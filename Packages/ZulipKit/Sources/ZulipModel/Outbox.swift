import Foundation
import ZulipAPI

/// Where a message is being sent. Codable so drafts persist across launches.
public enum SendDestination: Hashable, Sendable, Codable {
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

extension SendDestination {
    /// The conversation an outbox entry belongs to (the sidebar Outbox
    /// section navigates there).
    public func conversationKey(selfUserId: Int) -> ConversationKey {
        switch self {
        case .topic(let streamId, let topic):
            .topic(streamId: streamId, topic: topic)
        case .dm(let userIds):
            Unreads.dmKey(participantIds: userIds, selfUserId: selfUserId)
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
/// `message` event (carrying our `local_message_id`) replaces it. Codable so
/// the outbox survives relaunch (see `OfflineStore`).
public struct OutboxMessage: Identifiable, Sendable, Equatable, Codable {
    public enum State: Sendable, Equatable, Codable {
        case sending
        /// Waiting for the network: the send failed with a network error
        /// (offline, dropped connection, or timeout) and resends
        /// automatically on reconnect.
        case queued
        case failed(String)
    }

    public let id: String
    public let destination: SendDestination
    /// Raw Zulip markdown (rendered HTML arrives with the echo event).
    public let content: String
    public let timestamp: Int
    public var state: State

    /// The state a persisted entry restores to on relaunch: `.sending` is
    /// ambiguous (the send may have completed; its echo died with the old
    /// event queue), so it demotes to `.failed` and requires a manual retry.
    /// `.queued` entries never reached the server and stay auto-resendable.
    public var restoredState: State {
        switch state {
        case .sending: return .failed("Not confirmed sent before quitting")
        case .queued, .failed: return state
        }
    }
}
