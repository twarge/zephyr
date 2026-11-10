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
        case reaction(ReactionEvent)
        case typing(TypingEvent)
        case realmUserAdd(User)
        case realmUserUpdate(RealmUserUpdate)
        case realmUserRemove(userId: Int)
        case subscriptionAdd([Subscription])
        case subscriptionRemove(streamIds: [Int])
        case subscriptionUpdate(SubscriptionUpdateEvent)
        /// stream/update: realm-wide channel property changes (rename,
        /// description); reuses SubscriptionUpdateEvent's wire shape.
        case streamUpdate(SubscriptionUpdateEvent)
        /// A reminder was created or removed — the payload isn't decoded;
        /// the store refetches the list instead.
        case remindersChanged
        case userTopic(UserTopicItem)
        case submessage(SubmessageEvent)
        case draftsAdd([ServerDraft])
        case draftsUpdate(ServerDraft)
        case draftsRemove(draftId: Int)
        case streamCreate([ZulipStream])
        case streamDelete(streamIds: [Int])
        /// A compose preview re-rendered with link previews the server
        /// fetched after answering /messages/render (Zulip 13+).
        case urlEmbedData(UrlEmbedDataEvent)
        /// One of the user's own settings changed (on any of their clients).
        case userSettingsUpdate(UserSettingsUpdateEvent)
        /// Legacy realm_emoji/update: the realm's complete custom emoji set
        /// (servers below FL 491, which ignore `individual_emoji_changes`).
        case realmEmojiReplace([String: RealmEmojiItem])
        /// realm_emoji/add (FL 491+): one new custom emoji, by id.
        case realmEmojiAdd(emojiId: String, emoji: RealmEmojiItem)
        /// realm_emoji/update_one (FL 491+): changed properties of one emoji.
        case realmEmojiUpdateOne(emojiId: String, deactivated: Bool?)
        case channelFolderAdd(ChannelFolderAddEvent)
        case channelFolderUpdate(ChannelFolderUpdateEvent)
        /// New display order: folder ids, first to last.
        case channelFolderReorder(order: [Int])
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
    /// All moved messages (moves affect a set; edits just `messageId`).
    public var messageIds: [Int]?
    public var renderedContent: String?
    public var editTimestamp: Int?
    /// The stream the messages were in (pre-move).
    public var streamId: Int?
    /// Move target stream, when the move crosses channels.
    public var newStreamId: Int?
    /// Move target topic.
    public var subject: String?
    public var origSubject: String?
    public var propagateMode: String?
    /// Server re-render only (link previews, thumbnails): not a user edit,
    /// so it must not mark the message edited.
    public var renderingOnly: Bool?

    public var isRenderingOnly: Bool { renderingOnly ?? false }

    /// Whether the event moves messages to another topic or channel.
    public var isMove: Bool {
        (newStreamId != nil && newStreamId != streamId)
            || (subject != nil && origSubject != nil && subject != origSubject)
    }
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
    /// remove/read only (FL 121+): where each newly-unread message lives,
    /// so clients can file unreads for messages they never loaded.
    public var messageDetails: [String: MessageDetail]?

    public struct MessageDetail: Decodable, Sendable, Equatable {
        /// "stream" or "private".
        public var type: String
        public var mentioned: Bool?
        /// DMs: the other recipients (excluding self; empty for self-DMs).
        public var userIds: [Int]?
        public var streamId: Int?
        public var topic: String?
    }

    /// The detail for one message id.
    public func detail(for messageId: Int) -> MessageDetail? {
        messageDetails?[String(messageId)]
    }
}

/// A per-channel setting change (`subscription`/`update`): value is
/// property-dependent (bool for is_muted/pin_to_top, string for color).
public struct SubscriptionUpdateEvent: Decodable, Sendable {
    public var streamId: Int
    public var property: String
    public var boolValue: Bool?
    public var stringValue: String?
    /// Integer-valued properties (`folder_id`); nil also when the value is
    /// null (a channel removed from its folder).
    public var intValue: Int?

    enum CodingKeys: String, CodingKey {
        case streamId, property, value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamId = try container.decode(Int.self, forKey: .streamId)
        property = try container.decode(String.self, forKey: .property)
        boolValue = try? container.decode(Bool.self, forKey: .value)
        stringValue = try? container.decode(String.self, forKey: .value)
        intValue = boolValue == nil ? try? container.decode(Int.self, forKey: .value) : nil
    }
}

/// `channel_folder/add` (Zulip 11+). `order` arrived later (FL 414): an
/// older server's folder sorts last.
public struct ChannelFolderAddEvent: Decodable, Sendable {
    public var folder: ChannelFolder
    public var isArchived: Bool

    private enum CodingKeys: String, CodingKey { case channelFolder }
    private struct Raw: Decodable {
        var id: Int
        var name: String
        var order: Int?
        var isArchived: Bool?
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: CodingKeys.self)
            .decode(Raw.self, forKey: .channelFolder)
        folder = ChannelFolder(id: raw.id, name: raw.name, order: raw.order ?? .max)
        isArchived = raw.isArchived ?? false
    }
}

/// `channel_folder/update`: only the changed fields are present.
public struct ChannelFolderUpdateEvent: Decodable, Sendable {
    public var channelFolderId: Int
    public var name: String?
    public var isArchived: Bool?

    private enum CodingKeys: String, CodingKey { case channelFolderId, data }
    private struct Changes: Decodable {
        var name: String?
        var isArchived: Bool?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        channelFolderId = try container.decode(Int.self, forKey: .channelFolderId)
        let data = try container.decode(Changes.self, forKey: .data)
        name = data.name
        isArchived = data.isArchived
    }
}

private struct RealmEmojiEnvelope: Decodable {
    var realmEmoji: [String: RealmEmojiItem]
}

private struct RealmEmojiAddEnvelope: Decodable {
    struct Identified: Decodable { var id: String }
    var emoji: RealmEmojiItem
    var emojiId: String

    private enum CodingKeys: String, CodingKey { case emoji }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decode(RealmEmojiItem.self, forKey: .emoji)
        emojiId = try container.decode(Identified.self, forKey: .emoji).id
    }
}

private struct RealmEmojiUpdateOneEnvelope: Decodable {
    struct Changes: Decodable { var deactivated: Bool? }
    var emojiId: String
    var data: Changes
}

private struct ChannelFolderReorderEnvelope: Decodable {
    var order: [Int]
}

/// `user_settings/update`: `value` is a bool, integer or string by setting;
/// only the bool ones are read.
public struct UserSettingsUpdateEvent: Decodable, Sendable {
    public var property: String
    public var boolValue: Bool?

    enum CodingKeys: String, CodingKey {
        case property, value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        property = try container.decode(String.self, forKey: .property)
        boolValue = try? container.decode(Bool.self, forKey: .value)
    }
}

public struct TypingEvent: Decodable, Sendable {
    public struct UserRef: Decodable, Sendable {
        public var userId: Int
    }

    public var op: String
    /// "direct" or "stream".
    public var messageType: String?
    private var sender: UserRef
    /// Direct typing: all recipients (including the sender).
    public var recipients: [UserRef]?
    /// Channel typing.
    public var streamId: Int?
    public var topic: String?

    public var senderId: Int { sender.userId }
}

public struct ReactionEvent: Decodable, Sendable {
    public var op: String
    public var messageId: Int
    public var userId: Int
    public var emojiName: String
    public var emojiCode: String
    public var reactionType: String

    public var reaction: Reaction {
        Reaction(
            emojiName: emojiName, emojiCode: emojiCode,
            reactionType: reactionType, userId: userId)
    }
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
        case ("reaction", "add"), ("reaction", "remove"):
            kind = .reaction(try ReactionEvent(from: decoder))
        case ("typing", "start"), ("typing", "stop"):
            kind = .typing(try TypingEvent(from: decoder))
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
        case ("subscription", "update"):
            kind = .subscriptionUpdate(try SubscriptionUpdateEvent(from: decoder))
        case ("stream", "create"):
            kind = .streamCreate(try StreamsEnvelope(from: decoder).streams)
        case ("stream", "update"):
            // Same wire shape as subscription/update: stream_id, property,
            // value.
            kind = .streamUpdate(try SubscriptionUpdateEvent(from: decoder))
        case ("stream", "delete"):
            kind = .streamDelete(streamIds: try DeletedStreamsEnvelope(from: decoder).allIds)
        case ("reminder", _), ("reminders", _):
            kind = .remindersChanged
        case ("user_topic", _):
            kind = .userTopic(try UserTopicItem(from: decoder))
        case ("submessage", _):
            kind = .submessage(try SubmessageEvent(from: decoder))
        case ("drafts", "add"):
            kind = .draftsAdd(try DraftsEnvelope(from: decoder).drafts)
        case ("drafts", "update"):
            kind = .draftsUpdate(try DraftEnvelope(from: decoder).draft)
        case ("drafts", "remove"):
            kind = .draftsRemove(draftId: try DraftIdEnvelope(from: decoder).draftId)
        case ("url_embed_data", _):
            kind = .urlEmbedData(try UrlEmbedDataEvent(from: decoder))
        case ("user_settings", "update"):
            kind = .userSettingsUpdate(try UserSettingsUpdateEvent(from: decoder))
        case ("realm_emoji", "update"):
            kind = .realmEmojiReplace(try RealmEmojiEnvelope(from: decoder).realmEmoji)
        case ("realm_emoji", "add"):
            let envelope = try RealmEmojiAddEnvelope(from: decoder)
            kind = .realmEmojiAdd(emojiId: envelope.emojiId, emoji: envelope.emoji)
        case ("realm_emoji", "update_one"):
            let envelope = try RealmEmojiUpdateOneEnvelope(from: decoder)
            kind = .realmEmojiUpdateOne(
                emojiId: envelope.emojiId, deactivated: envelope.data.deactivated)
        case ("channel_folder", "add"):
            kind = .channelFolderAdd(try ChannelFolderAddEvent(from: decoder))
        case ("channel_folder", "update"):
            kind = .channelFolderUpdate(try ChannelFolderUpdateEvent(from: decoder))
        case ("channel_folder", "reorder"):
            kind = .channelFolderReorder(order: try ChannelFolderReorderEnvelope(from: decoder).order)
        default:
            kind = .unexpected(type: type, op: op)
        }
    }
}

/// A widget update (poll vote, todo strike, new option) for an existing
/// message.
public struct SubmessageEvent: Decodable, Sendable {
    public var msgType: String
    public var content: String
    public var messageId: Int
    public var senderId: Int
}

/// `url_embed_data`: sent to all the user's clients, and not guaranteed —
/// the server drops it when the rendering didn't change, when a newer
/// render request superseded it, or when it waited too long to run.
public struct UrlEmbedDataEvent: Decodable, Sendable, Equatable {
    /// The draft markdown that was re-rendered; apply only to a preview
    /// still showing exactly this.
    public var content: String
    public var renderedContent: String
}

private struct DraftsEnvelope: Decodable {
    var drafts: [ServerDraft]
}

private struct DraftEnvelope: Decodable {
    var draft: ServerDraft
}

private struct DraftIdEnvelope: Decodable {
    var draftId: Int
}
