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

    private weak var store: PerAccountStore?
    private var generation = 0

    public init(store: PerAccountStore, narrow: Narrow) {
        self.store = store
        self.narrow = narrow
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
            didInitialFetch = true
        } catch is CancellationError {
        } catch {
            guard generation == gen else { return }
            fetchError = error
            didInitialFetch = true
        }
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
            guard let index = messages.firstIndex(where: { $0.id == id }),
                  let updated = store.messages[id] else { continue }
            messages[index] = updated
        }
    }

    func handleDeletedMessages(ids: [Int]) {
        let deleted = Set(ids)
        messages.removeAll { deleted.contains($0.id) }
    }
}
