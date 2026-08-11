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
                && message.subject.caseInsensitiveCompare(topic) == .orderedSame
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
    /// Set once by the initial fetch and left stable as reading proceeds.
    public private(set) var firstUnreadMarkerId: Int?

    /// A first-unread window whose newest fetched message is older than
    /// this is a stale backlog (e.g. years of never-read #general): the
    /// view opens at the newest messages instead of deep in history.
    private static let staleBacklogAge: TimeInterval = 14 * 86400
    /// Paging keeps at most this many messages in memory — beyond it the
    /// far end is dropped and re-pages from the server or cache on demand.
    private static let maxWindowCount = 600

    private weak var store: PerAccountStore?
    private var generation = 0
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

    // MARK: Fetching

    public func fetchInitial(count: Int = 60) async {
        guard let store, !isFetching else { return }
        isFetching = true
        let gen = generation
        defer { isFetching = false }
        // Zulip semantics: open at the first unread (or a linked message),
        // with history in both directions. Search narrows can't ask for
        // first_unread; they open at the newest results.
        let anchor: MessageAnchor
        var anchoredMidHistory = true
        if let initialAnchorMessageId {
            anchor = .id(initialAnchorMessageId)
        } else if case .custom = narrow {
            anchor = .newest
            anchoredMidHistory = false
        } else {
            anchor = .firstUnread
        }
        // Offline-first: render the cached transcript immediately, anchored
        // where the server render will land. The fetch below still runs:
        // success replaces the preview and clears the fallback flag;
        // failure leaves it showing, and reconnect refetches.
        populateOfflineFallback()
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
                suppressUnreadMarker = true
            }
            store.reconcileFetchedMessages(result.messages)
            messages = result.messages
                .sorted { $0.id < $1.id }
                .map { store.messages[$0.id] ?? $0 }
            haveNewest = result.foundNewest ?? !anchoredMidHistory
            haveOldest = result.foundOldest ?? false
            // The marker is the oldest fetched message still unread.
            firstUnreadMarkerId = suppressUnreadMarker ? nil : messages.first { message in
                !(message.flags ?? []).contains("read")
            }?.id
            fetchError = nil
            didInitialFetch = true
            isOfflineFallback = false
            serverDidRespond = true
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
            messages = result.messages
                .sorted { $0.id < $1.id }
                .map { store.messages[$0.id] ?? $0 }
            haveNewest = result.foundNewest ?? true
            haveOldest = result.foundOldest ?? false
            fetchError = nil
            serverDidRespond = true
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
            .filter { narrow.containsMessage($0, selfUserId: store.selfUserId) }
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
        } else if let index = cached.firstIndex(where: {
            !($0.flags ?? []).contains("read")
        }), Date.now.timeIntervalSince1970 - TimeInterval(cached[index].timestamp)
            <= Self.staleBacklogAge {
            // The same stale-backlog rule as the fetch: an ancient first
            // unread opens at the newest messages, with no NEW marker.
            anchorIndex = index
            firstUnreadMarkerId = cached[index].id
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
            let older = cached.filter { $0.id < currentFirst }
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
        guard haveNewest, narrow.containsMessage(message, selfUserId: selfUserId) else { return }
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
            } else if narrow.containsMessage(updated, selfUserId: store.selfUserId) {
                messages[index] = updated
            } else {
                messages.remove(at: index)
            }
        }
    }

    func handleDeletedMessages(ids: [Int]) {
        let deleted = Set(ids)
        messages.removeAll { deleted.contains($0.id) }
    }
}
