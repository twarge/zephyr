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
    /// True when `messages` came from the offline cache because the initial
    /// fetch failed; the list refetches when connectivity returns.
    public private(set) var isOfflineFallback = false
    /// The first unread message at open time — the "NEW" marker's position.
    /// Set once by the initial fetch and left stable as reading proceeds.
    public private(set) var firstUnreadMarkerId: Int?

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
        do {
            let result = try await store.connection.getMessages(
                anchor: anchor, numBefore: count,
                numAfter: anchoredMidHistory ? count : 0,
                narrow: narrow.apiElements)
            guard generation == gen else { return }
            store.reconcileFetchedMessages(result.messages)
            messages = result.messages
                .sorted { $0.id < $1.id }
                .map { store.messages[$0.id] ?? $0 }
            haveNewest = result.foundNewest ?? !anchoredMidHistory
            haveOldest = result.foundOldest ?? false
            // The marker is the oldest fetched message still unread.
            firstUnreadMarkerId = messages.first { message in
                !(message.flags ?? []).contains("read")
            }?.id
            fetchError = nil
            didInitialFetch = true
            isOfflineFallback = false
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
        } catch is CancellationError {
        } catch {
            guard generation == gen else { return }
            fetchError = error
        }
    }

    /// Renders the transcript from the store's cached messages when the
    /// network is down. Live events still append (`haveNewest`), and the
    /// store triggers a real refetch on reconnect.
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
                guard self.generation == gen, self.messages.isEmpty, !results.isEmpty
                else { return }
                self.messages = results
                self.isOfflineFallback = true
            }
            return
        }
        let cached = store.messages.values
            .filter { narrow.containsMessage($0, selfUserId: store.selfUserId) }
            .sorted { $0.id < $1.id }
        guard !cached.isEmpty else { return }
        messages = Array(cached.suffix(100))
        haveNewest = true
        isOfflineFallback = true
    }

    func refetchIfOfflineFallback() {
        guard isOfflineFallback else { return }
        Task { await self.fetchInitial() }
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
            store.reconcileFetchedMessages(older)
            messages.insert(
                contentsOf: older.map { store.messages[$0.id] ?? $0 }, at: 0)
        }
    }

    // MARK: Event fan-in (called by PerAccountStore)

    func handleNewMessage(_ message: Message, selfUserId: Int) {
        guard haveNewest, narrow.containsMessage(message, selfUserId: selfUserId) else { return }
        guard (messages.last?.id ?? -1) < message.id else { return }
        messages.append(message)
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
