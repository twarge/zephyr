import Foundation
import ZulipModel

/// What the detail column shows: a DM/topic transcript, a channel's
/// interleaved message feed, a channel's topic list, or a cross-channel view.
/// Codable so each server's selection persists across launches.
nonisolated enum Destination: Hashable, Codable {
    case summary
    case conversation(ConversationKey)
    case channel(streamId: Int)
    case channelTopics(streamId: Int)
    case recentConversations
    case drafts
    case outbox
    case reminders
    case combinedFeed
    case mentions
    case starred
    case search(SearchQuery)
    case allChannels
}
