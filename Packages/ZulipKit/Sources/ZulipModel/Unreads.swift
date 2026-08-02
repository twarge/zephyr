import Foundation
import Observation
import ZulipAPI

/// Identifies a conversation for unread bookkeeping (and, later, the sidebar).
public enum ConversationKey: Hashable, Sendable {
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

    public init(snapshot: UnreadMessagesSnapshot?, selfUserId: Int) {
        self.selfUserId = selfUserId
        guard let snapshot else { return }
        oldUnreadsMissing = snapshot.oldUnreadsMissing
        mentionIds = Set(snapshot.mentions)
        for dm in snapshot.pms where !dm.unreadMessageIds.isEmpty {
            unreadIds[.dm(String(dm.otherUserId))] = Set(dm.unreadMessageIds)
        }
        for huddle in snapshot.huddles where !huddle.unreadMessageIds.isEmpty {
            let participants = huddle.userIdsString.split(separator: ",").compactMap { Int($0) }
            let key = Self.dmKey(participantIds: participants, selfUserId: selfUserId)
            unreadIds[key, default: []].formUnion(huddle.unreadMessageIds)
        }
        for channel in snapshot.streams where !channel.unreadMessageIds.isEmpty {
            let key = ConversationKey.topic(streamId: channel.streamId, topic: channel.topic)
            unreadIds[key, default: []].formUnion(channel.unreadMessageIds)
        }
    }

    public static func dmKey(participantIds: [Int], selfUserId: Int) -> ConversationKey {
        .dm(
            participantIds
                .filter { $0 != selfUserId }
                .sorted()
                .map(String.init)
                .joined(separator: ","))
    }

    public static func conversationKey(for message: Message, selfUserId: Int) -> ConversationKey? {
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
        unreadIds[key, default: []].insert(message.id)
        if !Set(flags).isDisjoint(with: Self.mentionFlags) {
            mentionIds.insert(message.id)
        }
    }

    /// Applies an `update_message_flags` event for the `read` flag.
    /// `locate` resolves a message id in the canonical message map, needed to
    /// re-file a message when `read` is removed.
    func handleFlagsEvent(
        op: UpdateFlagsOp,
        flag: String,
        ids: [Int],
        all: Bool,
        locate: (Int) -> Message?
    ) {
        guard flag == "read" else { return }
        switch op {
        case .add:
            if all {
                unreadIds = [:]
                mentionIds = []
                oldUnreadsMissing = false
            } else {
                removeMessages(ids: ids)
            }
        case .remove:
            for id in ids {
                guard let message = locate(id),
                      let key = Self.conversationKey(for: message, selfUserId: selfUserId)
                else { continue }
                unreadIds[key, default: []].insert(id)
            }
        }
    }

    func removeMessages(ids: [Int]) {
        for id in ids {
            mentionIds.remove(id)
            for (key, var set) in unreadIds where set.contains(id) {
                set.remove(id)
                if set.isEmpty {
                    unreadIds.removeValue(forKey: key)
                } else {
                    unreadIds[key] = set
                }
            }
        }
    }
}
