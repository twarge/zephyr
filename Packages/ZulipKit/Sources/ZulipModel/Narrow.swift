import Foundation
import ZulipAPI

/// A first-class narrow (message filter). Each case knows its API encoding;
/// UI-side membership/visibility logic arrives with the message-list model
/// in M1.
public enum Narrow: Sendable, Hashable {
    case combinedFeed
    case channel(streamId: Int)
    case topic(streamId: Int, topic: String)
    case dm(userIds: [Int])
    case mentions
    case starred
    /// An arbitrary operator combination (search queries). Message lists with
    /// a custom narrow never live-append — server-side matching (full-text
    /// search especially) can't be replicated client-side.
    case custom([NarrowElement])

    public var apiElements: [NarrowElement] {
        switch self {
        case .combinedFeed:
            []
        case .channel(let streamId):
            [NarrowElement("channel", .int(streamId))]
        case .topic(let streamId, let topic):
            [NarrowElement("channel", .int(streamId)), NarrowElement("topic", .string(topic))]
        case .dm(let userIds):
            [NarrowElement("dm", .intList(userIds))]
        case .mentions:
            [NarrowElement("is", .string("mentioned"))]
        case .starred:
            [NarrowElement("is", .string("starred"))]
        case .custom(let elements):
            elements
        }
    }
}
