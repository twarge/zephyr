import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

@MainActor
struct MessageListModelTests {
    private func makeStoreWithTransport(
        script: [FakeResponse]
    ) throws -> (PerAccountStore, FakeTransport) {
        let transport = FakeTransport(script: script, defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        return (PerAccountStore(account: account, connection: connection, snapshot: snapshot), transport)
    }

    @Test func fetchInitialThenLiveAppend() async throws {
        let (store, _) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 100, flags: ["read"]),
                Fixtures.channelMessageJSON(id: 101, flags: ["read"]),
            ]))
        ])
        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "greetings"))
        await list.fetchInitial()
        #expect(list.messages.map(\.id) == [100, 101])
        #expect(list.haveNewest)

        // A live event for the same topic appends; a different topic doesn't.
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 102), flags: [])))
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 2,
                    message: Fixtures.channelMessageJSON(id: 103, topic: "other-topic"), flags: [])))
        #expect(list.messages.map(\.id) == [100, 101, 102])
    }

    @Test func fetchOlderPrependsWithoutDuplicatingAnchor() async throws {
        let (store, transport) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 200, flags: ["read"]),
            ])),
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 198, flags: ["read"]),
                Fixtures.channelMessageJSON(id: 199, flags: ["read"]),
                Fixtures.channelMessageJSON(id: 200, flags: ["read"]),  // anchor comes back
            ])),
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()
        await list.fetchOlder()
        #expect(list.messages.map(\.id) == [198, 199, 200])
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].queryValue("anchor") == "200")
    }

    @Test func deleteAndEditPropagate() async throws {
        let (store, _) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 100, flags: ["read"]),
                Fixtures.channelMessageJSON(id: 101, flags: ["read"]),
            ]))
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()

        store.handleEvent(
            try decodeEvent(
                #"{"id": 1, "type": "update_message", "message_id": 100, "rendered_content": "<p>edited</p>"}"#))
        #expect(list.messages[0].content == "<p>edited</p>")

        store.handleEvent(
            try decodeEvent(
                #"{"id": 2, "type": "delete_message", "message_ids": [101], "message_type": "stream"}"#))
        #expect(list.messages.map(\.id) == [100])
    }

    @Test func narrowMembership() throws {
        let dm = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.dmMessageJSON(id: 5, recipientIds: [1, 2]).utf8))
        #expect(Narrow.dm(userIds: [2]).containsMessage(dm, selfUserId: 1))
        #expect(Narrow.dm(userIds: [1, 2]).containsMessage(dm, selfUserId: 1))
        #expect(!Narrow.dm(userIds: [3]).containsMessage(dm, selfUserId: 1))

        let channelMessage = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.channelMessageJSON(id: 6, topic: "Greetings").utf8))
        #expect(Narrow.topic(streamId: 10, topic: "greetings")
            .containsMessage(channelMessage, selfUserId: 1))
        #expect(!Narrow.channel(streamId: 11).containsMessage(channelMessage, selfUserId: 1))
    }
}

@MainActor
struct ConversationListTests {
    @Test func seededFromSnapshotAndOrderedByRecency() throws {
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let unreads = """
            {"count": 1, "pms": [],
             "streams": [{"stream_id": 10, "topic": "greetings", "unread_message_ids": [500]}],
             "huddles": [], "mentions": [], "old_unreads_missing": false}
            """
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self,
            from: Data(
                Fixtures.registerJSON(
                    queueId: "q1", unreadMsgs: unreads,
                    recentPrivateConversations: #"[{"max_message_id": 400, "user_ids": [2]}]"#
                ).utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: FakeTransport(defaultResponse: .hang))
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        // Topic (id 500) is more recent than the DM (id 400).
        #expect(store.conversations.conversations.map(\.key) == [
            .topic(streamId: 10, topic: "greetings"),
            .dm("2"),
        ])

        // A new DM message bumps that conversation to the top, with snippet.
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1,
                    message: Fixtures.dmMessageJSON(id: 600, recipientIds: [1, 2]), flags: [])))
        let top = store.conversations.conversations[0]
        #expect(top.key == .dm("2"))
        #expect(top.snippetHTML == "<p>psst</p>")
        #expect(top.senderName == "Other")
    }

    @Test func conversationKeyNarrowRoundTrip() {
        #expect(ConversationKey.dm("2,5").narrow(selfUserId: 1) == .dm(userIds: [2, 5]))
        #expect(
            ConversationKey.topic(streamId: 10, topic: "hi").narrow(selfUserId: 1)
                == .topic(streamId: 10, topic: "hi"))
        #expect(ConversationKey.dm("2,5").dmParticipantIds == [2, 5])
    }
}

@MainActor
struct SelfDmTests {
    /// The self-DM key's participant set is empty; its narrow must query
    /// dm:[selfUserId] (dm:[] returns nothing).
    @Test func selfDmNarrowTargetsSelf() throws {
        let key = Unreads.dmKey(participantIds: [1], selfUserId: 1)
        #expect(key.narrow(selfUserId: 1) == .dm(userIds: [1]))
        #expect(key.sendDestination(selfUserId: 1) == .dm(userIds: [1]))

        let message = try ZulipJSON.decoder.decode(
            Message.self,
            from: Data(Fixtures.dmMessageJSON(id: 9, senderId: 1, recipientIds: [1]).utf8))
        #expect(Narrow.dm(userIds: [1]).containsMessage(message, selfUserId: 1))
        #expect(Unreads.conversationKey(for: message, selfUserId: 1) == key)
    }
}

@MainActor
struct SelfDmEchoTests {
    @Test func selfDmEchoStaysInOpenList() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.getMessagesJSON([])),
                .json(#"{"result": "success", "id": 500}"#),
            ], defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        let list = MessageListModel(store: store, narrow: .dm(userIds: [1]))
        await list.fetchInitial()
        #expect(list.haveNewest)

        store.send("note to self", to: .dm(userIds: [1]))
        let localId = try #require(store.outbox.first?.id)
        try await eventually("send issued") {
            transport.requests.contains { $0.path == "/api/v1/messages" }
        }

        let echo = """
            {"id": 9, "type": "message", "local_message_id": "\(localId)",
             "message": \(Fixtures.dmMessageJSON(id: 500, senderId: 1, recipientIds: [1])),
             "flags": ["read"]}
            """
        store.handleEvent(try ZulipJSON.decoder.decode(Event.self, from: Data(echo.utf8)))
        #expect(store.outbox.isEmpty)
        #expect(list.messages.map(\.id) == [500])

        // The mark-read flags event that follows must not evict it.
        store.handleEvent(
            try decodeEvent(Fixtures.flagsEventJSON(eventId: 10, op: "add", flag: "read", messages: [500])))
        #expect(list.messages.map(\.id) == [500])
    }
}
