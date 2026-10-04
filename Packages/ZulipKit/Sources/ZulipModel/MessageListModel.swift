import Foundation
import Observation
import ZulipAPI

extension Narrow {
    /// Whether a message belongs in this narrow (client-side counterpart of
    /// the server's narrow filtering, used to route live events into open
    /// message lists).
    public func containsMessage(_ message: Message, selfUserId: Int) -> Bool {
        switch self {
        case .combinedFeed:
            return true
        case .channel(let streamId):
            return message.streamId == streamId
        case .topic(let streamId, let topic):
            return message.streamId == streamId
                && TopicName.matches(message.subject, topic)
        case .dm(let userIds):
            guard message.type == .private,
                  case .users(let recipients) = message.displayRecipient else { return false }
            let normalize = { (ids: [Int]) in Set(ids.filter { $0 != selfUserId }) }
            return normalize(recipients.map(\.id)) == normalize(userIds)
        case .mentions:
            let flags = Set(message.flags ?? [])
            return !flags.isDisjoint(with: [
                "mentioned", "wildcard_mentioned", "stream_wildcard_mentioned",
                "topic_wildcard_mentioned",
            ])
        case .starred:
            return (message.flags ?? []).contains("starred")
        case .custom:
            return false
        }
    }
}

/// The view-model for one open transcript: a narrow, the fetched slice of its
/// history (ascending by id), and live updates fanned in from the store.
///
/// UI-agnostic by design (see ARCHITECTURE §6): it exposes messages and fetch
/// intents; scrolling strategy lives entirely in the view layer.
@MainActor
@Observable
public final class MessageListModel: Identifiable {
    public let id = UUID()
    public let narrow: Narrow

    public private(set) var messages: [Message] = []
    public private(set) var haveOldest = false
    public private(set) var haveNewest = false
    public private(set) var isFetching = false
    public private(set) var fetchError: (any Error)?
    public private(set) var didInitialFetch = false
    /// True while `messages` is the offline copy (rendered ahead of the
    /// initial fetch, or left showing after it failed); the list refetches
    /// when connectivity returns.
    public private(set) var isOfflineFallback = false
    /// The initial fetch has come back from the server; late-arriving cache
    /// reads must not overwrite its answer (even an empty one).
    private var serverDidRespond = false
    /// The first unread message at open time — the "NEW" marker's position.
    /// Set by the initial fetch and left stable as reading proceeds; a warm
    /// reopen re-aims it at the first unread that arrived while the model
    /// was parked (`reaimUnreadMarker`).
    public private(set) var firstUnreadMarkerId: Int?

    /// A first-unread window whose newest fetched message is older than
    /// this is a stale backlog (e.g. years of never-read #general): the
    /// view opens at the newest messages instead of deep in history.
    private static let staleBacklogAge: TimeInterval = 14 * 86400

    /// Catch-up feeds interleave many conversations, so the server's
    /// `first_unread` is the wrong opening anchor — in Combined it is
    /// nearly always a muted or years-stale message, not where the reader
    /// left off. These narrows resume at the oldest unread the UI
    /// surfaces (`PerAccountStore.resumeUnreadId`) instead.
    private var resumesAtVisibleUnread: Bool {
        switch narrow {
        case .combinedFeed, .channel: true
        default: false
        }
    }

    /// An unread worth resuming at: surfaced in the UI (a Combined feed
    /// can hold muted conversations too) and not a stale backlog.
    private func isResumePoint(_ message: Message, in store: PerAccountStore) -> Bool {
        guard !(message.flags ?? []).contains("read"),
              Date.now.timeIntervalSince1970 - TimeInterval(message.timestamp)
                  <= Self.staleBacklogAge
        else { return false }
        guard case .combinedFeed(let includesMuted) = narrow else { return true }
        return Unreads.conversationKey(for: message, selfUserId: store.selfUserId)
            .map { store.isCombinedUnread($0, includesMuted: includesMuted) } ?? true
    }

    /// Narrow membership for messages no server fetch filtered (live
    /// events, the local cache). The home view's muting rule lives in the
    /// store, beyond what `Narrow.containsMessage` can see.
    private func admits(_ message: Message, in store: PerAccountStore) -> Bool {
        guard narrow.containsMessage(message, selfUserId: store.selfUserId) else { return false }
        if case .combinedFeed(includesMuted: false) = narrow {
            return store.isShownInHome(message)
        }
        return true
    }
    /// Paging keeps at most this many messages in memory — beyond it the
    /// far end is dropped and re-pages from the server or cache on demand.
    private static let maxWindowCount = 600

    private weak var store: PerAccountStore?
    private var generation = 0
    /// Live arrivals for this narrow that couldn't append because the
    /// window didn't reach the newest message (mid-history anchor, deep
    /// scrollback, or a jump-to-newest fetch still in flight). Merged in
    /// once a fetch re-establishes `haveNewest`. Dropping them instead
    /// would lose the message until an unrelated refetch — worst for our
    /// own sends, whose one echo event also clears their outbox row.
    private var pendingNewest: [Message] = []
    private static let maxPendingNewest = 200
    /// A specific message to open at (message links); overrides the
    /// first-unread anchor.
    private let initialAnchorMessageId: Int?

    public init(store: PerAccountStore, narrow: Narrow, anchorMessageId: Int? = nil) {
        self.store = store
        self.narrow = narrow
        initialAnchorMessageId = anchorMessageId
        store.register(self)
    }

    /// Detach from the store's event fan-out (views call this on disappear;
    /// registration is weak, so this is belt-and-suspenders).
    public func deactivate() {
        store?.unregister(id)
    }

    /// True while this list is fed by `store`'s event fan-out. A queue
    /// rebuild replaces the store, so a list kept warm across navigation
    /// is stale exactly when this turns false.
    public func isBound(to store: PerAccountStore) -> Bool {
        self.store === store
    }

    /// The oldest unread newer than `newestId` (nil accepts any unread) —
    /// the logical resume point when a feed parked at the bottom reopens
    /// after messages arrived. Catch-up feeds count only unreads worth
    /// resuming at, as their fresh open does: a muted arrival must not
    /// capture the reopen. Pure: callable from view init.
    public func firstUnreadId(after newestId: Int?) -> Int? {
        messages.first { message in
            if let newestId, message.id <= newestId { return false }
            if resumesAtVisibleUnread, let store {
                return isResumePoint(message, in: store)
            }
            return !(message.flags ?? []).contains("read")
        }?.id
    }

    /// Re-aims the NEW marker at a warm reopen (the id from
    /// `firstUnreadId(after:)`). Separate from the query so views can
    /// decide in init — pure, re-run on every parent re-evaluation — and
    /// mutate once on appear.
    public func reaimUnreadMarker(to id: Int) {
        guard messages.contains(where: { $0.id == id }) else { return }
        firstUnreadMarkerId = id
    }

    // MARK: Fetching

    public func fetchInitial(count: Int = 60) async {
        guard let store, !isFetching else { return }
        isFetching = true
        let gen = generation
        defer { isFetching = false }
        // Zulip semantics: open at the first unread (or a linked message),
        // with history in both directions. Search narrows can't ask for
        // first_unread; they open at the newest results.
        // Offline-first: render the cached transcript immediately, anchored
        // where the server render will land. The fetch below still runs:
        // success replaces the preview and clears the fallback flag;
        // failure leaves it showing, and reconnect refetches.
        populateOfflineFallback()
        var anchor: MessageAnchor
        var anchoredMidHistory = true
        var resumeId: Int?
        if let initialAnchorMessageId {
            anchor = .id(initialAnchorMessageId)
        } else if case .custom = narrow {
            anchor = .newest
            anchoredMidHistory = false
        } else if resumesAtVisibleUnread {
            resumeId = await store.resumeUnreadId(
                for: narrow, staleAfter: Self.staleBacklogAge)
            guard generation == gen else { return }
            if let resumeId {
                anchor = .id(resumeId)
            } else {
                // Nothing the reader would catch up on: the newest messages.
                anchor = .newest
                anchoredMidHistory = false
            }
        } else {
            anchor = .firstUnread
        }
        do {
            var result = try await store.connection.getMessages(
                anchor: anchor, numBefore: count,
                numAfter: anchoredMidHistory ? count : 0,
                narrow: narrow.apiElements)
            guard generation == gen else { return }
            // A stale backlog (the first unread is weeks-to-years deep, as
            // in huge never-read public channels) would open the view far
            // in the past; reopen at the newest messages, with no NEW
            // marker — that backlog is beyond catching up linearly.
            var suppressUnreadMarker = false
            if case .firstUnread = anchor,
               !(result.foundNewest ?? false),
               let newestFetched = result.messages.map(\.timestamp).max(),
               Date.now.timeIntervalSince1970 - TimeInterval(newestFetched)
                   > Self.staleBacklogAge {
                result = try await store.connection.getMessages(
                    anchor: .newest, numBefore: count, numAfter: 0,
                    narrow: narrow.apiElements)
                guard generation == gen else { return }
                anchoredMidHistory = false
                // The newest window can still hold the resume point: when
                // its oldest message is read, recent reading reached into
                // it, and its unreads are fresh arrivals (only the ancient
                // backlog lies above) — the marker aims at the first of
                // them below. Unread to the window's very edge is the
                // bottomless backlog itself: no marker, open at newest.
                suppressUnreadMarker = result.messages
                    .min { $0.id < $1.id }
                    .map { !($0.flags ?? []).contains("read") } ?? true
            }
            // The resume id came from unread bookkeeping, which has no
            // dates: a cache too shallow to set the staleness floor can
            // hand back an ancient one. The fetched message settles it —
            // stale means open at the newest messages instead.
            if let resumeId,
               let resumed = result.messages.filter({ $0.id >= resumeId })
                   .min(by: { $0.id < $1.id }),
               Date.now.timeIntervalSince1970 - TimeInterval(resumed.timestamp)
                   > Self.staleBacklogAge {
                result = try await store.connection.getMessages(
                    anchor: .newest, numBefore: count, numAfter: 0,
                    narrow: narrow.apiElements)
                guard generation == gen else { return }
                anchoredMidHistory = false
            }
            store.reconcileFetchedMessages(result.messages)
            let fetched = result.messages
                .sorted { $0.id < $1.id }
                .map { store.messages[$0.id] ?? $0 }
            // A wholesale replace must not wipe live arrivals newer than
            // the fetched window — its server snapshot can predate events
            // applied while it was in flight (a just-sent echo especially).
            if haveNewest {
                stashPendingNewest(messages.filter { $0.id > (fetched.last?.id ?? -1) })
            }
            messages = fetched
            haveNewest = result.foundNewest ?? !anchoredMidHistory
            haveOldest = result.foundOldest ?? false
            // The marker is the oldest fetched message still unread — in
            // a catch-up feed, the oldest one worth resuming at (its window
            // also holds muted and stale unreads, which never anchor).
            if resumesAtVisibleUnread, initialAnchorMessageId == nil {
                firstUnreadMarkerId = messages.first { isResumePoint($0, in: store) }?.id
            } else {
                firstUnreadMarkerId = suppressUnreadMarker ? nil : messages.first { message in
                    !(message.flags ?? []).contains("read")
                }?.id
            }
            fetchError = nil
            didInitialFetch = true
            isOfflineFallback = false
            serverDidRespond = true
            mergePendingNewest()
        } catch is CancellationError {
        } catch {
            guard generation == gen else { return }
            fetchError = error
            didInitialFetch = true
            populateOfflineFallback()
        }
    }

    /// Pages forward from the newest fetched message (the list opened
    /// mid-history at an unread or linked anchor).
    public func fetchNewer(count: Int = 100) async {
        guard let store, !isFetching, !haveNewest, let last = messages.last else { return }
        isFetching = true
        let gen = generation
        defer { isFetching = false }
        do {
            let result = try await store.connection.getMessages(
                anchor: .id(last.id), numBefore: 0, numAfter: count,
                narrow: narrow.apiElements)
            guard generation == gen else { return }
            store.reconcileFetchedMessages(result.messages)
            let newer = result.messages
                .filter { $0.id > last.id }
                .sorted { $0.id < $1.id }
                .map { store.messages[$0.id] ?? $0 }
            messages.append(contentsOf: newer)
            haveNewest = result.foundNewest ?? false
            mergePendingNewest()
            trimWindowKeepingNewest()
        } catch is CancellationError {
        } catch {
            guard generation == gen else { return }
            fetchError = error
        }
    }

    /// Abandons the current window and reloads at the newest messages
    /// (the jump-to-latest control).
    public func jumpToNewest(count: Int = 60) async {
        guard let store else { return }
        generation += 1  // Invalidate any in-flight page.
        let gen = generation
        isFetching = true
        defer { isFetching = false }
        do {
            let result = try await store.connection.getMessages(
                anchor: .newest, numBefore: count, numAfter: 0, narrow: narrow.apiElements)
            guard generation == gen else { return }
            store.reconcileFetchedMessages(result.messages)
            let fetched = result.messages
                .sorted { $0.id < $1.id }
                .map { store.messages[$0.id] ?? $0 }
            // See fetchInitial: don't let the replace wipe live arrivals.
            if haveNewest {
                stashPendingNewest(messages.filter { $0.id > (fetched.last?.id ?? -1) })
            }
            messages = fetched
            haveNewest = result.foundNewest ?? true
            haveOldest = result.foundOldest ?? false
            fetchError = nil
            serverDidRespond = true
            mergePendingNewest()
        } catch is CancellationError {
        } catch {
            guard generation == gen else { return }
            fetchError = error
        }
    }

    /// Renders the transcript from the local cache ahead of (or instead of)
    /// the initial fetch: the in-memory map when it covers the narrow, the
    /// SQLite store when it doesn't. Live events still append
    /// (`haveNewest`), and the store triggers a real refetch on reconnect.
    private func populateOfflineFallback() {
        guard messages.isEmpty, let store else { return }
        // Search narrows can't be matched client-side, but the local FTS
        // index can answer them.
        if case .custom(let elements) = narrow {
            let text = elements.first { $0.operatorName == "search" }.flatMap { element -> String? in
                if case .string(let value) = element.operand { return value }
                return nil
            }
            guard let text else { return }
            let gen = generation
            Task { [weak self] in
                guard let self, let store = self.store else { return }
                let results = await store.searchOffline(text)
                guard self.generation == gen, self.messages.isEmpty,
                      !self.serverDidRespond, !results.isEmpty
                else { return }
                self.messages = results
                self.isOfflineFallback = true
                self.didInitialFetch = true
            }
            return
        }
        let cached = store.messages.values
            .filter { admits($0, in: store) }
            .sorted { $0.id < $1.id }
        if !cached.isEmpty {
            applyCachedWindow(cached)
            return
        }
        // The launch restore holds only the newest ~50 per conversation;
        // a narrow it doesn't cover pages out of the database instead.
        let gen = generation
        Task { [weak self] in
            guard let self, let store = self.store else { return }
            let rows = await store.olderFromCache(than: .max, narrow: narrow)
                .filter { self.admits($0, in: store) }
            guard self.generation == gen, self.messages.isEmpty,
                  !self.serverDidRespond, !rows.isEmpty
            else { return }
            store.installCachedMessages(rows)
            self.applyCachedWindow(rows.map { store.messages[$0.id] ?? $0 })
        }
    }

    /// Shows a cached slice, anchored the way the server render will be —
    /// a linked message, else the first unread, else the newest — so the
    /// fetch's replace lands where the reader already is.
    private func applyCachedWindow(_ cached: [Message], count: Int = 100) {
        var anchorIndex: Int?
        if let target = initialAnchorMessageId {
            // A linked message the cache doesn't hold: wait for the server.
            guard let index = cached.firstIndex(where: { $0.id == target })
            else { return }
            anchorIndex = index
        } else if resumesAtVisibleUnread {
            // The same rule as the fetch, answered from the cache: the
            // oldest surfaced, still-fresh unread — else the newest.
            if let store,
               let index = cached.firstIndex(where: { isResumePoint($0, in: store) }) {
                anchorIndex = index
                firstUnreadMarkerId = cached[index].id
            }
        } else if let index = cached.firstIndex(where: {
            !($0.flags ?? []).contains("read")
        }) {
            if Date.now.timeIntervalSince1970 - TimeInterval(cached[index].timestamp)
                <= Self.staleBacklogAge {
                anchorIndex = index
                firstUnreadMarkerId = cached[index].id
            } else if let resume = cached.suffix(count).first(where: {
                !($0.flags ?? []).contains("read")
            }), let oldest = cached.suffix(count).first,
                (oldest.flags ?? []).contains("read")
            {
                // The same stale-backlog rule as the fetch: an ancient
                // first unread opens at the newest messages — but the
                // newest window read to its edge still marks the resume
                // point at its own first unread (fresh arrivals).
                firstUnreadMarkerId = resume.id
            }
        }
        if let anchorIndex {
            let start = max(cached.startIndex, anchorIndex - count)
            let end = min(cached.endIndex, anchorIndex + count)
            messages = Array(cached[start..<end])
            haveNewest = end == cached.endIndex
        } else {
            messages = Array(cached.suffix(count))
            haveNewest = true
        }
        isOfflineFallback = true
        didInitialFetch = true
    }

    func refetchIfOfflineFallback() {
        guard isOfflineFallback else { return }
        Task { await self.fetchInitial() }
    }

    /// The launch restore hydrated the store after this list opened (it
    /// found an empty map): render the now-available cache unless the
    /// server has already answered.
    func cacheDidRestore() {
        guard messages.isEmpty, !serverDidRespond else { return }
        populateOfflineFallback()
    }

    /// Safe to call repeatedly from scroll tracking; no-ops while busy or at
    /// the start of history.
    public func fetchOlder(count: Int = 100) async {
        guard let store, !isFetching, !haveOldest, let first = messages.first else { return }
        isFetching = true
        let gen = generation
        defer { isFetching = false }
        do {
            let result = try await store.connection.getMessages(
                anchor: .id(first.id), numBefore: count, numAfter: 0, narrow: narrow.apiElements)
            guard generation == gen else { return }
            store.reconcileFetchedMessages(result.messages)
            let older = result.messages
                .filter { $0.id < first.id }
                .sorted { $0.id < $1.id }
                .map { store.messages[$0.id] ?? $0 }
            messages.insert(contentsOf: older, at: 0)
            haveOldest = result.foundOldest ?? false
            trimWindowKeepingOldest()
        } catch is CancellationError {
        } catch {
            guard generation == gen else { return }
            fetchError = error
            // Offline scrollback: page older history out of the local
            // database instead.
            let cached = await store.olderFromCache(than: first.id, narrow: narrow)
            guard generation == gen, let currentFirst = messages.first?.id else { return }
            let older = cached.filter { $0.id < currentFirst && admits($0, in: store) }
            guard !older.isEmpty else { return }
            store.installCachedMessages(older)
            messages.insert(
                contentsOf: older.map { store.messages[$0.id] ?? $0 }, at: 0)
            trimWindowKeepingOldest()
        }
    }

    // MARK: Window bounding

    /// Dropping the far end keeps huge scrollback sessions responsive; the
    /// cleared have-flag makes the dropped side re-page on demand.
    private func trimWindowKeepingNewest() {
        guard messages.count > Self.maxWindowCount else { return }
        messages.removeFirst(messages.count - Self.maxWindowCount)
        haveOldest = false
    }

    private func trimWindowKeepingOldest() {
        guard messages.count > Self.maxWindowCount else { return }
        messages.removeLast(messages.count - Self.maxWindowCount)
        haveNewest = false
    }

    // MARK: Event fan-in (called by PerAccountStore)

    func handleNewMessage(_ message: Message, selfUserId: Int) {
        guard narrow.containsMessage(message, selfUserId: selfUserId),
              store.map({ admits(message, in: $0) }) ?? true
        else { return }
        guard haveNewest else {
            stashPendingNewest([message])
            return
        }
        guard (messages.last?.id ?? -1) < message.id else { return }
        messages.append(message)
        trimWindowKeepingNewest()
    }

    func handleChangedMessages(ids: some Sequence<Int>) {
        guard let store else { return }
        for id in ids {
            guard let index = messages.firstIndex(where: { $0.id == id }) else { continue }
            guard let updated = store.messages[id] else {
                messages.remove(at: index)
                continue
            }
            // Moves can carry a message out of this narrow. Search results
            // (.custom) can't be re-evaluated client-side — keep them.
            if case .custom = narrow {
                messages[index] = updated
            } else if admits(updated, in: store) {
                messages[index] = updated
            } else {
                messages.remove(at: index)
            }
        }
    }

    /// A conversation's mute state changed. Only the home view cares:
    /// newly hidden messages leave in place (their neighbors hold the
    /// viewport), while a reveal needs the server — it alone knows what
    /// belongs between the rows already here.
    func handleHomeVisibilityChange(revealed: Bool) {
        guard case .combinedFeed(includesMuted: false) = narrow,
              let store, didInitialFetch
        else { return }
        if revealed {
            Task { await self.fetchInitial(count: max(60, min(messages.count, 100))) }
            return
        }
        let shown = messages.filter { store.isShownInHome($0) }
        if shown.count != messages.count { messages = shown }
        pendingNewest.removeAll { !store.isShownInHome($0) }
    }

    /// A mid-history window whose pending buffer holds one of our own sends
    /// means the send-time jump-to-newest failed: the echo consumed the
    /// outbox row, so nothing visible represents the message until a fetch
    /// re-establishes `haveNewest`. Called on connectivity recovery to
    /// re-run that jump; a no-op for buffered arrivals from others (the
    /// reader parked mid-history on purpose — don't yank them).
    func recoverBuriedOwnSends() {
        guard !haveNewest, !isFetching, let store,
              pendingNewest.contains(where: { $0.senderId == store.selfUserId })
        else { return }
        Task { await self.jumpToNewest() }
    }

    func handleDeletedMessages(ids: [Int]) {
        let deleted = Set(ids)
        messages.removeAll { deleted.contains($0.id) }
        pendingNewest.removeAll { deleted.contains($0.id) }
    }

    private func stashPendingNewest(_ arrivals: [Message]) {
        for message in arrivals
        where !pendingNewest.contains(where: { $0.id == message.id }) {
            pendingNewest.append(message)
        }
        if pendingNewest.count > Self.maxPendingNewest {
            pendingNewest.removeFirst(pendingNewest.count - Self.maxPendingNewest)
        }
    }

    /// Appends buffered live arrivals newer than the fetched window (the
    /// store's copy, so edits/reactions that landed while buffered are
    /// kept; a move out of the narrow while buffered drops it). Call after
    /// any fetch that leaves `haveNewest` true.
    private func mergePendingNewest() {
        guard haveNewest, !pendingNewest.isEmpty, let store else { return }
        let lastId = messages.last?.id ?? -1
        let merged = pendingNewest
            .compactMap { store.messages[$0.id] }
            .filter {
                $0.id > lastId && admits($0, in: store)
            }
            .sorted { $0.id < $1.id }
        pendingNewest = []
        guard !merged.isEmpty else { return }
        messages.append(contentsOf: merged)
        trimWindowKeepingNewest()
    }
}
