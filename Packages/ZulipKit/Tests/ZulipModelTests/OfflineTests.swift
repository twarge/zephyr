import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

@MainActor
struct OfflineTests {
    private func tempOfflineStore() -> OfflineStore {
        OfflineStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("zephyr-offline-tests-\(UUID().uuidString)"))
    }

    private func makeStore(
        script: [FakeResponse], offline: OfflineStore? = nil
    ) throws -> (PerAccountStore, FakeTransport) {
        let transport = FakeTransport(script: script, defaultResponse: .hang)
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

    private func fixtureMessage(id: Int, topic: String = "greetings") throws -> Message {
        try ZulipJSON.decoder.decode(
            Message.self,
            from: Data(Fixtures.channelMessageJSON(id: id, topic: topic, flags: ["read"]).utf8))
    }

    // MARK: Message database

    @Test func databaseRestoreIsBoundedPerConversation() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let db = try #require(offline.openDatabase())
        // 60 in one topic (over the per-conversation restore bound), 3 in
        // another; the database retains all of them.
        var all = try (1...60).map { try fixtureMessage(id: $0) }
        all += try (100...102).map { try fixtureMessage(id: $0, topic: "other") }
        try db.upsert(all, selfUserId: 1)
        #expect(try db.messageCount() == 63)

        let restored = try db.recentPerConversation(OfflineStore.messagesPerConversation)
        let byTopic = Dictionary(grouping: restored, by: \.subject)
        #expect(byTopic["greetings"]?.count == OfflineStore.messagesPerConversation)
        // The newest survive the bound.
        #expect(byTopic["greetings"]?.map(\.id).min() == 11)
        #expect(byTopic["other"]?.count == 3)
        #expect(restored.map(\.id) == restored.map(\.id).sorted())
    }

    @Test func databasePagesOlderHistory() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let db = try #require(offline.openDatabase())
        try db.upsert(try (1...60).map { try fixtureMessage(id: $0) }, selfUserId: 1)

        let page = try db.older(
            than: 31, matching: .topic(streamId: 10, topic: "Greetings"), limit: 20)
        #expect(page.map(\.id) == Array(11...30))
        #expect(try db.older(than: 31, matching: .channel(streamId: 99), limit: 20).isEmpty)
    }

    @Test func databaseFullTextSearch() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let db = try #require(offline.openDatabase())
        var special = try fixtureMessage(id: 7)
        special.content = "<p>the <b>flux capacitor</b> hums</p>"
        try db.upsert([special, try fixtureMessage(id: 8)], selfUserId: 1)

        #expect(try db.search("capacitor").map(\.id) == [7])
        #expect(try db.search("flux hums").map(\.id) == [7])
        // Topic and sender names are indexed too; HTML tags are not.
        #expect(try db.search("greetings").count == 2)
        #expect(try db.search("Other").count == 2)
        #expect(try db.search("nonexistent").isEmpty)
        #expect(try db.search("<p>").isEmpty)

        // Edits re-index; deletes drop out.
        special.content = "<p>quantum foam</p>"
        try db.upsert([special], selfUserId: 1)
        #expect(try db.search("capacitor").isEmpty)
        #expect(try db.search("quantum").map(\.id) == [7])
        #expect(try db.messageCount() == 2)
        try db.delete(ids: [7])
        #expect(try db.search("quantum").isEmpty)
        #expect(try db.messageCount() == 1)
    }

    @Test func legacyJSONCacheMigratesIntoDatabase() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let legacy = try (1...5).map { try fixtureMessage(id: $0) }
        try ZulipJSON.encoder.encode(legacy)
            .write(to: offline.directory.appendingPathComponent("messages.json"))

        let (store, _) = try makeStore(script: [], offline: offline)
        #expect(store.messages.count == 5)
        #expect(try store.database?.messageCount() == 5)
        // The JSON file is consumed by the import.
        #expect(!FileManager.default.fileExists(
            atPath: offline.directory.appendingPathComponent("messages.json").path))
    }

    @Test func outboxAndActionsRoundTrip() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let outbox = [
            OutboxMessage(
                id: "a", destination: .topic(streamId: 10, topic: "greetings"),
                content: "hi", timestamp: 1, state: .queued),
            OutboxMessage(
                id: "b", destination: .dm(userIds: [2]),
                content: "yo", timestamp: 2, state: .sending),
        ]
        offline.saveOutbox(outbox)
        #expect(offline.loadOutbox() == outbox)

        let actions: [PendingAction] = [
            .updateFlags(messageIds: [1, 2], add: true, flag: "read"),
            .reaction(
                messageId: 3, add: true, emojiName: "octopus", emojiCode: "1f419",
                reactionType: "unicode_emoji"),
        ]
        offline.savePendingActions(actions)
        #expect(offline.loadPendingActions() == actions)
    }

    // MARK: Outbox offline behavior

    @Test func offlineSendQueuesAndFlushResends() async throws {
        let (store, transport) = try makeStore(script: [
            .networkError,
            .json(#"{"result": "success", "id": 500}"#),
        ])
        store.send("hello", to: .topic(streamId: 10, topic: "greetings"))
        try await eventually("send queued while offline") {
            store.outbox.first?.state == .queued
        }

        store.flushPending()
        try await eventually("flush resends") {
            transport.requests.count(where: { $0.path == "/api/v1/messages" }) == 2
        }
        // Still in the outbox awaiting its echo event.
        try await eventually("entry awaits echo") {
            store.outbox.first?.state == .sending
        }
    }

    @Test func serverRejectionStaysManual() async throws {
        let (store, _) = try makeStore(script: [
            .json(Fixtures.errorJSON(code: "BAD_REQUEST", msg: "nope"), status: 400)
        ])
        store.send("hello", to: .dm(userIds: [2]))
        try await eventually("marked failed, not queued") {
            if case .failed = store.outbox.first?.state { return true }
            return false
        }
    }

    @Test func outboxSurvivesRelaunch() async throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let (first, _) = try makeStore(script: [.networkError], offline: offline)
        first.send("stranded", to: .topic(streamId: 10, topic: "greetings"))
        try await eventually("queued") { first.outbox.first?.state == .queued }

        // Also persist an entry that was mid-send at "quit".
        offline.saveOutbox(
            first.outbox + [
                OutboxMessage(
                    id: "ambiguous", destination: .dm(userIds: [2]),
                    content: "did this go out?", timestamp: 1, state: .sending)
            ])

        let (second, _) = try makeStore(script: [], offline: offline)
        #expect(second.outbox.count == 2)
        #expect(second.outbox[0].state == .queued)
        // The mid-send entry restores as failed: resending might duplicate.
        if case .failed = second.outbox[1].state {
        } else {
            Issue.record("expected .failed, got \(second.outbox[1].state)")
        }
    }

    // MARK: Pending actions

    @Test func offlineReactionIsOptimisticAndReplays() async throws {
        let (store, transport) = try makeStore(script: [
            .networkError,
            .json(#"{"result": "success"}"#),
        ])
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: ["read"])))

        let message = try #require(store.messages[100])
        store.toggleReaction(
            message: message, emojiName: "octopus", emojiCode: "1f419",
            reactionType: "unicode_emoji")
        // Optimistic: visible immediately, even though the network is down.
        #expect(store.messages[100]?.reactions.contains {
            $0.userId == 1 && $0.emojiCode == "1f419"
        } == true)
        try await eventually("action recorded") { !store.pendingActions.isEmpty }

        store.flushPending()
        try await eventually("action replayed") { store.pendingActions.isEmpty }
        let replay = transport.requests.last
        #expect(replay?.path == "/api/v1/messages/100/reactions")
    }

    @Test func rejectedReplayIsDropped() async throws {
        let (store, _) = try makeStore(script: [
            .networkError,
            .json(Fixtures.errorJSON(code: "BAD_REQUEST", msg: "already reacted"), status: 400),
        ])
        store.setStarred(true, messageId: 42)
        try await eventually("action recorded") { !store.pendingActions.isEmpty }
        store.flushPending()
        try await eventually("rejected action dropped") { store.pendingActions.isEmpty }
    }

    @Test func markReadOfflineClearsLocallyAndQueues() async throws {
        let (store, _) = try makeStore(script: [.networkError])
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: [])))
        let key = ConversationKey.topic(streamId: 10, topic: "greetings")
        #expect(store.unreads.unreadIds[key]?.contains(100) == true)

        store.markConversationRead(key)
        #expect(store.unreads.unreadIds[key]?.contains(100) != true)
        try await eventually("mark-read queued") {
            store.pendingActions == [.updateFlags(messageIds: [100], add: true, flag: "read")]
        }
    }

    @Test func backloggedActionsPreserveOrder() async throws {
        let (store, _) = try makeStore(script: [.networkError])
        store.setStarred(true, messageId: 1)
        try await eventually("first queued") { store.pendingActions.count == 1 }
        // With a backlog, later actions join the queue without racing ahead.
        store.setStarred(false, messageId: 1)
        #expect(store.pendingActions == [
            .updateFlags(messageIds: [1], add: true, flag: "starred"),
            .updateFlags(messageIds: [1], add: false, flag: "starred"),
        ])
    }

    // MARK: Cached transcripts

    @Test func cachedMessagesRenderOfflineAndRefetchOnReconnect() async throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        try #require(offline.openDatabase())
            .upsert(try (1...5).map { try fixtureMessage(id: $0) }, selfUserId: 1)

        let (store, _) = try makeStore(script: [.networkError], offline: offline)
        #expect(store.messages.count == 5)
        // Cached history also seeds sidebar recency.
        #expect(store.conversations.conversations.contains {
            $0.key == .topic(streamId: 10, topic: "greetings")
        })

        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "greetings"))
        await list.fetchInitial()
        #expect(list.isOfflineFallback)
        #expect(list.messages.map(\.id) == [1, 2, 3, 4, 5])
        #expect(list.fetchError != nil)
    }

    @Test func offlineScrollbackPagesFromDatabase() async throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        try #require(offline.openDatabase())
            .upsert(try (1...60).map { try fixtureMessage(id: $0) }, selfUserId: 1)

        // Restore loads the newest 50 (ids 11–60); the rest live only on disk.
        let (store, _) = try makeStore(
            script: [.networkError, .networkError], offline: offline)
        #expect(store.messages.count == 50)

        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "greetings"))
        await list.fetchInitial()
        #expect(list.messages.first?.id == 11)

        // Scrolling up offline pages ids 1–10 out of the database.
        await list.fetchOlder()
        #expect(list.messages.first?.id == 1)
        #expect(list.messages.count == 60)
    }

    @Test func offlineSearchUsesFullTextIndex() async throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        var special = try fixtureMessage(id: 3)
        special.content = "<p>zephyr rising</p>"
        try #require(offline.openDatabase())
            .upsert([special, try fixtureMessage(id: 4)], selfUserId: 1)

        let (store, _) = try makeStore(script: [.networkError], offline: offline)
        let list = MessageListModel(
            store: store, narrow: .custom([NarrowElement("search", .string("zephyr"))]))
        await list.fetchInitial()
        try await eventually("offline search results") {
            list.messages.map(\.id) == [3] && list.isOfflineFallback
        }
    }

    @Test func fetchedCopyBeatsCachedCopy() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        try #require(offline.openDatabase())
            .upsert([try fixtureMessage(id: 1)], selfUserId: 1)

        let (store, _) = try makeStore(script: [], offline: offline)
        var fresh = try fixtureMessage(id: 1)
        fresh.content = "<p>edited while we were away</p>"
        store.reconcileFetchedMessages([fresh])
        #expect(store.messages[1]?.content == "<p>edited while we were away</p>")

        // Once replaced, the ordinary rule returns: stored beats fetched.
        var stale = try fixtureMessage(id: 1)
        stale.content = "<p>stale</p>"
        store.reconcileFetchedMessages([stale])
        #expect(store.messages[1]?.content == "<p>edited while we were away</p>")
    }
}
