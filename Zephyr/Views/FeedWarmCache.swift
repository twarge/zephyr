import Foundation
import ZulipModel

/// Where a parked feed's viewport sat when the user navigated away.
enum FeedScrollPosition {
    /// Sticky bottom: restore shows the newest messages, exactly as a
    /// live feed at the bottom would. `newestId` is the window's newest
    /// message at park time — a reopen compares it against the unreads
    /// to tell whether anything arrived while parked (and, if so, opens
    /// at the first arrival instead of the physical bottom).
    case bottom(newestId: Int?)
    /// Mid-history: the bottom-most visible row and the viewport-height
    /// fraction its bottom edge sat at — enough to reproduce the exact
    /// offset via the row's edge sentinel, independent of lazy-layout
    /// height estimates. `anchorY` is the unit anchor that lands the row
    /// itself there (its top over viewport-minus-row height): the scroll
    /// binding takes rows, not their sentinels, so the reopen's first
    /// layout uses it to open where the settle pass would end.
    case row(id: Int, fraction: CGFloat, anchorY: CGFloat)
}

/// A reference box the feed updates on every scroll tick (never observed
/// state — frames change per frame and must not re-render the feed),
/// parked in `FeedWarmCache` beside the model it describes.
@MainActor
final class FeedScrollMemory {
    var position: FeedScrollPosition?
}

/// The last few transcripts' view-models, kept alive after navigation away
/// so returning to a recent conversation renders instantly instead of
/// spinning through a refetch. A parked pair is the expensive part of a
/// feed: the fetched message window (`MessageListModel`, which stays
/// registered with its store and keeps absorbing live events while parked)
/// and its parsed-HTML memo (`MessageContentCache`).
///
/// Views are never parked — only models — so read-marking, keyboard
/// routing, and focus stay exclusive to the one visible feed.
///
/// Shared across windows and accounts. The model and parse memo are
/// shared by every window showing the narrow (both are plain data that
/// any number of views can read); scroll memory is per window (`scene`),
/// so two windows on one conversation don't fight over the restore.
/// An entry whose store instance was replaced (event-queue rebuild,
/// provisional → live swap) is stale and reads as a miss.
@MainActor
final class FeedWarmCache {
    static let shared = FeedWarmCache()

    /// Identifies a window for per-window scroll memory (its keyboard
    /// router, one per window).
    typealias Scene = ObjectIdentifier

    /// What a feed view resumes with.
    struct Warm {
        let model: MessageListModel
        let cache: MessageContentCache
        let scrollMemory: FeedScrollMemory
    }

    /// How many feeds stay warm. Each model's message window is itself
    /// bounded (`MessageListModel.maxWindowCount`), so the worst case is
    /// modest even with cross-channel feeds parked.
    private let capacity = 8

    private struct Key: Hashable {
        let account: Account.ID
        let narrow: Narrow
    }

    private final class Entry {
        /// Weak so a parked entry never keeps a replaced store alive;
        /// a dead reference is the staleness signal.
        weak var store: PerAccountStore?
        let model: MessageListModel
        let cache: MessageContentCache
        var scrollMemories: [Scene: FeedScrollMemory] = [:]

        init(store: PerAccountStore, model: MessageListModel, cache: MessageContentCache) {
            self.store = store
            self.model = model
            self.cache = cache
        }

        func warm(for scene: Scene) -> Warm {
            let memory = scrollMemories[scene] ?? FeedScrollMemory()
            scrollMemories[scene] = memory
            return Warm(model: model, cache: cache, scrollMemory: memory)
        }
    }

    /// LRU order: the last element is the most recently used.
    private var entries: [(key: Key, entry: Entry)] = []

    /// The warm state for this narrow, if it was parked against the same
    /// store instance. A hit bumps recency.
    func lookup(narrow: Narrow, store: PerAccountStore, scene: Scene) -> Warm? {
        let key = Key(account: store.accountId, narrow: narrow)
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries[index].entry
        guard entry.store === store else {
            entries.remove(at: index)
            return nil
        }
        entries.remove(at: index)
        entries.append((key, entry))
        return entry.warm(for: scene)
    }

    /// Narrows a cold open found nothing cached for, per store instance,
    /// so the view's repeated inits don't rebuild a preview that can't show.
    private var previewMisses: [Key: ObjectIdentifier] = [:]

    /// The warm state for this narrow — or, on a cold open whose narrow the
    /// store's cached history covers, a new model already showing that
    /// cache (`showCachedPreview`), parked here so the view's later inits
    /// (one per parent render) find it instead of building another. Either
    /// way the view's first frame has messages, not a spinner; a preview
    /// still owes its server fetch (`awaitsServer`). Nil when nothing is
    /// cached: the view's task loads it.
    func lookupOrPreview(
        narrow: Narrow, store: PerAccountStore, scene: Scene,
        makeModel: () -> MessageListModel
    ) -> Warm? {
        if let warm = lookup(narrow: narrow, store: store, scene: scene) { return warm }
        let key = Key(account: store.accountId, narrow: narrow)
        guard previewMisses[key] != ObjectIdentifier(store) else { return nil }
        let model = makeModel()
        model.showCachedPreview()
        guard model.didInitialFetch else {
            model.deactivate()
            previewMisses[key] = ObjectIdentifier(store)
            return nil
        }
        previewMisses[key] = nil
        let warm = Warm(model: model, cache: MessageContentCache(), scrollMemory: FeedScrollMemory())
        insert(warm, narrow: narrow, store: store, scene: scene)
        return warm
    }

    /// Parks a feed's state. Another window's scroll memory for the same
    /// model survives; a different model starts every window afresh.
    func insert(_ warm: Warm, narrow: Narrow, store: PerAccountStore, scene: Scene) {
        let key = Key(account: store.accountId, narrow: narrow)
        let existing = entries.first { $0.key == key }?.entry
        entries.removeAll { $0.key == key }
        let entry = existing.flatMap { $0.model === warm.model && $0.store === store ? $0 : nil }
            ?? Entry(store: store, model: warm.model, cache: warm.cache)
        entry.scrollMemories[scene] = warm.scrollMemory
        entries.append((key, entry))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Sign-out: a removed account's transcripts don't linger in memory.
    func removeAll(for account: Account.ID) {
        entries.removeAll { $0.key.account == account }
    }

    /// The feed views' shared `.task` body. A healthy model already bound
    /// to this store (warm start, or a reappearing live view) is kept —
    /// parked models keep absorbing live events — and a cached preview
    /// fetches in place, under the messages it shows. Otherwise a fresh
    /// model fetches: installed at once on a first open (showing the
    /// fetch in progress), or only once it has content on a store swap
    /// (provisional → live at launch, queue rebuild), so the rendered
    /// feed never blanks mid-read. A successful fetch parks for an
    /// instant return. Returns the fresh model, nil when `current` was
    /// kept.
    @discardableResult
    func bind(
        current: MessageListModel?, store: PerAccountStore, narrow: Narrow,
        count: Int, keepsCurrent: Bool = true, replacesPreview: Bool = false,
        parks: Bool = true, warm: (cache: MessageContentCache, scrollMemory: FeedScrollMemory),
        scene: Scene,
        makeModel: () -> MessageListModel,
        install: (MessageListModel) -> Void
    ) async -> MessageListModel? {
        if keepsCurrent, let current, current.isBound(to: store),
           current.didInitialFetch, current.fetchError == nil
        {
            if current.awaitsServer {
                await current.fetchInitial(count: count)
            }
            return nil
        }
        let list = makeModel()
        if current == nil || (replacesPreview && current?.awaitsServer == true) {
            install(list)
            await list.fetchInitial(count: count)
        } else {
            await list.fetchInitial(count: count)
            install(list)
        }
        if parks, list.fetchError == nil {
            insert(
                Warm(model: list, cache: warm.cache, scrollMemory: warm.scrollMemory),
                narrow: narrow, store: store, scene: scene)
        }
        return list
    }
}
