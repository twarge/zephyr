import Foundation
import Testing
import ZulipAPI
@testable import ZulipModel

struct ComposeRankingTests {
    private func user(_ id: Int, _ name: String, bot: Bool = false) -> User {
        User(userId: id, email: "u\(id)@example.com", fullName: name, isBot: bot)
    }

    @Test func qualityBuckets() {
        #expect(ComposeRanking.quality(of: "Tim", query: "tim") == .exact)
        #expect(ComposeRanking.quality(of: "Tim Abbott", query: "ti") == .prefix)
        #expect(ComposeRanking.quality(of: "Tim Abbott", query: "ab") == .wordStart)
        #expect(ComposeRanking.quality(of: "Tim Abbott", query: "bb") == .substring)
        #expect(ComposeRanking.quality(of: "Tim Abbott", query: "zz") == nil)
        // The best occurrence wins: "an" hits mid-"Roxana" first but
        // starts "Andrews".
        #expect(ComposeRanking.quality(of: "Roxana Andrews", query: "an") == .wordStart)
        // An empty query matches everyone equally.
        #expect(ComposeRanking.quality(of: "anyone", query: "") == .substring)
    }

    @Test func usersRankByConversationThenDmRecency() {
        let users = [user(1, "Anna"), user(2, "Beth"), user(3, "Cara"), user(4, "Dave")]
        let ranked = ComposeRanking.topUsers(
            users, matching: "", limit: 3,
            conversationRecency: [3: 900, 2: 500],
            dmRecency: [4: 700])
        #expect(ranked.map(\.userId) == [3, 2, 4])
    }

    @Test func matchQualityOutranksRecency() {
        // "ab" prefixes "Abbey Road" but word-starts "Bo Ab" — recency
        // cannot jump the quality bucket.
        let users = [user(1, "Abbey Road"), user(2, "Bo Ab")]
        let ranked = ComposeRanking.topUsers(
            users, matching: "ab", limit: 2,
            conversationRecency: [2: 999], dmRecency: [:])
        #expect(ranked.map(\.userId) == [1, 2])
    }

    @Test func humansBeforeBotsThenName() {
        let users = [user(1, "Zoe"), user(2, "Robo", bot: true), user(3, "Amy")]
        let ranked = ComposeRanking.topUsers(
            users, matching: "", limit: 3, conversationRecency: [:], dmRecency: [:])
        #expect(ranked.map(\.userId) == [3, 1, 2])
    }

    @Test func channelsRankByCurrentThenRecencyThenTraffic() {
        let subs = [
            Subscription(streamId: 1, name: "alpha"),
            Subscription(streamId: 2, name: "beta", streamWeeklyTraffic: 50),
            Subscription(streamId: 3, name: "gamma"),
            Subscription(streamId: 4, name: "delta"),
        ]
        let ranked = ComposeRanking.topChannels(
            subs, matching: "", limit: 4, currentStreamId: 3, recency: [4: 800])
        #expect(ranked.map(\.streamId) == [3, 4, 2, 1])
    }

    @Test func topKMatchesFullSortAndIsStable() {
        let values = [5, 1, 4, 1, 3, 2, 9, 1]
        #expect(ComposeRanking.top(3, of: values, by: <) == [1, 1, 1])
        #expect(ComposeRanking.top(3, of: values, by: >) == [9, 5, 4])
        #expect(ComposeRanking.top(0, of: values, by: <).isEmpty)
        #expect(ComposeRanking.top(99, of: values, by: <) == values.sorted())
        // Equal keys keep arrival order.
        let pairs = [(1, "a"), (0, "b"), (1, "c"), (0, "d")]
        let top = ComposeRanking.top(3, of: pairs) { $0.0 < $1.0 }
        #expect(top.map(\.1) == ["b", "d", "a"])
    }
}
