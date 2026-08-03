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

    // MARK: OfflineStore round-trips

    @Test func messagesRoundTripAndBound() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        // 60 in one topic (over the per-conversation bound), 3 in another.
        var all = try (1...60).map { try fixtureMessage(id: $0) }
        all += try (100...102).map { try fixtureMessage(id: $0, topic: "other") }
        offline.saveMessages(all, selfUserId: 1)

        let loaded = offline.loadMessages()
        let byTopic = Dictionary(grouping: loaded, by: \.subject)
        #expect(byTopic["greetings"]?.count == OfflineStore.messagesPerConversation)
        // The newest survive the bound.
        #expect(byTopic["greetings"]?.map(\.id).min() == 11)
        #expect(byTopic["other"]?.count == 3)
        #expect(loaded.map(\.id) == loaded.map(\.id).sorted())
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
        offline.saveMessages(try (1...5).map { try fixtureMessage(id: $0) }, selfUserId: 1)

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

    @Test func fetchedCopyBeatsCachedCopy() throws {
        let offline = tempOfflineStore()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        offline.saveMessages([try fixtureMessage(id: 1)], selfUserId: 1)

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
