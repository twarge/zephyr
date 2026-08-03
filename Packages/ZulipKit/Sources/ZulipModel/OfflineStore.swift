import Foundation
import ZulipAPI

/// Per-account offline persistence: recent messages (so transcripts render
/// with no network), the outbox (so unsent messages survive relaunch), and
/// queued idempotent actions (reactions/flags recorded offline, replayed on
/// reconnect). Distinct from the register snapshot cache in `GlobalStore`,
/// which holds server *state*; this holds work and history.
///
/// All loads are tolerant (any failure reads as empty) and all writes are
/// atomic — losing this data only costs offline convenience.
public struct OfflineStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The standard Application Support location for one account.
    public static func forAccount(_ accountId: Account.ID) -> OfflineStore? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }
        return OfflineStore(directory: base
            .appendingPathComponent("com.twarge.zephyr", isDirectory: true)
            .appendingPathComponent("offline", isDirectory: true)
            .appendingPathComponent(accountId.uuidString, isDirectory: true))
    }

    public static func remove(for accountId: Account.ID) {
        guard let store = forAccount(accountId) else { return }
        try? FileManager.default.removeItem(at: store.directory)
    }

    // MARK: Files

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? ZulipJSON.decoder.decode(type, from: data)
    }

    private func save(_ value: some Encodable, to name: String) {
        guard let data = try? ZulipJSON.encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    // MARK: Messages

    /// How many messages per conversation restore into memory at launch.
    /// (The SQLite store itself retains full history.)
    public static let messagesPerConversation = 50

    /// Opens (creating on first use) the account's SQLite message store.
    public func openDatabase() -> MessageDatabase? {
        try? MessageDatabase(path: url("messages.sqlite").path)
    }

    /// The pre-SQLite JSON cache, read once for migration then removed.
    public func loadLegacyMessages() -> [Message] {
        load([Message].self, from: "messages.json") ?? []
    }

    public func removeLegacyMessages() {
        try? FileManager.default.removeItem(at: url("messages.json"))
    }

    // MARK: Outbox

    public func loadOutbox() -> [OutboxMessage] {
        load([OutboxMessage].self, from: "outbox.json") ?? []
    }

    public func saveOutbox(_ outbox: [OutboxMessage]) {
        save(outbox, to: "outbox.json")
    }

    // MARK: Pending actions

    public func loadPendingActions() -> [PendingAction] {
        load([PendingAction].self, from: "actions.json") ?? []
    }

    public func savePendingActions(_ actions: [PendingAction]) {
        save(actions, to: "actions.json")
    }
}

/// A server mutation recorded while offline, replayed in order on reconnect.
/// Only idempotent operations qualify (replaying after an ambiguous failure
/// must be harmless); destructive ones (delete, edit, move) stay online-only.
public enum PendingAction: Codable, Sendable, Equatable {
    case updateFlags(messageIds: [Int], add: Bool, flag: String)
    case reaction(
        messageId: Int, add: Bool, emojiName: String, emojiCode: String, reactionType: String)
}

/// Whether an error means the request never reached the server (no route, no
/// connection): safe to auto-retry anything, including non-idempotent sends.
public func isDefinitelyOfflineError(_ error: any Error) -> Bool {
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
        return true
    default:
        return false
    }
}

/// Broader classification for idempotent operations: includes failures where
/// the request *may* have reached the server (connection lost, timeout) —
/// replaying those is harmless when the operation is idempotent, but would
/// risk duplicating a message send.
public func isTransientNetworkError(_ error: any Error) -> Bool {
    if isDefinitelyOfflineError(error) { return true }
    guard let urlError = error as? URLError else { return false }
    switch urlError.code {
    case .networkConnectionLost, .timedOut:
        return true
    default:
        return false
    }
}
