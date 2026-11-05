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
    /// `conversations`, sorted once per change rather than on every read:
    /// the sidebar and Recent read it several times a render.
    @ObservationIgnored private var sorted: [Conversation]?

    public var conversations: [Conversation] {
        let current = byKey  // Read every time: it's what observation tracks.
        if let sorted { return sorted }
        let result = current.values.sorted { $0.lastMessageId > $1.lastMessageId }
        sorted = result
        return result
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
        sorted = nil
    }

    /// Feed messages (from any fetch) to establish recency and snippets —
    /// as one change, not one per message (a launch restore seeds
    /// thousands).
    public func seed(messages: [Message], selfUserId: Int) {
        var updated = byKey
        var changed = false
        for message in messages {
            guard let latest = Self.latest(message, selfUserId: selfUserId, in: updated)
            else { continue }
            updated[latest.key] = latest
            changed = true
        }
        guard changed else { return }
        byKey = updated
        sorted = nil
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
        guard let latest = Self.latest(message, selfUserId: selfUserId, in: byKey) else { return }
        byKey[latest.key] = latest
        sorted = nil
    }

    /// The conversation entry the message makes, when it is its
    /// conversation's latest — nil when it's older, or not one of the
    /// user's conversations.
    private static func latest(
        _ message: Message, selfUserId: Int, in byKey: [ConversationKey: Conversation]
    ) -> Conversation? {
        // Never delivered to the user (a public-channel search result, a
        // channel they aren't in): not one of their conversations.
        guard !(message.flags ?? []).contains("historical") else { return nil }
        guard let key = Unreads.conversationKey(for: message, selfUserId: selfUserId)
        else { return nil }
        guard (byKey[key]?.lastMessageId ?? -1) <= message.id else { return nil }
        return Conversation(
            key: key, lastMessageId: message.id, timestamp: message.timestamp,
            snippetHTML: message.content, senderName: message.senderFullName)
    }
}
