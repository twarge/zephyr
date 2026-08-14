import Foundation
import ZulipModel

/// Where a parked feed's viewport sat when the user navigated away.
enum FeedScrollPosition {
    /// Sticky bottom: restore shows the newest messages, exactly as a
    /// live feed at the bottom would.
    case bottom
    /// Mid-history: the bottom-most visible row and the viewport-height
    /// fraction its bottom edge sat at — enough to reproduce the exact
    /// offset via the row's edge sentinel, independent of lazy-layout
    /// height estimates.
    case row(id: Int, fraction: CGFloat)
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
/// Shared across windows and accounts. An entry whose store instance was
/// replaced (event-queue rebuild, provisional → live swap) is stale and
/// reads as a miss.
@MainActor
final class FeedWarmCache {
    static let shared = FeedWarmCache()

    /// How many feeds stay warm. Each model's message window is itself
    /// bounded (`MessageListModel.maxWindowCount`), so the worst case is
    /// modest even with cross-channel feeds parked.
    private let capacity = 8

    private struct Key: Hashable {
        let account: Account.ID
        let narrow: Narrow
    }

    private struct Entry {
        /// Weak so a parked entry never keeps a replaced store alive;
        /// a dead reference is the staleness signal.
        weak var store: PerAccountStore?
        let model: MessageListModel
        let cache: MessageContentCache
        let scrollMemory: FeedScrollMemory
    }

    /// LRU order: the last element is the most recently used.
    private var entries: [(key: Key, entry: Entry)] = []

    /// The warm state for this narrow, if it was parked against the same
    /// store instance. A hit bumps recency.
    func lookup(
        narrow: Narrow, store: PerAccountStore
    ) -> (model: MessageListModel, cache: MessageContentCache, scrollMemory: FeedScrollMemory)? {
        let key = Key(account: store.accountId, narrow: narrow)
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries[index].entry
        guard entry.store === store else {
            entries.remove(at: index)
            return nil
        }
        entries.remove(at: index)
        entries.append((key, entry))
        return (entry.model, entry.cache, entry.scrollMemory)
    }

    func insert(
        model: MessageListModel, cache: MessageContentCache,
        scrollMemory: FeedScrollMemory,
        narrow: Narrow, store: PerAccountStore
    ) {
        let key = Key(account: store.accountId, narrow: narrow)
        entries.removeAll { $0.key == key }
        entries.append((key, Entry(
            store: store, model: model, cache: cache, scrollMemory: scrollMemory)))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Sign-out: a removed account's transcripts don't linger in memory.
    func removeAll(for account: Account.ID) {
        entries.removeAll { $0.key.account == account }
    }
}
