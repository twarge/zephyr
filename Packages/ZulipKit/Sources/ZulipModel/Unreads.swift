import Foundation
import Observation
import ZulipAPI

/// Identifies a conversation for unread bookkeeping (and, later, the sidebar).
public enum ConversationKey: Hashable, Sendable, Codable {
    /// DM thread, keyed by the sorted non-self participant ids joined with ","
    /// ("" would be a self-DM; "5" a 1:1; "5,9" a group DM).
    case dm(String)
    case topic(streamId: Int, topic: String)
}

public enum UpdateFlagsOp: String, Sendable {
    case add
    case remove
}

/// Unread-message bookkeeping: seeded from the register snapshot's
/// `unread_msgs`, maintained from `message` and `update_message_flags` events.
@MainActor
@Observable
public final class Unreads {
    public let selfUserId: Int
    public private(set) var unreadIds: [ConversationKey: Set<Int>] = [:]
    public private(set) var mentionIds: Set<Int> = []
    /// True when the snapshot was truncated (very old unreads not included).
    public private(set) var oldUnreadsMissing = false

    public var totalCount: Int {
        unreadIds.values.reduce(0) { $0 + $1.count }
    }

    /// Unread direct messages (for badge policies).
    public var dmCount: Int {
        unreadIds.reduce(0) { total, entry in
            if case .dm = entry.key {
                return total + entry.value.count
            }
            return total
        }
    }

    /// The "DMs and mentions" badge: every unread DM plus mentions
    /// elsewhere. A DM that also mentions you is in both `unreadIds`
    /// and `mentionIds` — naive addition counted it twice.
    public var dmAndMentionCount: Int {
        var count = 0
        var dmIds: Set<Int> = []
        for (key, ids) in unreadIds where isDm(key) {
            count += ids.count
            dmIds.formUnion(ids)
        }
        return count + mentionIds.subtracting(dmIds).count
    }

    private nonisolated func isDm(_ key: ConversationKey) -> Bool {
        if case .dm = key { true } else { false }
    }

    public func unreadCount(inChannel streamId: Int) -> Int {
        unreadIds.reduce(0) { total, entry in
            if case .topic(let id, _) = entry.key, id == streamId {
                return total + entry.value.count
            }
            return total
        }
    }

    /// Reverse index of `unreadIds`, so removal and moves are O(ids).
    @ObservationIgnored private var keyById: [Int: ConversationKey] = [:]

    public init(snapshot: UnreadMessagesSnapshot?, selfUserId: Int) {
        self.selfUserId = selfUserId
        guard let snapshot else { return }
        oldUnreadsMissing = snapshot.oldUnreadsMissing
        mentionIds = Set(snapshot.mentions)
        var byKey: [ConversationKey: Set<Int>] = [:]
        for dm in snapshot.pms where !dm.unreadMessageIds.isEmpty {
            byKey[.dm(String(dm.otherUserId)), default: []].formUnion(dm.unreadMessageIds)
        }
        for huddle in snapshot.huddles where !huddle.unreadMessageIds.isEmpty {
            let participants = huddle.userIdsString.split(separator: ",").compactMap { Int($0) }
            let key = Self.dmKey(participantIds: participants, selfUserId: selfUserId)
            byKey[key, default: []].formUnion(huddle.unreadMessageIds)
        }
        for channel in snapshot.streams where !channel.unreadMessageIds.isEmpty {
            let key = ConversationKey.topic(streamId: channel.streamId, topic: channel.topic)
            byKey[key, default: []].formUnion(channel.unreadMessageIds)
        }
        unreadIds = byKey
        for (key, ids) in byKey {
            for id in ids { keyById[id] = key }
        }
    }

    /// The conversation an unread message is filed under.
    public func conversationKey(ofUnread id: Int) -> ConversationKey? {
        keyById[id]
    }

    public nonisolated static func dmKey(participantIds: [Int], selfUserId: Int) -> ConversationKey {
        .dm(
            participantIds
                .filter { $0 != selfUserId }
                .sorted()
                .map(String.init)
                .joined(separator: ","))
    }

    public nonisolated static func conversationKey(
        for message: Message, selfUserId: Int
    ) -> ConversationKey? {
        switch message.type {
        case .stream:
            guard let streamId = message.streamId else { return nil }
            return .topic(streamId: streamId, topic: message.subject)
        case .private:
            guard case .users(let recipients) = message.displayRecipient else { return nil }
            return dmKey(participantIds: recipients.map(\.id), selfUserId: selfUserId)
        }
    }

    private static let mentionFlags: Set<String> = [
        "mentioned", "wildcard_mentioned", "stream_wildcard_mentioned", "topic_wildcard_mentioned",
    ]

    func handleMessage(_ message: Message, flags: [String]) {
        guard message.senderId != selfUserId, !flags.contains("read") else { return }
        guard let key = Self.conversationKey(for: message, selfUserId: selfUserId) else { return }
        insert(message.id, into: key)
        if !Set(flags).isDisjoint(with: Self.mentionFlags) {
            mentionIds.insert(message.id)
        }
    }

    /// Applies an `update_message_flags` event for the `read` flag.
    /// `locate` resolves a message id in the canonical message map, and
    /// `detail` the event's `message_details` — together they re-file a
    /// message when `read` is removed, loaded or not.
    func handleFlagsEvent(
        op: UpdateFlagsOp,
        flag: String,
        ids: [Int],
        all: Bool,
        locate: (Int) -> Message?,
        detail: (Int) -> UpdateMessageFlagsEvent.MessageDetail? = { _ in nil }
    ) {
        guard flag == "read" else { return }
        switch op {
        case .add:
            if all {
                unreadIds = [:]
                keyById = [:]
                mentionIds = []
                oldUnreadsMissing = false
            } else {
                removeMessages(ids: ids)
            }
        case .remove:
            var byKey = unreadIds
            var mentions = mentionIds
            for id in ids {
                let message = locate(id)
                let detail = detail(id)
                guard let key = message.flatMap({
                    Self.conversationKey(for: $0, selfUserId: selfUserId)
                }) ?? detail.flatMap({ Self.conversationKey(for: $0, selfUserId: selfUserId) })
                else { continue }
                if let old = keyById[id], old != key {
                    Self.remove(id, from: old, in: &byKey)
                }
                byKey[key, default: []].insert(id)
                keyById[id] = key
                let mentioned = detail?.mentioned
                    ?? message.map { !Set($0.flags ?? []).isDisjoint(with: Self.mentionFlags) }
                    ?? false
                if mentioned { mentions.insert(id) }
            }
            unreadIds = byKey
            if mentions != mentionIds { mentionIds = mentions }
        }
    }

    /// Re-files unread messages a topic/channel move carried elsewhere.
    /// Works from the bookkeeping alone, so moved ids never loaded move
    /// too; `belongs` limits it to ids filed under the move's source.
    func handleMove(
        ids: [Int], to newKey: ConversationKey, belongs: (ConversationKey) -> Bool
    ) {
        var byKey = unreadIds
        var changed = false
        for id in ids {
            guard let old = keyById[id], old != newKey, belongs(old) else { continue }
            Self.remove(id, from: old, in: &byKey)
            byKey[newKey, default: []].insert(id)
            keyById[id] = newKey
            changed = true
        }
        if changed { unreadIds = byKey }
    }

    func removeMessages(ids: some Sequence<Int>) {
        var byKey: [ConversationKey: Set<Int>]?
        for id in ids {
            if mentionIds.contains(id) { mentionIds.remove(id) }
            guard let key = keyById.removeValue(forKey: id) else { continue }
            if byKey == nil { byKey = unreadIds }
            Self.remove(id, from: key, in: &byKey!)
        }
        if let byKey { unreadIds = byKey }
    }

    private func insert(_ id: Int, into key: ConversationKey) {
        if let old = keyById[id] {
            guard old != key else { return }
            var byKey = unreadIds
            Self.remove(id, from: old, in: &byKey)
            byKey[key, default: []].insert(id)
            unreadIds = byKey
        } else {
            unreadIds[key, default: []].insert(id)
        }
        keyById[id] = key
    }

    private static func remove(
        _ id: Int, from key: ConversationKey, in byKey: inout [ConversationKey: Set<Int>]
    ) {
        guard var set = byKey[key] else { return }
        set.remove(id)
        byKey[key] = set.isEmpty ? nil : set
    }

    nonisolated static func conversationKey(
        for detail: UpdateMessageFlagsEvent.MessageDetail, selfUserId: Int
    ) -> ConversationKey? {
        switch detail.type {
        case "stream", "channel":
            guard let streamId = detail.streamId else { return nil }
            return .topic(streamId: streamId, topic: detail.topic ?? "")
        case "private", "direct":
            return dmKey(participantIds: detail.userIds ?? [], selfUserId: selfUserId)
        default:
            return nil
        }
    }
}
