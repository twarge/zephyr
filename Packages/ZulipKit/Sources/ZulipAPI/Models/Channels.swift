import Foundation

/// A channel (API name: stream), as in the register `streams` list and
/// `stream` events.
public struct ZulipStream: Decodable, Sendable, Hashable, Identifiable {
    public var streamId: Int
    public var name: String
    public var description: String
    public var inviteOnly: Bool
    public var isWebPublic: Bool?
    public var isArchived: Bool?
    /// The channel folder this channel is filed under (Zulip 12+), if any.
    public var folderId: Int?

    public var id: Int { streamId }
}

/// A sidebar grouping of channels (register `channel_folders`, Zulip 12+).
public struct ChannelFolder: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    /// 0-indexed display order.
    public var order: Int
}

/// A subscription: a channel plus the user's per-channel settings (subset).
/// Fields beyond id/name are lenient because we only rely on them for display.
public struct Subscription: Decodable, Sendable, Hashable, Identifiable {
    public var streamId: Int
    public var name: String
    public var description: String?
    public var color: String?
    public var isMuted: Bool?
    public var pinToTop: Bool?
    public var inviteOnly: Bool?
    /// Per-channel "notify for all messages" (nil = realm default off).
    public var desktopNotifications: Bool?

    public var id: Int { streamId }
    public var muted: Bool { isMuted ?? false }
}
