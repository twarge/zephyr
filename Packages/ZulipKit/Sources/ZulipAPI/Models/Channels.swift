import Foundation

/// A channel (API name: stream), as in the register `streams` list and
/// `stream` events.
public struct ZulipStream: Decodable, Sendable, Hashable, Identifiable {
    public var streamId: Int
    public var name: String
    public var description: String
    public var inviteOnly: Bool
    public var isArchived: Bool?

    public var id: Int { streamId }
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

    public var id: Int { streamId }
    public var muted: Bool { isMuted ?? false }
}
