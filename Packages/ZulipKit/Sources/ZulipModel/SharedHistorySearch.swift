import Foundation
import ZulipAPI

// MARK: - Searching shared history

/// A search with no channel, DM or `is:` term reaches only the user's
/// personal history: the messages delivered to them. Public channels hold
/// more — everything sent before the user joined, and channels they never
/// did. The web offers to widen such a search to `channels:public` once it
/// runs dry ("Expand search", "Search all public channels"), which drops
/// DMs and private channels from the widened results. Zephyr asks both
/// from the start and merges the answers, so one feed holds all of it.
extension Narrow {
    /// The same search across every public channel, when it can find what
    /// the personal-history search can't (the web's
    /// `may_have_incomplete_message_history`); nil when it can't.
    public var sharedHistoryElements: [NarrowElement]? {
        guard case .custom(let elements) = self else { return nil }
        for element in elements {
            switch element.operatorName {
            case "channel", "stream", "channels", "streams":
                // Already reaches the channels' full history.
                return nil
            case "dm", "dm-including", "pm-with", "group-pm-with":
                return nil
            case "is":
                // Flags (starred, mentioned, …) live only on delivered
                // messages; is:resolved is about the topic.
                if element.operand != .string("resolved") { return nil }
            default:
                break
            }
        }
        return [NarrowElement("channels", .string("public"))] + elements
    }
}

extension GetMessagesResult {
    /// One page asked of several narrows with the same anchor and counts,
    /// as a single page. Each answer is complete only between its own ends
    /// (or past them, where it found the oldest or newest), so the union
    /// keeps what lies inside every answer's span; the next page asks again
    /// from the union's edge, refetching what this one left out.
    static func union(
        _ pages: [GetMessagesResult], anchor: MessageAnchor, numBefore: Int, numAfter: Int
    ) -> GetMessagesResult {
        guard let first = pages.first, pages.count > 1 else {
            return pages.first ?? GetMessagesResult(messages: [], foundNewest: true, foundOldest: true)
        }
        let requestedId: Int? = if case .id(let id) = anchor { id } else { nil }
        var lower = Int.min
        var upper = Int.max
        for page in pages {
            let ids = page.messages.map(\.id)
            // A page with nothing asked for on one side reaches its anchor
            // there: the server had nothing between.
            let anchorId = page.anchor ?? requestedId
            if page.foundOldest != true, anchor != .oldest {
                lower = max(lower, (numBefore == 0 ? anchorId : nil) ?? ids.min() ?? .min)
            }
            if page.foundNewest != true, anchor != .newest {
                upper = min(upper, (numAfter == 0 ? anchorId : nil) ?? ids.max() ?? .max)
            }
        }
        // Spans that miss each other can't happen for one anchor; keep the
        // first (personal) answer whole rather than guess.
        guard lower <= upper else { return first }
        var byId: [Int: Message] = [:]
        // The first page's copy wins: it carries the user's own flags.
        for page in pages.reversed() {
            for message in page.messages { byId[message.id] = message }
        }
        let messages = byId.values
            .filter { (lower...upper).contains($0.id) }
            .sorted { $0.id < $1.id }
        var resolvedAnchor = first.anchor
        if case .date(let date) = anchor {
            // Each answer anchored at its first message sent at or after
            // the date, else its newest. The union's is the earliest such
            // pick, else the newest; an answer that landed nowhere (an
            // empty narrow, a server too old for dates) offers none.
            let picks = pages.compactMap(\.anchor).compactMap { id in
                messages.first { $0.id == id }
            }
            let onOrAfter = picks.filter {
                TimeInterval($0.timestamp) >= date.timeIntervalSince1970
            }
            if let pick = onOrAfter.min(by: { $0.id < $1.id })
                ?? picks.max(by: { $0.id < $1.id }) {
                resolvedAnchor = pick.id
            }
        }
        func all(_ flag: (GetMessagesResult) -> Bool?) -> Bool? {
            pages.contains { flag($0) == nil } ? nil : pages.allSatisfy { flag($0) == true }
        }
        return GetMessagesResult(
            messages: messages,
            foundNewest: all(\.foundNewest),
            foundOldest: all(\.foundOldest),
            historyLimited: pages.contains { $0.historyLimited == true },
            anchor: resolvedAnchor)
    }
}
