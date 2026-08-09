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
    /// The realm's square icon (absolute, or relative to the realm URL).
    public var realmIconUrl: String?
    /// The wide organization logo and its night-theme variant. The source
    /// fields say whether each is uploaded ("U") or the generic default
    /// ("D") — the default is Zulip's own logo, not the realm's.
    public var realmLogoUrl: String?
    public var realmLogoSource: String?
    public var realmNightLogoUrl: String?
    public var realmNightLogoSource: String?
    public var maxMessageLength: Int?
    /// Static JSON mapping unicode emoji codepoints to shortcode names.
    public var serverEmojiDataUrl: String?
    public var serverTypingStartedWaitPeriodMilliseconds: Int?
    public var serverTypingStoppedWaitPeriodMilliseconds: Int?
    public var serverTypingStartedExpiryPeriodMilliseconds: Int?
    public var serverPresencePingIntervalSeconds: Int?
    public var serverPresenceOfflineThresholdSeconds: Int?

    public var realmUsers: [User]?
    public var realmNonActiveUsers: [User]?
    public var crossRealmBots: [User]?
    public var streams: [ZulipStream]?
    public var subscriptions: [Subscription]?
    public var unreadMsgs: UnreadMessagesSnapshot?
    /// Every starred message id (the sidebar count; ids only, not bodies).
    public var starredMessages: [Int]?
    public var recentPrivateConversations: [RecentPrivateConversation]?
    public var channelFolders: [ChannelFolder]?
    /// Per-topic visibility overrides (muted/unmuted/followed).
    public var userTopics: [UserTopicItem]?
    /// Server-synced compose drafts.
    public var drafts: [ServerDraft]?
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

/// One `user_topics` entry: a per-topic visibility override.
public struct UserTopicItem: Decodable, Sendable, Equatable {
    public var streamId: Int
    public var topicName: String
    public var visibilityPolicy: Int
    public var lastUpdated: Int?
}

/// `visibility_policy` values (api: user_topics).
public enum TopicVisibilityPolicy: Int, Sendable {
    case none = 0
    case muted = 1
    case unmuted = 2
    case followed = 3
}

/// One server-side draft (the /drafts API). `to` is [streamId] for channel
/// drafts, recipient user ids for DMs.
public struct ServerDraft: Codable, Sendable, Equatable {
    public var id: Int?
    public var type: String
    public var to: [Int]
    public var topic: String
    public var content: String
    public var timestamp: Double?

    public init(
        id: Int? = nil, type: String, to: [Int], topic: String,
        content: String, timestamp: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.to = to
        self.topic = topic
        self.content = content
        self.timestamp = timestamp
    }
}
