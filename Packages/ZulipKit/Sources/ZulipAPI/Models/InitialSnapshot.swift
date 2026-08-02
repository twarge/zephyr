import Foundation

/// The response of POST /register: the event queue handle plus the initial
/// state snapshot. Only the fields the M0 store consumes are modeled; the
/// state fields are optional because they depend on `fetch_event_types`.
public struct InitialSnapshot: Decodable, Sendable {
    public var queueId: String
    public var lastEventId: Int
    public var zulipVersion: String
    public var zulipFeatureLevel: Int
    public var eventQueueLongpollTimeoutSeconds: Int?

    public var realmName: String?
    public var maxMessageLength: Int?

    public var realmUsers: [User]?
    public var realmNonActiveUsers: [User]?
    public var crossRealmBots: [User]?
    public var streams: [ZulipStream]?
    public var subscriptions: [Subscription]?
    public var unreadMsgs: UnreadMessagesSnapshot?
    public var recentPrivateConversations: [RecentPrivateConversation]?
    public var channelFolders: [ChannelFolder]?
    /// Custom emoji, keyed by emoji id (reaction `emoji_code` for
    /// `realm_emoji` reactions).
    public var realmEmoji: [String: RealmEmojiItem]?
}

public struct RealmEmojiItem: Decodable, Sendable {
    public var name: String
    public var sourceUrl: String
    public var stillUrl: String?
    public var deactivated: Bool
}

/// One entry of the register payload's `recent_private_conversations`:
/// a DM thread the user recently participated in. `userIds` excludes self.
public struct RecentPrivateConversation: Decodable, Sendable {
    public var maxMessageId: Int
    public var userIds: [Int]
}
