import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

@MainActor
struct OutboxTests {
    private func makeStore(script: [FakeResponse]) throws -> (PerAccountStore, FakeTransport) {
        let transport = FakeTransport(script: script, defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        return (
            PerAccountStore(account: account, connection: connection, snapshot: snapshot),
            transport)
    }

    @Test func sendCreatesOutboxAndEchoClears() async throws {
        let (store, transport) = try makeStore(script: [
            .json(#"{"result": "success", "id": 500}"#)
        ])
        store.send("hello there", to: .topic(streamId: 10, topic: "greetings"))
        #expect(store.outbox.count == 1)
        #expect(store.outbox[0].state == .sending)
        let localId = store.outbox[0].id

        try await eventually("send request issued") {
            transport.requests.contains { $0.path == "/api/v1/messages" }
        }
        let request = try #require(
            transport.requests.first { $0.path == "/api/v1/messages" })
        #expect(request.formValue("type") == "channel")
        #expect(request.formValue("to") == "10")
        #expect(request.formValue("topic") == "greetings")
        #expect(request.formValue("local_id") == localId)
        #expect(request.formValue("queue_id") == "q1")

        // The echo event (local_message_id) clears the outbox entry.
        let echo = """
            {"id": 9, "type": "message", "local_message_id": "\(localId)",
             "message": \(Fixtures.channelMessageJSON(id: 500, senderId: 1, senderName: "Self")),
             "flags": ["read"]}
            """
        store.handleEvent(try ZulipJSON.decoder.decode(Event.self, from: Data(echo.utf8)))
        #expect(store.outbox.isEmpty)
        #expect(store.messages[500] != nil)
    }

    @Test func failedSendMarksAndRetries() async throws {
        let (store, _) = try makeStore(script: [
            .json(Fixtures.errorJSON(code: "BAD_REQUEST", msg: "nope"), status: 400),
            .json(#"{"result": "success", "id": 501}"#),
        ])
        store.send("hello", to: .dm(userIds: [2]))
        let localId = store.outbox[0].id

        try await eventually("marked failed") {
            if case .failed = store.outbox.first?.state { return true }
            return false
        }
        store.retrySend(localId)
        #expect(store.outbox[0].state == .sending)
        try await eventually("retry stays pending after success (awaits echo)") {
            store.outbox.first?.state == .sending
        }
        store.discardSend(localId)
        #expect(store.outbox.isEmpty)
    }

    @Test func timedOutSendQueuesAndFlushResends() async throws {
        let (store, transport) = try makeStore(script: [
            .timeout,
            .json(#"{"result": "success", "id": 502}"#),
        ])
        store.send("hello", to: .dm(userIds: [2]))
        // A timeout is a network failure: queued for automatic resend.
        try await eventually("queued after timeout") {
            store.outbox.first?.state == .queued
        }
        store.flushPending()
        try await eventually("resent on flush (awaits echo)") {
            store.outbox.first?.state == .sending
        }
        #expect(transport.requests.count == 2)
    }

    @Test func destinationMatching() {
        let topic = SendDestination.topic(streamId: 10, topic: "Greetings")
        #expect(topic.matches(narrow: .topic(streamId: 10, topic: "greetings"), selfUserId: 1))
        #expect(topic.matches(narrow: .channel(streamId: 10), selfUserId: 1))
        #expect(!topic.matches(narrow: .channel(streamId: 11), selfUserId: 1))

        let dm = SendDestination.dm(userIds: [2, 5])
        #expect(dm.matches(narrow: .dm(userIds: [1, 2, 5]), selfUserId: 1))
        #expect(!dm.matches(narrow: .dm(userIds: [2]), selfUserId: 1))
    }
}

@MainActor
struct ReactionEventTests {
    @Test func reactionEventsUpdateCanonicalMessage() throws {
        let (store, _) = try {
            let transport = FakeTransport(defaultResponse: .hang)
            let account = Account(
                realmURL: URL(string: "https://test.example")!,
                email: "self@example.com", userId: 1)
            let snapshot = try ZulipJSON.decoder.decode(
                InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
            let connection = ApiConnection(
                realmURL: account.realmURL, email: account.email, apiKey: "key",
                transport: transport)
            return (
                PerAccountStore(account: account, connection: connection, snapshot: snapshot),
                transport)
        }()
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: [])))

        let add = #"{"id": 2, "type": "reaction", "op": "add", "message_id": 100, "user_id": 7, "emoji_name": "octopus", "emoji_code": "1f419", "reaction_type": "unicode_emoji"}"#
        store.handleEvent(try decodeEvent(add))
        #expect(store.messages[100]?.reactions.count == 1)
        #expect(store.messages[100]?.reactions.first?.userId == 7)

        let remove = #"{"id": 3, "type": "reaction", "op": "remove", "message_id": 100, "user_id": 7, "emoji_name": "octopus", "emoji_code": "1f419", "reaction_type": "unicode_emoji"}"#
        store.handleEvent(try decodeEvent(remove))
        #expect(store.messages[100]?.reactions.isEmpty == true)
    }
}
