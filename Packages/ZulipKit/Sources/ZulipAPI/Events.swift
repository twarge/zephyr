import Foundation

/// A real-time event from GET /events.
///
/// Decoding is strict for known event types ("crunchy shell": a malformed
/// known event throws, which the sync layer treats as a rebuild trigger) and
/// forward-compatible for unknown ones (`.unexpected`, logged and skipped).
public struct Event: Sendable {
    public var id: Int
    public var kind: Kind

    public enum Kind: Sendable {
        case heartbeat
        case message(MessageEvent)
        case updateMessage(UpdateMessageEvent)
        case deleteMessage(DeleteMessageEvent)
        case updateMessageFlags(UpdateMessageFlagsEvent)
        case realmUserAdd(User)
        case realmUserUpdate(RealmUserUpdate)
        case realmUserRemove(userId: Int)
        case subscriptionAdd([Subscription])
        case subscriptionRemove(streamIds: [Int])
        case streamCreate([ZulipStream])
        case streamDelete(streamIds: [Int])
        case unexpected(type: String, op: String?)
    }
}

public struct MessageEvent: Decodable, Sendable {
    public var message: Message
    public var flags: [String]
    /// Echoed for our own optimistically-sent messages (local echo).
    public var localMessageId: String?
}

/// `update_message`: a content edit and/or a topic/channel move.
public struct UpdateMessageEvent: Decodable, Sendable {
    public var messageId: Int
    public var messageIds: [Int]?
    public var renderedContent: String?
    public var editTimestamp: Int?
    public var streamId: Int?
    public var subject: String?
    public var origSubject: String?
    public var propagateMode: String?
}

public struct DeleteMessageEvent: Decodable, Sendable {
    /// Present with the `bulk_message_deletion` capability (which we set).
    public var messageIds: [Int]?
    public var messageId: Int?

    public var allIds: [Int] { messageIds ?? messageId.map { [$0] } ?? [] }
}

public struct UpdateMessageFlagsEvent: Decodable, Sendable {
    public var op: String
    public var flag: String
    public var messages: [Int]
    public var all: Bool
}

extension Event: Decodable {
    private enum RawKeys: String, CodingKey {
        case id, type, op
    }

    private struct PersonEnvelope<P: Decodable>: Decodable {
        var person: P
    }

    private struct UserIdOnly: Decodable {
        var userId: Int
    }

    private struct SubscriptionsEnvelope: Decodable {
        var subscriptions: [Subscription]
    }

    private struct RemovedSubscriptionsEnvelope: Decodable {
        struct Entry: Decodable {
            var streamId: Int
        }
        var subscriptions: [Entry]
    }

    private struct StreamsEnvelope: Decodable {
        var streams: [ZulipStream]
    }

    private struct DeletedStreamsEnvelope: Decodable {
        struct Entry: Decodable {
            var streamId: Int
        }
        var streams: [Entry]?
        var streamIds: [Int]?

        var allIds: [Int] { streamIds ?? streams?.map(\.streamId) ?? [] }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RawKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        let type = try container.decode(String.self, forKey: .type)
        let op = try container.decodeIfPresent(String.self, forKey: .op)

        switch (type, op) {
        case ("heartbeat", _):
            kind = .heartbeat
        case ("message", _):
            kind = .message(try MessageEvent(from: decoder))
        case ("update_message", _):
            kind = .updateMessage(try UpdateMessageEvent(from: decoder))
        case ("delete_message", _):
            kind = .deleteMessage(try DeleteMessageEvent(from: decoder))
        case ("update_message_flags", "add"), ("update_message_flags", "remove"):
            kind = .updateMessageFlags(try UpdateMessageFlagsEvent(from: decoder))
        case ("realm_user", "add"):
            kind = .realmUserAdd(try PersonEnvelope<User>(from: decoder).person)
        case ("realm_user", "update"):
            kind = .realmUserUpdate(try PersonEnvelope<RealmUserUpdate>(from: decoder).person)
        case ("realm_user", "remove"):
            kind = .realmUserRemove(userId: try PersonEnvelope<UserIdOnly>(from: decoder).person.userId)
        case ("subscription", "add"):
            kind = .subscriptionAdd(try SubscriptionsEnvelope(from: decoder).subscriptions)
        case ("subscription", "remove"):
            kind = .subscriptionRemove(
                streamIds: try RemovedSubscriptionsEnvelope(from: decoder).subscriptions.map(\.streamId))
        case ("stream", "create"):
            kind = .streamCreate(try StreamsEnvelope(from: decoder).streams)
        case ("stream", "delete"):
            kind = .streamDelete(streamIds: try DeletedStreamsEnvelope(from: decoder).allIds)
        default:
            kind = .unexpected(type: type, op: op)
        }
    }
}
