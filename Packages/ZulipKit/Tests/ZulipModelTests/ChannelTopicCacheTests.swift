import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

@MainActor
struct ChannelTopicCacheTests {
    private func tempOfflineStore() -> OfflineStore {
        OfflineStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("zephyr-topic-cache-tests-\(UUID().uuidString)"))
    }

    private func makeStore(
        script: [FakeResponse], offline: OfflineStore? = nil
    ) throws -> (PerAccountStore, FakeTransport) {
        let transport = FakeTransport(script: script, defaultResponse: .networkError)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        return (
            PerAccountStore(
                account: account, connection: connection, snapshot: snapshot, offline: offline),
            transport)
    }

    private func topicsJSON(_ topics: [(String, Int)]) -> String {
        let items = topics.map { #"{"name": "\#($0.0)", "max_id": \#($0.1)}"# }
        return #"{"result": "success", "msg": "", "topics": [\#(items.joined(separator: ","))]}"#
    }

    private func message(id: Int, topic: String) throws -> Message {
        try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.channelMessageJSON(id: id, topic: topic).utf8))
    }

    @Test func offlineFetchFallsBackToDatabaseTopics() async throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let (store, _) = try makeStore(script: [.networkError], offline: offline)
        try store.database?.upsert(
            [try message(id: 1, topic: "alpha"), try message(id: 2, topic: "beta")],
            selfUserId: 1)

        let topics = await store.channelTopics.load(10)
        #expect(topics.map(\.name) == ["beta", "alpha"])
        #expect(!store.channelTopics.isFresh(10))
        // A database seed is partial: it never persists as the channel's list.
        await store.channelTopics.save()
        #expect(offline.loadChannelTopics().isEmpty)
    }

    @Test func fetchedListsPersistForAnOfflineRelaunch() async throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let (online, _) = try makeStore(
            script: [.json(topicsJSON([("new", 9), ("old", 3)]))], offline: offline)
        await online.channelTopics.load(10)
        await online.channelTopics.save()

        let (relaunched, transport) = try makeStore(script: [], offline: offline)
        await relaunched.restoreOfflineCache()
        // restore runs alongside the transcript hydration; give it a turn.
        for _ in 0..<50 where relaunched.channelTopics.lists[10] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(relaunched.channelTopics.lists[10]?.map(\.name) == ["new", "old"])
        // Offline, a refresh keeps the restored list rather than emptying it.
        await relaunched.channelTopics.load(10)
        #expect(transport.requests.count == 1)
        #expect(relaunched.channelTopics.lists[10]?.map(\.name) == ["new", "old"])
    }

    @Test func newMessagesBumpTheirTopic() async throws {
        let (store, _) = try makeStore(
            script: [.json(topicsJSON([("b", 20), ("a", 10)]))])
        await store.channelTopics.load(10)

        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 30, topic: "A"))))
        #expect(store.channelTopics.lists[10] == [
            ChannelTopic(name: "A", maxId: 30), ChannelTopic(name: "b", maxId: 20),
        ])
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 2, message: Fixtures.channelMessageJSON(id: 31, topic: "c"))))
        #expect(store.channelTopics.lists[10]?.map(\.name) == ["c", "A", "b"])
    }

    @Test func messagesDontStubAnUnloadedChannel() throws {
        let (store, _) = try makeStore(script: [])
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 30, topic: "a"))))
        #expect(store.channelTopics.lists[10] == nil)
    }

    @Test func failedLoadAllRetriesLater() async throws {
        let (store, transport) = try makeStore(script: [.networkError])
        await store.channelTopics.loadAll()
        #expect(transport.requests.count == 1)
        #expect(store.channelTopics.lists[10] == [])
        #expect(!store.channelTopics.isLoadingUncached)
        // Within the retry pause, another keystroke doesn't hammer the server.
        await store.channelTopics.loadAll()
        #expect(transport.requests.count == 1)
    }

    @Test func storeSwapCarriesListsButFetchesAgain() async throws {
        let (provisional, _) = try makeStore(script: [.json(topicsJSON([("a", 1)]))])
        await provisional.channelTopics.load(10)
        let (live, transport) = try makeStore(script: [.json(topicsJSON([("a", 1), ("b", 2)]))])
        live.adoptCachedMessages(from: provisional)
        #expect(live.channelTopics.lists[10]?.map(\.name) == ["a"])
        #expect(!live.channelTopics.isFresh(10))
        await live.channelTopics.loadAll()
        #expect(transport.requests.count == 1)
        #expect(live.channelTopics.lists[10]?.map(\.name) == ["a", "b"])
    }
}
