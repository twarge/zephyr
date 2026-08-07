#if canImport(AppKit)
import AppKit
#endif
import Intents
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

    /// Wires the delegate and action categories. Called from `AppModel.init`
    /// so a notification action that launches the app (iOS launches in the
    /// background for a reply) finds the delegate installed; never prompts.
    func attach(appModel: AppModel) {
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
    }

    /// Requests authorization (the user-visible prompt); called once an
    /// account exists.
    func setup(appModel: AppModel) {
        attach(appModel: appModel)
        Task {
            authorized =
                (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]))
                ?? false
        }
    }

    /// Decides whether a message event deserves a banner and posts it.
    func handleMessageEvent(_ event: MessageEvent, accountId: Account.ID, store: PerAccountStore) {
        guard authorized, UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        else { return }
        // Focus filter: the active Focus may restrict banners to one server.
        if let only = UserDefaults.standard.string(forKey: "focusNotifyAccount"),
           let onlyId = UUID(uuidString: only), onlyId != accountId {
            return
        }
        let message = event.message
        guard message.senderId != store.selfUserId else { return }
        guard !event.flags.contains("read") else { return }

        let isMention = !Set(event.flags).isDisjoint(with: [
            "mentioned", "wildcard_mentioned", "stream_wildcard_mentioned",
            "topic_wildcard_mentioned",
        ])
        // Policy: every DM, channel messages that mention you, and all
        // messages in channels with per-channel notifications on — except
        // muted topics.
        let channelNotifies = message.streamId.map {
            store.subscriptions[$0]?.desktopNotifications == true
        } ?? false
        guard message.type == .private || isMention || channelNotifies else { return }
        if let streamId = message.streamId,
           store.topicVisibility(streamId: streamId, topic: message.subject) == .muted,
           !isMention {
            return
        }

        guard let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId)
        else { return }
        // No banner for the conversation you're actively reading.
        if Platform.isActive,
           appModel?.activeConversation == ActiveConversation(account: accountId, key: key) {
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

        // Communication notification: donating the receive intent lets the
        // system style the banner like Messages (sender-first) and lets
        // Focus break through for people. Falls back to the plain content
        // if updating fails (e.g. the entitlement is missing).
        var finalContent: UNNotificationContent = content
        let senderId = "zephyr-\(accountId.uuidString)-\(message.senderId)"
        let sender = INPerson(
            personHandle: INPersonHandle(value: senderId, type: .unknown),
            nameComponents: nil, displayName: message.senderFullName, image: nil,
            contactIdentifier: nil, customIdentifier: senderId)
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: INSpeakableString(
                spokenPhrase: content.subtitle.isEmpty ? content.title : content.subtitle),
            conversationIdentifier: "\(accountId.uuidString)|\(content.subtitle)|\(content.title)",
            serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate()
        if let updated = try? content.updating(from: intent) {
            finalContent = updated
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "msg-\(message.id)", content: finalContent, trigger: nil))
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
        guard let accountId = (info["account"] as? String).flatMap(UUID.init(uuidString:)),
              let key = Self.conversationKey(from: info)
        else { return }
        await handleResponse(
            accountId: accountId, key: key, actionId: actionId, replyText: replyText)
    }

    private func handleResponse(
        accountId: Account.ID, key: ConversationKey, actionId: String, replyText: String?
    ) async {
        guard let appModel else { return }
        // iOS grants a short grace period for handling; hold it explicitly.
        let endActivity = BackgroundActivity.begin("notification-response")
        defer { endActivity() }
        switch actionId {
        case Self.replyActionId, Self.markReadActionId:
            // Cold launches (a reply from Notification Center after the app
            // was terminated) load the account's store on demand.
            guard let store = try? await appModel.global.perAccountStore(for: accountId)
            else { return }
            if actionId == Self.replyActionId {
                if let replyText, !replyText.isEmpty {
                    store.send(replyText, to: key.sendDestination(selfUserId: store.selfUserId))
                }
            } else {
                store.markConversationRead(key)
            }
        default:
            // Clicking the banner opens the conversation.
            appModel.pendingDestination = PendingDestination(
                account: accountId, destination: .conversation(key))
            Platform.activate()
        }
    }
}
