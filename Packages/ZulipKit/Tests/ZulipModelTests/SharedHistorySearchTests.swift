import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

private func message(
    _ id: Int, timestamp: Int = 1_750_000_000, flags: [String] = ["read"]
) throws -> Message {
    try ZulipJSON.decoder.decode(
        Message.self,
        from: Data(Fixtures.channelMessageJSON(id: id, timestamp: timestamp, flags: flags).utf8))
}

private func page(
    _ ids: [Int], oldest: Bool = false, newest: Bool = false, anchor: Int? = nil
) throws -> GetMessagesResult {
    GetMessagesResult(
        messages: try ids.map { try message($0) }, foundNewest: newest, foundOldest: oldest,
        anchor: anchor)
}

private let publicChannels = NarrowElement("channels", .string("public"))
private let launch = NarrowElement("search", .string("launch"))

struct SharedHistoryNarrowTests {
    @Test func unscopedSearchesAlsoAskPublicChannels() {
        #expect(Narrow.custom([launch]).sharedHistoryElements == [publicChannels, launch])
        let sender = NarrowElement("sender", .int(2))
        #expect(Narrow.custom([sender]).sharedHistoryElements == [publicChannels, sender])
        // A date search with no other term, and resolved topics.
        #expect(Narrow.custom([]).sharedHistoryElements == [publicChannels])
        let resolved = NarrowElement("is", .string("resolved"))
        #expect(Narrow.custom([resolved]).sharedHistoryElements == [publicChannels, resolved])
    }

    @Test func scopedSearchesAskOnce() {
        let scopes = [
            NarrowElement("channel", .int(10)),
            publicChannels,
            NarrowElement("dm", .intList([2])),
            NarrowElement("dm-including", .int(2)),
            NarrowElement("is", .string("starred")),
            NarrowElement("is", .string("mentioned")),
        ]
        for scope in scopes {
            #expect(Narrow.custom([scope, launch]).sharedHistoryElements == nil)
        }
        #expect(Narrow.combinedFeed(includesMuted: true).sharedHistoryElements == nil)
        #expect(Narrow.channel(streamId: 10).sharedHistoryElements == nil)
    }
}

struct SearchPageUnionTests {
    @Test func keepsWhatEveryAnswerCovers() throws {
        let union = GetMessagesResult.union(
            [try page([80, 90, 100], newest: true), try page([85, 95, 99], newest: true)],
            anchor: .newest, numBefore: 3, numAfter: 0)
        // Below 85 the public answer says nothing yet: 80 waits for the
        // next page.
        #expect(union.messages.map(\.id) == [85, 90, 95, 99, 100])
        #expect(union.foundNewest == true)
        #expect(union.foundOldest == false)
    }

    @Test func pagingOlderReachesEverything() throws {
        // Personal history holds 5 and 10; public channels 1…70.
        let first = GetMessagesResult.union(
            [try page([5, 10], oldest: true, newest: true), try page([50, 60, 70], newest: true)],
            anchor: .newest, numBefore: 3, numAfter: 0)
        #expect(first.messages.map(\.id) == [50, 60, 70])
        #expect(first.foundOldest == false)

        let second = GetMessagesResult.union(
            [try page([5, 10], oldest: true), try page([20, 30, 40])],
            anchor: .id(50), numBefore: 3, numAfter: 0)
        #expect(second.messages.map(\.id) == [20, 30, 40])

        let third = GetMessagesResult.union(
            [try page([5, 10], oldest: true), try page([1, 2], oldest: true)],
            anchor: .id(20), numBefore: 3, numAfter: 0)
        #expect(third.messages.map(\.id) == [1, 2, 5, 10])
        #expect(third.foundOldest == true)
    }

    @Test func olderPagesReachUpToTheirAnchor() throws {
        // Asked for nothing newer, each answer covers up to the anchor —
        // a sparse one mustn't cut the dense one's page short.
        let union = GetMessagesResult.union(
            [try page(Array(90...99)), try page([10, 20], oldest: true)],
            anchor: .id(100), numBefore: 10, numAfter: 0)
        #expect(union.messages.map(\.id) == Array(90...99))
    }

    @Test func newerPagesReachDownToTheirAnchor() throws {
        let union = GetMessagesResult.union(
            [try page([11, 12, 13]), try page([50], newest: true)],
            anchor: .id(10), numBefore: 0, numAfter: 3)
        #expect(union.messages.map(\.id) == [11, 12, 13])
        #expect(union.foundNewest == false)
    }

    @Test func thePersonalCopyWins() throws {
        let starred = GetMessagesResult(
            messages: [try message(100, flags: ["read", "starred"])],
            foundNewest: true, foundOldest: true)
        let historical = GetMessagesResult(
            messages: [try message(100, flags: ["read", "historical"])],
            foundNewest: true, foundOldest: true)
        let union = GetMessagesResult.union(
            [starred, historical], anchor: .newest, numBefore: 10, numAfter: 0)
        #expect(union.messages.map(\.id) == [100])
        #expect(union.messages.first?.flags?.contains("starred") == true)
    }

    @Test func aDateResolvesAcrossBothAnswers() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let personal = GetMessagesResult(
            messages: [try message(10, timestamp: 900), try message(30, timestamp: 1100)],
            foundNewest: true, foundOldest: true, anchor: 30)
        let shared = GetMessagesResult(
            messages: [try message(20, timestamp: 1050)],
            foundNewest: true, foundOldest: true, anchor: 20)
        let union = GetMessagesResult.union(
            [personal, shared], anchor: .date(date), numBefore: 10, numAfter: 10)
        #expect(union.messages.map(\.id) == [10, 20, 30])
        #expect(union.anchor == 20)

        // Nothing that recent: the newest, as the server falls back.
        let later = GetMessagesResult.union(
            [personal, shared], anchor: .date(Date(timeIntervalSince1970: 5000)),
            numBefore: 10, numAfter: 10)
        #expect(later.anchor == 30)
    }
}

@MainActor
struct SharedHistorySearchListTests {
    private func makeStore(
        personal: String, shared: FakeResponse
    ) throws -> (PerAccountStore, FakeTransport) {
        let transport = FakeTransport(defaultResponse: .hang) { request in
            guard request.path.hasSuffix("/messages") else { return nil }
            return request.queryValue("narrow")?.contains(#""channels""#) == true
                ? shared : .json(personal)
        }
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        connection.featureLevel = 400
        return (PerAccountStore(account: account, connection: connection, snapshot: snapshot), transport)
    }

    @Test func searchMergesPublicHistoryIn() async throws {
        let (store, transport) = try makeStore(
            personal: Fixtures.getMessagesJSON(
                [Fixtures.dmMessageJSON(id: 90, flags: ["read"])], foundOldest: true),
            shared: .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 95, flags: ["read", "historical"])],
                foundOldest: true)))
        let list = MessageListModel(store: store, narrow: .custom([launch]))
        await list.fetchInitial()
        #expect(transport.requests.count == 2)
        #expect(list.messages.map(\.id) == [90, 95])
        #expect(list.haveOldest)
    }

    @Test func aRefusedPublicSearchKeepsPersonalResults() async throws {
        let (store, transport) = try makeStore(
            personal: Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 90, flags: ["read"]),
            ]),
            shared: .json(
                #"{"result": "error", "msg": "Invalid narrow", "code": "BAD_NARROW"}"#,
                status: 400))
        let list = MessageListModel(store: store, narrow: .custom([launch]))
        await list.fetchInitial()
        #expect(list.messages.map(\.id) == [90])
        #expect(list.fetchError == nil)
        // From then on the list asks only its own history.
        await list.fetchOlder()
        #expect(transport.requests.count == 3)
        #expect(transport.requests[2].queryValue("narrow")?.contains(#""channels""#) == false)
    }

    @Test func channelSearchesAskOnce() async throws {
        let (store, transport) = try makeStore(
            personal: Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 90, flags: ["read"]),
            ]),
            shared: .networkError)
        let list = MessageListModel(
            store: store, narrow: .custom([NarrowElement("channel", .int(10)), launch]))
        await list.fetchInitial()
        #expect(transport.requests.count == 1)
        #expect(list.messages.map(\.id) == [90])
    }

    @Test func undeliveredMessagesStayOutOfTheCombinedFeed() async throws {
        // Both in memory (a public-channel search fetched 95); offline,
        // the combined feed renders from it.
        let (store, _) = try makeStore(personal: "", shared: .hang)
        store.reconcileFetchedMessages([
            try message(90), try message(95, flags: ["read", "historical"]),
        ])
        let list = MessageListModel(store: store, narrow: .combinedFeed(includesMuted: true))
        await list.fetchInitial()  // The fetch fails; the cache stands in.
        #expect(list.messages.map(\.id) == [90])
    }

    @Test func undeliveredMessagesAreNoConversation() throws {
        let (store, _) = try makeStore(personal: "", shared: .hang)
        let conversations = store.conversations
        conversations.seed(
            messages: [try message(95, flags: ["read", "historical"])], selfUserId: 1)
        #expect(conversations.conversations.isEmpty)
        conversations.seed(messages: [try message(96)], selfUserId: 1)
        #expect(conversations.conversations.map(\.lastMessageId) == [96])
    }
}
