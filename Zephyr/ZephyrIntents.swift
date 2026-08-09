import AppIntents
import Foundation
import ZulipModel

// The App Intents surface: entities for conversations and servers, intents
// to open and send, Siri phrases, and a Focus filter. Everything runs
// in-process and resolves live state through AppModel.shared.

enum ZephyrIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    case needsTopic

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Zephyr isn't signed in yet."
        case .needsTopic: "Sending to a channel needs a topic."
        }
    }
}

// MARK: - Entities

/// A channel or conversation on a specific account. The identifier is the
/// JSON payload itself, so Shortcuts round-trips it losslessly.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = ConversationEntityQuery()

    struct Payload: Codable, Hashable {
        var account: UUID
        var destination: Destination
    }

    var id: String
    var title: String
    var serverName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(serverName)")
    }

    var payload: Payload? {
        guard let data = id.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    init(payload: Payload, title: String, serverName: String) {
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        id = String(data: data, encoding: .utf8) ?? ""
        self.title = title
        self.serverName = serverName
    }

    @MainActor
    static func resolve(id: String) -> ConversationEntity? {
        guard let data = id.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        let store = AppModel.shared?.global.stores[payload.account]
        let server = store?.realmName ?? "Zulip"
        let title: String
        switch payload.destination {
        case .channel(let streamId), .channelTopics(let streamId):
            title = "#\(store?.subscriptions[streamId]?.name ?? store?.channels[streamId]?.name ?? "channel")"
        case .conversation(let key):
            title = store.map { key.displayTitle(in: $0) } ?? "Conversation"
        default:
            title = "Conversation"
        }
        return ConversationEntity(payload: payload, title: title, serverName: server)
    }
}

struct ConversationEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        identifiers.compactMap { ConversationEntity.resolve(id: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        Array(Self.candidates(matching: nil).prefix(20))
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        Self.candidates(matching: string)
    }

    /// Channels and recent conversations across every signed-in account.
    @MainActor
    static func candidates(matching text: String?) -> [ConversationEntity] {
        guard let model = AppModel.shared else { return [] }
        var out: [ConversationEntity] = []
        for account in model.global.enabledAccounts {
            guard let store = model.global.stores[account.id] else { continue }
            let server = store.realmName ?? account.realmURL.host() ?? "server"
            for conversation in store.conversations.conversations.prefix(30) {
                let title = conversation.key.displayTitle(in: store)
                guard text.map({ title.localizedCaseInsensitiveContains($0) }) ?? true
                else { continue }
                out.append(ConversationEntity(
                    payload: .init(
                        account: account.id,
                        destination: .conversation(conversation.key)),
                    title: title, serverName: server))
            }
            for (streamId, subscription) in store.subscriptions {
                guard text.map({ subscription.name.localizedCaseInsensitiveContains($0) }) ?? true
                else { continue }
                out.append(ConversationEntity(
                    payload: .init(account: account.id, destination: .channel(streamId: streamId)),
                    title: "#\(subscription.name)", serverName: server))
            }
        }
        return Array(out.prefix(40))
    }
}

/// One signed-in server (for the Focus filter).
struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Server")
    static let defaultQuery = AccountEntityQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct AccountEntityQuery: EntityQuery {
    @MainActor
    private func all() -> [AccountEntity] {
        (AppModel.shared?.global.enabledAccounts ?? []).map {
            AccountEntity(id: $0.id, name: $0.realmName ?? $0.realmURL.host() ?? "Server")
        }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AccountEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AccountEntity] {
        all()
    }
}

// MARK: - Intents

struct OpenConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription(
        "Opens a channel or direct message in Zephyr.")
    static let openAppWhenRun = true

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared, let payload = conversation.payload else {
            throw ZephyrIntentError.notReady
        }
        await model.ensureStore(payload.account)
        model.pendingDestination = PendingDestination(
            account: payload.account, destination: payload.destination)
        Platform.activate()
        return .result()
    }
}

struct SendZulipMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription(
        "Sends a message to a Zephyr conversation. Sends to a channel need a topic.")

    @Parameter(title: "Conversation")
    var conversation: ConversationEntity

    @Parameter(title: "Topic")
    var topic: String?

    @Parameter(title: "Message")
    var messageText: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let model = AppModel.shared, let payload = conversation.payload else {
            throw ZephyrIntentError.notReady
        }
        await model.ensureStore(payload.account)
        guard let store = model.global.stores[payload.account] else {
            throw ZephyrIntentError.notReady
        }
        let destination: SendDestination
        switch payload.destination {
        case .conversation(let key):
            destination = key.sendDestination(selfUserId: store.selfUserId)
        case .channel(let streamId), .channelTopics(let streamId):
            let trimmed = topic?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !trimmed.isEmpty else { throw ZephyrIntentError.needsTopic }
            destination = .topic(streamId: streamId, topic: trimmed)
        default:
            throw ZephyrIntentError.needsTopic
        }
        store.send(messageText, to: destination)
        return .result()
    }
}

/// Zero-setup Siri/Spotlight phrases.
struct ZephyrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: ["Open a conversation in \(.applicationName)"],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: SendZulipMessageIntent(),
            phrases: ["Send a message in \(.applicationName)"],
            shortTitle: "Send Message",
            systemImageName: "paperplane")
    }
}

// MARK: - Focus filter

/// Focus filter: a Focus mode can restrict notifications to one server
/// (e.g. only the work account during Work focus).
struct ZephyrFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Notifying Server"
    static let description = IntentDescription(
        "Choose which server may notify during this Focus.")

    @Parameter(title: "Only Notify")
    var account: AccountEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Notifications",
            subtitle: account.map { "\($0.name)" } ?? "All servers")
    }

    func perform() async throws -> some IntentResult {
        // Read by NotificationManager before posting a banner.
        UserDefaults.standard.set(account?.id.uuidString, forKey: "focusNotifyAccount")
        return .result()
    }
}
