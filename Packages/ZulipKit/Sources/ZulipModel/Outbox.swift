import Foundation
import ZulipAPI

/// Where a message is being sent.
public enum SendDestination: Hashable, Sendable {
    case topic(streamId: Int, topic: String)
    case dm(userIds: [Int])

    /// Whether an optimistically-sent message belongs in a given open list.
    public func matches(narrow: Narrow, selfUserId: Int) -> Bool {
        switch (self, narrow) {
        case (.topic(let streamId, let topic), .topic(let narrowStream, let narrowTopic)):
            return streamId == narrowStream
                && topic.caseInsensitiveCompare(narrowTopic) == .orderedSame
        case (.topic(let streamId, _), .channel(let narrowStream)):
            return streamId == narrowStream
        case (.dm(let userIds), .dm(let narrowIds)):
            let normalize = { (ids: [Int]) in Set(ids.filter { $0 != selfUserId }) }
            return normalize(userIds) == normalize(narrowIds)
        case (_, .combinedFeed):
            return true
        default:
            return false
        }
    }
}

extension ConversationKey {
    /// The destination for composing into this conversation.
    public func sendDestination(selfUserId: Int) -> SendDestination {
        switch self {
        case .topic(let streamId, let topic):
            return .topic(streamId: streamId, topic: topic)
        case .dm:
            let ids = dmParticipantIds ?? []
            return .dm(userIds: ids.isEmpty ? [selfUserId] : ids)
        }
    }
}

/// A message sent optimistically, shown in the transcript until the server's
/// `message` event (carrying our `local_message_id`) replaces it.
public struct OutboxMessage: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case sending
        case failed(String)
    }

    public let id: String
    public let destination: SendDestination
    /// Raw Zulip markdown (rendered HTML arrives with the echo event).
    public let content: String
    public let timestamp: Int
    public var state: State
}
