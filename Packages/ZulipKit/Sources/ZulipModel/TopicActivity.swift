import Foundation
import ZulipAPI
import ZulipContent

/// Summary uses a canonical identity, keeping the latest server spelling for
/// display and navigation. A rename/move removes messages from the old key.
public struct TopicActivityID: Hashable, Codable, Sendable {
    public let streamId: Int
    public let topic: String

    public init(streamId: Int, topic: String) {
        self.streamId = streamId
        self.topic = TopicName.canonical(topic).lowercased()
    }

    public init?(_ message: Message) {
        guard message.type == .stream, let id = message.streamId else { return nil }
        self.init(streamId: id, topic: message.subject)
    }
}

public struct TopicActivity: Identifiable, Sendable {
    public enum Indicator: Sendable, Equatable {
        case awaitingResponse, unseen, participated, seen
    }

    public let id: TopicActivityID
    public let topic: String
    public let messages: [Message]
    public let lastMessageId: Int
    public let timestamp: Int
    public let unansweredMentionIds: [Int]
    public let needsReactionReview: Bool
    public let hasReplied: Bool
    public let hasReacted: Bool

    public var conversation: ConversationKey { .topic(streamId: id.streamId, topic: topic) }

    public func indicator(unreadCount: Int) -> Indicator {
        if !unansweredMentionIds.isEmpty { return .awaitingResponse }
        if unreadCount > 0 { return .unseen }
        return hasReplied || hasReacted ? .participated : .seen
    }
}

struct TopicMentionRecord: Codable, Sendable, Equatable {
    let message: Message
    let since: Int
    let reactionNeedsConfirmation: Bool
}

/// Pure, testable activity state. It never contains outbox entries or
/// optimistic reactions; only server events/fetches confirm participation.
public struct TopicActivityIndex: Sendable {
    public let selfUserId: Int
    private(set) var messages: [Int: Message] = [:]
    private var groups: [TopicActivityID: Set<Int>] = [:]
    private var mentionSince: [Int: Int] = [:]
    private var uncertainReactions: Set<Int> = []
    private var liveOrder = 0
    private var replyOrder: [Int: Int] = [:]
    private var mentionOrder: [Int: Int] = [:]

    public init(selfUserId: Int) { self.selfUserId = selfUserId }

    public mutating func upsert(_ message: Message, live: Bool = false) {
        let old = messages[message.id]
        let previousMention = mentionSince[message.id]
        if live {
            liveOrder &+= 1
            if old == nil && message.senderId == selfUserId { replyOrder[message.id] = liveOrder }
        }
        if let oldKey = old.flatMap(TopicActivityID.init) {
            groups[oldKey]?.remove(message.id)
            if groups[oldKey]?.isEmpty == true { groups.removeValue(forKey: oldKey) }
        }
        guard let key = TopicActivityID(message) else { remove([message.id]); return }
        messages[message.id] = message
        groups[key, default: []].insert(message.id)
        if old?.content != message.content {
            let mentionsSelf = message.senderId != selfUserId
                && message.content.contains("user-mention")
                && ContentParser.parse(html: message.content).mentions(userId: selfUserId)
            if mentionsSelf {
                mentionSince[message.id] = previousMention
                    ?? message.lastEditTimestamp ?? message.timestamp
                if previousMention == nil && message.lastEditTimestamp != nil {
                    uncertainReactions.insert(message.id)
                    if live { mentionOrder[message.id] = liveOrder }
                }
            } else {
                mentionSince.removeValue(forKey: message.id)
                uncertainReactions.remove(message.id)
            }
        }
    }

    public mutating func remove(_ ids: [Int]) {
        for id in ids {
            if let message = messages.removeValue(forKey: id), let key = TopicActivityID(message) {
                groups[key]?.remove(id)
                if groups[key]?.isEmpty == true { groups.removeValue(forKey: key) }
            }
            mentionSince.removeValue(forKey: id)
            uncertainReactions.remove(id)
            replyOrder.removeValue(forKey: id)
            mentionOrder.removeValue(forKey: id)
        }
    }

    public mutating func applyReaction(_ event: ReactionEvent) {
        guard var message = messages[event.messageId] else { return }
        if event.op == "add" {
            if !message.reactions.contains(event.reaction) { message.reactions.append(event.reaction) }
            if event.userId == selfUserId { uncertainReactions.remove(message.id) }
        } else if event.op == "remove" {
            message.reactions.removeAll {
                $0.userId == event.userId && $0.emojiCode == event.emojiCode
                    && $0.reactionType == event.reactionType
            }
        }
        messages[message.id] = message
    }

    public var mentionMessages: [Message] {
        mentionSince.keys.compactMap { messages[$0] }
    }

    /// Ordered by id: the caller compares successive record sets to decide
    /// whether a write is needed, and a Set's iteration order is not stable.
    func mentionRecords(ids: Set<Int>) -> [TopicMentionRecord] {
        ids.compactMap { id in
            guard let message = messages[id], let since = mentionSince[id] else { return nil }
            return TopicMentionRecord(message: message, since: since,
                                     reactionNeedsConfirmation: uncertainReactions.contains(id))
        }.sorted { $0.message.id < $1.message.id }
    }

    mutating func restore(_ record: TopicMentionRecord) {
        upsert(record.message)
        guard mentionSince[record.message.id] != nil else { return }
        mentionSince[record.message.id] = record.since
        if record.reactionNeedsConfirmation { uncertainReactions.insert(record.message.id) }
        else { uncertainReactions.remove(record.message.id) }
    }

    public func activities(since cutoff: Int, topics: Set<TopicActivityID>? = nil) -> [TopicActivity] {
        let selected = topics.map { keys in
            Dictionary(uniqueKeysWithValues: keys.compactMap { key in groups[key].map { (key, $0) } })
        } ?? groups
        return selected.compactMap { key, ids in
            let ordered = ids.compactMap { messages[$0] }.sorted { $0.id < $1.id }
            guard let latest = ordered.last else { return nil }
            let own = ordered.filter { $0.senderId == selfUserId }
            let pending = ordered.filter { message in
                guard let since = mentionSince[message.id] else { return false }
                let replied = own.contains { reply in
                    guard reply.timestamp >= since && reply.id > message.id else { return false }
                    if reply.timestamp == since && message.lastEditTimestamp != nil {
                        // Second-resolution timestamps cannot order a new
                        // mention edit against a reply in the same second.
                        guard let editOrder = mentionOrder[message.id],
                              let sentOrder = replyOrder[reply.id] else { return false }
                        return sentOrder > editOrder
                    }
                    return true
                }
                let reacted = !uncertainReactions.contains(message.id)
                    && message.reactions.contains { $0.userId == selfUserId }
                return !replied && !reacted
            }.map(\.id)
            guard latest.timestamp >= cutoff || !pending.isEmpty else { return nil }
            let recent = ordered.filter { $0.timestamp >= cutoff }
            // Old unanswered requests still get a useful source excerpt.
            let source = recent.isEmpty ? ordered.suffix(30) : recent.suffix(50)
            return TopicActivity(
                id: key, topic: latest.subject, messages: Array(source),
                lastMessageId: latest.id, timestamp: latest.timestamp,
                unansweredMentionIds: pending,
                needsReactionReview: pending.contains { id in
                    uncertainReactions.contains(id)
                        && messages[id]?.reactions.contains { $0.userId == selfUserId } == true
                },
                hasReplied: recent.contains { $0.senderId == selfUserId },
                hasReacted: recent.contains { message in
                    message.senderId != selfUserId
                        && message.reactions.contains { $0.userId == selfUserId }
                })
        }.sorted { $0.lastMessageId > $1.lastMessageId }
    }
}
