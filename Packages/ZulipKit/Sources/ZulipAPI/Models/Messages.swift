import Foundation

public enum MessageType: String, Codable, Sendable {
    case stream
    case `private`
}

/// One entry of a DM message's `display_recipient` array.
public struct DmRecipient: Codable, Sendable, Hashable {
    public var id: Int
    public var email: String?
    public var fullName: String?
}

/// `display_recipient` is polymorphic: the channel name for channel messages,
/// the recipient users (including the sender) for DMs.
public enum DisplayRecipient: Sendable, Hashable {
    case channelName(String)
    case users([DmRecipient])
}

extension DisplayRecipient: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .channelName(name)
        } else {
            self = .users(try container.decode([DmRecipient].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .channelName(let name): try container.encode(name)
        case .users(let users): try container.encode(users)
        }
    }
}

public struct Reaction: Codable, Sendable, Hashable {
    public var emojiName: String
    public var emojiCode: String
    public var reactionType: String
    public var userId: Int

    public init(emojiName: String, emojiCode: String, reactionType: String, userId: Int) {
        self.emojiName = emojiName
        self.emojiCode = emojiCode
        self.reactionType = reactionType
        self.userId = userId
    }
}

/// A message as returned by GET /messages and `message` events, with
/// `apply_markdown: true` (so `content` is server-rendered HTML). Encodable
/// so the offline message cache can round-trip it through `ZulipJSON`.
public struct Message: Codable, Sendable, Identifiable, Equatable {
    public var id: Int
    public var senderId: Int
    public var senderFullName: String
    public var timestamp: Int
    public var type: MessageType
    public var content: String
    public var contentType: String?
    public var streamId: Int?
    /// The topic; the API's legacy field name is `subject`.
    public var subject: String
    public var displayRecipient: DisplayRecipient
    public var reactions: [Reaction]
    /// Present in fetched messages; absent inside `message` events (the event
    /// carries flags at its top level).
    public var flags: [String]?
    public var lastEditTimestamp: Int?
    /// For `search` narrows only: the content/topic with matched terms
    /// wrapped in `<span class="highlight">`.
    public var matchContent: String?
    public var matchSubject: String?
    /// Widget data (polls, todo lists): the message's content is a
    /// placeholder; the real state is built from these.
    public var submessages: [Submessage]?

    public var topic: String { subject }
}

/// One widget submessage: `content` is a JSON-encoded widget event.
public struct Submessage: Codable, Sendable, Equatable {
    public var msgType: String
    public var content: String
    public var senderId: Int

    public init(msgType: String, content: String, senderId: Int) {
        self.msgType = msgType
        self.content = content
        self.senderId = senderId
    }
}

// MARK: - Unreads (register payload)

public struct UnreadDmSnapshot: Decodable, Sendable {
    public var otherUserId: Int
    public var unreadMessageIds: [Int]
}

public struct UnreadChannelSnapshot: Decodable, Sendable {
    public var streamId: Int
    public var topic: String
    public var unreadMessageIds: [Int]
}

public struct UnreadHuddleSnapshot: Decodable, Sendable {
    /// All participant user ids (including self), comma-joined, e.g. "1,2,3".
    public var userIdsString: String
    public var unreadMessageIds: [Int]
}

/// The register response's `unread_msgs` object. Covers only the most recent
/// ~50k unreads; `oldUnreadsMissing` signals truncation.
public struct UnreadMessagesSnapshot: Decodable, Sendable {
    public var count: Int
    public var pms: [UnreadDmSnapshot]
    public var streams: [UnreadChannelSnapshot]
    public var huddles: [UnreadHuddleSnapshot]
    public var mentions: [Int]
    public var oldUnreadsMissing: Bool
}
