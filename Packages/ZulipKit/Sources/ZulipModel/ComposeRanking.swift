import Foundation
import ZulipAPI

/// Relevance ranking for compose autocomplete, mirroring the web app:
/// match quality buckets first (exact > prefix > word-start > substring),
/// then activity — who spoke in the open conversation, whom you've
/// DM'd, which channel last saw a message — then name.
///
/// Population sizes reach 60k users on the big realms, so ranking never
/// sorts the whole population: candidates stream through a top-k
/// selection.
public enum ComposeRanking {
    /// How well a query hits a name; lower ranks first.
    public enum MatchQuality: Int, Comparable, Sendable {
        case exact = 0
        case prefix
        /// Starts a later word ("Ab" in "Tim Abbott").
        case wordStart
        case substring

        public static func < (a: MatchQuality, b: MatchQuality) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    /// The best quality across occurrences of `query` in `name`, nil when
    /// it never occurs. An empty query matches everything equally.
    public static func quality(of name: String, query: String) -> MatchQuality? {
        guard !query.isEmpty else { return .substring }
        var best: MatchQuality?
        var searchStart = name.startIndex
        while let range = name.range(
            of: query, options: .caseInsensitive,
            range: searchStart..<name.endIndex, locale: .current) {
            let quality: MatchQuality
            if range.lowerBound == name.startIndex {
                quality = range.upperBound == name.endIndex ? .exact : .prefix
            } else if name[name.index(before: range.lowerBound)].isWhitespace {
                quality = .wordStart
            } else {
                quality = .substring
            }
            best = min(best ?? quality, quality)
            // Prefix/exact only occur at the start; no later hit beats this.
            if best! <= .prefix { break }
            searchStart = name.index(after: range.lowerBound)
        }
        return best
    }

    /// Users matching `query`, most relevant first: match quality, who
    /// sent in the open conversation most recently, then DM recency,
    /// humans before bots, then name. Recency maps are message ids
    /// (globally monotonic — the id IS the recency order).
    public static func topUsers(
        _ users: some Sequence<User>, matching query: String, limit: Int,
        conversationRecency: [Int: Int], dmRecency: [Int: Int]
    ) -> [User] {
        let candidates = users.lazy.compactMap { user -> (User, MatchQuality)? in
            guard let quality = quality(of: user.fullName, query: query) else { return nil }
            return (user, quality)
        }
        return top(limit, of: candidates) { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            let aSpoke = conversationRecency[a.0.userId] ?? 0
            let bSpoke = conversationRecency[b.0.userId] ?? 0
            if aSpoke != bSpoke { return aSpoke > bSpoke }
            let aDm = dmRecency[a.0.userId] ?? 0
            let bDm = dmRecency[b.0.userId] ?? 0
            if aDm != bDm { return aDm > bDm }
            if a.0.isBot != b.0.isBot { return b.0.isBot }
            return a.0.fullName < b.0.fullName
        }.map(\.0)
    }

    /// Channels matching `query`, most relevant first: match quality, the
    /// channel being composed to, latest local message, the server's
    /// weekly traffic (covers channels we've never loaded), then name.
    public static func topChannels(
        _ subscriptions: some Sequence<Subscription>, matching query: String,
        limit: Int, currentStreamId: Int?, recency: [Int: Int]
    ) -> [Subscription] {
        let candidates = subscriptions.lazy.compactMap { sub -> (Subscription, MatchQuality)? in
            guard let quality = quality(of: sub.name, query: query) else { return nil }
            return (sub, quality)
        }
        return top(limit, of: candidates) { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if (a.0.streamId == currentStreamId) != (b.0.streamId == currentStreamId) {
                return a.0.streamId == currentStreamId
            }
            let aRecent = recency[a.0.streamId] ?? 0
            let bRecent = recency[b.0.streamId] ?? 0
            if aRecent != bRecent { return aRecent > bRecent }
            let aTraffic = a.0.streamWeeklyTraffic ?? -1
            let bTraffic = b.0.streamWeeklyTraffic ?? -1
            if aTraffic != bTraffic { return aTraffic > bTraffic }
            return a.0.name < b.0.name
        }.map(\.0)
    }

    /// The k best elements in ranking order — O(n·log k), no full sort.
    /// Stable: among equals, earlier elements rank first.
    static func top<T>(
        _ k: Int, of elements: some Sequence<T>, by precedes: (T, T) -> Bool
    ) -> [T] {
        guard k > 0 else { return [] }
        var best: [T] = []
        best.reserveCapacity(k + 1)
        for element in elements {
            // Most elements lose to the current worst outright.
            if best.count >= k, !precedes(element, best[best.count - 1]) { continue }
            var low = 0
            var high = best.count
            while low < high {
                let mid = (low + high) / 2
                if precedes(element, best[mid]) { high = mid } else { low = mid + 1 }
            }
            best.insert(element, at: low)
            if best.count > k { best.removeLast() }
        }
        return best
    }
}
