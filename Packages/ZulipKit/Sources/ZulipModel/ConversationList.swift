import Foundation
import Observation
import ZulipAPI

extension ConversationKey {
    /// The non-self participant ids of a DM conversation key.
    public var dmParticipantIds: [Int]? {
        guard case .dm(let joined) = self else { return nil }
        return joined.isEmpty ? [] : joined.split(separator: ",").compactMap { Int($0) }
    }

    /// The narrow that shows this conversation. The self-DM key has an empty
    /// participant set — its narrow must query dm:[selfUserId], not dm:[].
    public func narrow(selfUserId: Int) -> Narrow {
        switch self {
        case .dm:
            let ids = dmParticipantIds ?? []
            return .dm(userIds: ids.isEmpty ? [selfUserId] : ids)
        case .topic(let streamId, let topic):
            return .topic(streamId: streamId, topic: topic)
        }
    }
}

/// The unified sidebar model: every conversation (DM thread or channel topic)
/// with known activity, sorted by recency (message ids are globally
/// monotonic, so `lastMessageId` IS the recency order).
///
/// Seeded from the register snapshot (`recent_private_conversations` +
/// unreads), enriched by a combined-feed fetch, and maintained from events.
@MainActor
@Observable
public final class ConversationList {
    public struct Conversation: Identifiable, Sendable, Equatable {
        public var key: ConversationKey
        public var lastMessageId: Int
        /// Unix timestamp of the last message, when we've seen it.
        public var timestamp: Int?
        /// Raw rendered HTML of the last message (UI flattens for display).
        public var snippetHTML: String?
        public var senderName: String?

        public var id: ConversationKey { key }
    }

    private var byKey: [ConversationKey: Conversation] = [:]

    public var conversations: [Conversation] {
        byKey.values.sorted { $0.lastMessageId > $1.lastMessageId }
    }

    init(snapshot: InitialSnapshot, selfUserId: Int) {
        for recent in snapshot.recentPrivateConversations ?? [] {
            let key = Unreads.dmKey(participantIds: recent.userIds, selfUserId: selfUserId)
            note(key: key, messageId: recent.maxMessageId)
        }
        for channel in snapshot.unreadMsgs?.streams ?? [] {
            guard let maxId = channel.unreadMessageIds.max() else { continue }
            note(key: .topic(streamId: channel.streamId, topic: channel.topic), messageId: maxId)
        }
    }

    private func note(key: ConversationKey, messageId: Int) {
        if let existing = byKey[key], existing.lastMessageId >= messageId { return }
        byKey[key] = Conversation(
            key: key, lastMessageId: messageId,
            timestamp: byKey[key]?.timestamp, snippetHTML: byKey[key]?.snippetHTML,
            senderName: byKey[key]?.senderName)
    }

    /// Feed messages (from any fetch) to establish recency and snippets.
    public func seed(messages: [Message], selfUserId: Int) {
        for message in messages {
            noteMessage(message, selfUserId: selfUserId)
        }
    }

    /// Latest DM message id per participant — the "recently messaged"
    /// signal for mention and recipient ranking.
    public var dmRecencyByUser: [Int: Int] {
        var byUser: [Int: Int] = [:]
        for conversation in byKey.values {
            guard let ids = conversation.key.dmParticipantIds else { continue }
            for id in ids {
                byUser[id] = max(byUser[id] ?? 0, conversation.lastMessageId)
            }
        }
        return byUser
    }

    /// Latest known message id per channel, for channel ranking.
    public var channelRecency: [Int: Int] {
        var byStream: [Int: Int] = [:]
        for conversation in byKey.values {
            if case .topic(let streamId, _) = conversation.key {
                byStream[streamId] = max(byStream[streamId] ?? 0, conversation.lastMessageId)
            }
        }
        return byStream
    }

    func noteMessage(_ message: Message, selfUserId: Int) {
        guard let key = Unreads.conversationKey(for: message, selfUserId: selfUserId) else { return }
        guard (byKey[key]?.lastMessageId ?? -1) <= message.id else { return }
        byKey[key] = Conversation(
            key: key, lastMessageId: message.id, timestamp: message.timestamp,
            snippetHTML: message.content, senderName: message.senderFullName)
    }
}
