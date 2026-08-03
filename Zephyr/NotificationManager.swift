#if canImport(AppKit)
import AppKit
#endif
import UserNotifications
import ZulipAPI
import ZulipContent
import ZulipModel

/// Local notifications from the live event stream (Zulip has no desktop push
/// service — see docs/PROTOCOL.md §6): DMs and mentions, with inline reply
/// and mark-as-read actions. Notifications only fire while Zephyr runs.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private weak var appModel: AppModel?
    private var authorized = false

    private static let categoryId = "MESSAGE"
    private static let replyActionId = "REPLY"
    private static let markReadActionId = "MARK_READ"

    func setup(appModel: AppModel) {
        self.appModel = appModel
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionId, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
        let markRead = UNNotificationAction(
            identifier: Self.markReadActionId, title: "Mark as Read", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryId, actions: [reply, markRead],
                intentIdentifiers: [], options: [])
        ])
        Task {
            authorized =
                (try? await center.requestAuthorization(options: [.alert, .sound, .badge]))
                ?? false
        }
    }

    /// Decides whether a message event deserves a banner and posts it.
    func handleMessageEvent(_ event: MessageEvent, accountId: Account.ID, store: PerAccountStore) {
        guard authorized, UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        else { return }
        let message = event.message
        guard message.senderId != store.selfUserId else { return }
        guard !event.flags.contains("read") else { return }

        let isMention = !Set(event.flags).isDisjoint(with: [
            "mentioned", "wildcard_mentioned", "stream_wildcard_mentioned",
            "topic_wildcard_mentioned",
        ])
        // Policy (v1): every DM, and channel messages that mention you.
        guard message.type == .private || isMention else { return }

        guard let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId)
        else { return }
        // No banner for the conversation you're actively reading.
        if Platform.isActive, appModel?.activeConversation == key {
            return
        }

        let content = UNMutableNotificationContent()
        content.categoryIdentifier = Self.categoryId
        switch key {
        case .topic(let streamId, let topic):
            let channel = store.channels[streamId]?.name ?? "channel"
            content.title = message.senderFullName
            content.subtitle = "#\(channel) › \(TopicName.displayName(topic))"
        case .dm:
            content.title = message.senderFullName
            if (key.dmParticipantIds?.count ?? 0) > 1 {
                content.subtitle = key.displayTitle(in: store)
            }
        }
        content.body = String(ContentParser.parse(html: message.content).plainText.prefix(300))
        content.sound = .default
        content.userInfo = Self.userInfo(accountId: accountId, key: key)

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "msg-\(message.id)", content: content, trigger: nil))
    }

    // MARK: Round-tripping the conversation through userInfo

    private static func userInfo(accountId: Account.ID, key: ConversationKey) -> [String: Any] {
        var info: [String: Any] = ["account": accountId.uuidString]
        switch key {
        case .topic(let streamId, let topic):
            info["stream"] = streamId
            info["topic"] = topic
        case .dm(let joined):
            info["dm"] = joined
        }
        return info
    }

    private nonisolated static func conversationKey(from info: [AnyHashable: Any]) -> ConversationKey? {
        if let streamId = info["stream"] as? Int, let topic = info["topic"] as? String {
            return .topic(streamId: streamId, topic: topic)
        }
        if let joined = info["dm"] as? String {
            return .dm(joined)
        }
        return nil
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Extract Sendable values before hopping isolation.
        let info = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        let accountId = (info["account"] as? String).flatMap(UUID.init(uuidString:))
        let parsedKey = Self.conversationKey(from: info)
        await MainActor.run {
            guard let appModel = self.appModel,
                  let accountId,
                  let store = appModel.global.stores[accountId],
                  let key = parsedKey
            else { return }
            switch actionId {
            case Self.replyActionId:
                if let replyText, !replyText.isEmpty {
                    store.send(replyText, to: key.sendDestination(selfUserId: store.selfUserId))
                }
            case Self.markReadActionId:
                store.markConversationRead(key)
            default:
                // Clicking the banner opens the conversation.
                appModel.pendingDestination = .conversation(key)
                Platform.activate()
            }
        }
    }
}
