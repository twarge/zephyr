import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

@MainActor
func makeStore(unreadsJSON: String = Fixtures.emptyUnreadsJSON) throws -> PerAccountStore {
    let account = Account(
        realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
    let snapshot = try ZulipJSON.decoder.decode(
        InitialSnapshot.self,
        from: Data(Fixtures.registerJSON(queueId: "q1", unreadMsgs: unreadsJSON).utf8))
    let connection = ApiConnection(
        realmURL: account.realmURL, email: account.email, apiKey: "key",
        transport: FakeTransport(defaultResponse: .hang))
    return PerAccountStore(account: account, connection: connection, snapshot: snapshot)
}

func decodeEvent(_ json: String) throws -> Event {
    try ZulipJSON.decoder.decode(Event.self, from: Data(json.utf8))
}

@MainActor
struct StoreEventTests {
    @Test func snapshotSeedsState() throws {
        let store = try makeStore()
        #expect(store.queueId == "q1")
        #expect(store.users.count == 2)
        #expect(store.channels.count == 1)
        #expect(store.subscriptions.count == 1)
        #expect(store.unreads.totalCount == 0)
    }

    @Test func messageEventAddsMessageAndUnread() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: [])))
        #expect(store.messages[100] != nil)
        #expect(store.unreads.totalCount == 1)
        #expect(
            store.unreads.unreadIds[.topic(streamId: 10, topic: "greetings")] == [100])
    }

    @Test func ownMessageIsNotUnread() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1,
                    message: Fixtures.channelMessageJSON(id: 100, senderId: 1, senderName: "Self"),
                    flags: ["read"])))
        #expect(store.messages[100] != nil)
        #expect(store.unreads.totalCount == 0)
    }

    @Test func readFlagClearsUnread() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: [])))
        try store.handleEvent(
            decodeEvent(Fixtures.flagsEventJSON(eventId: 2, op: "add", flag: "read", messages: [100])))
        #expect(store.unreads.totalCount == 0)
        #expect(store.messages[100]?.flags?.contains("read") == true)
    }

    @Test func unreadFlagRemovalRefiles() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: [])))
        try store.handleEvent(
            decodeEvent(Fixtures.flagsEventJSON(eventId: 2, op: "add", flag: "read", messages: [100])))
        try store.handleEvent(
            decodeEvent(Fixtures.flagsEventJSON(eventId: 3, op: "remove", flag: "read", messages: [100])))
        #expect(store.unreads.totalCount == 1)
    }

    @Test func deleteMessageRemovesMessageAndUnread() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: [])))
        try store.handleEvent(
            decodeEvent(#"{"id": 2, "type": "delete_message", "message_ids": [100], "message_type": "stream"}"#))
        #expect(store.messages[100] == nil)
        #expect(store.unreads.totalCount == 0)
    }

    @Test func editUpdatesContentInPlace() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: [])))
        try store.handleEvent(
            decodeEvent(
                #"{"id": 2, "type": "update_message", "message_id": 100, "rendered_content": "<p>edited</p>", "edit_timestamp": 1750000100}"#))
        #expect(store.messages[100]?.content == "<p>edited</p>")
        #expect(store.messages[100]?.lastEditTimestamp == 1750000100)
    }

    @Test func userLifecycleEvents() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                #"{"id": 1, "type": "realm_user", "op": "add", "person": {"user_id": 5, "email": "new@example.com", "full_name": "New", "is_bot": false}}"#))
        #expect(store.users[5]?.fullName == "New")
        try store.handleEvent(
            decodeEvent(
                #"{"id": 2, "type": "realm_user", "op": "update", "person": {"user_id": 5, "full_name": "Renamed"}}"#))
        #expect(store.users[5]?.fullName == "Renamed")
        try store.handleEvent(
            decodeEvent(#"{"id": 3, "type": "realm_user", "op": "remove", "person": {"user_id": 5, "full_name": "Renamed"}}"#))
        #expect(store.users[5] == nil)
    }

    @Test func fetchedMessagesDoNotClobberStoredOnes() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100, content: "<p>from event</p>"),
                    flags: [])))
        let fetched = try ZulipJSON.decoder.decode(
            Message.self,
            from: Data(Fixtures.channelMessageJSON(id: 100, content: "<p>stale fetch</p>").utf8))
        store.reconcileFetchedMessages([fetched])
        #expect(store.messages[100]?.content == "<p>from event</p>")
    }

    @Test func unexpectedEventIsIgnored() throws {
        let store = try makeStore()
        try store.handleEvent(decodeEvent(#"{"id": 1, "type": "presence", "user_id": 2}"#))
        // No crash, no state change.
        #expect(store.messages.isEmpty)
    }
}

struct UnreadsSnapshotTests {
    @Test @MainActor func dmKeyNormalization() throws {
        let unreadsJSON = """
            {"count": 3,
             "pms": [{"other_user_id": 5, "unread_message_ids": [200]}],
             "huddles": [{"user_ids_string": "1,5,9", "unread_message_ids": [201]}],
             "streams": [{"stream_id": 10, "topic": "greetings", "unread_message_ids": [202]}],
             "mentions": [202], "old_unreads_missing": false}
            """
        let store = try makeStore(unreadsJSON: unreadsJSON)
        #expect(store.unreads.unreadIds[.dm("5")] == [200])
        // Huddle key excludes self (user 1).
        #expect(store.unreads.unreadIds[.dm("5,9")] == [201])
        #expect(store.unreads.unreadIds[.topic(streamId: 10, topic: "greetings")] == [202])
        #expect(store.unreads.mentionIds == [202])
        #expect(store.unreads.totalCount == 3)

        // A DM event lands in the same key space.
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1,
                    message: Fixtures.dmMessageJSON(id: 203, senderId: 5, recipientIds: [1, 5]),
                    flags: [])))
        #expect(store.unreads.unreadIds[.dm("5")] == [200, 203])
    }
}

struct BackoffMachineTests {
    @Test func boundsGrowAndCap() {
        var machine = BackoffMachine(firstBound: .milliseconds(100), maxBound: .seconds(1))
        var previousBound = Duration.zero
        for attempt in 0..<20 {
            let delay = machine.next()
            #expect(delay >= .zero)
            #expect(delay <= .seconds(1))
            if attempt == 0 {
                #expect(delay <= .milliseconds(100))
            }
            previousBound = max(previousBound, delay)
        }
    }

    @Test func resetRestartsSmall() {
        var machine = BackoffMachine(firstBound: .milliseconds(100), maxBound: .seconds(10))
        for _ in 0..<10 { _ = machine.next() }
        machine.reset()
        #expect(machine.next() <= .milliseconds(100))
    }
}

@MainActor
struct SubmessageEventTests {
    @Test func submessageEventUpdatesWidget() throws {
        let transport = FakeTransport(defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        // A poll message, then a live vote submessage event for it.
        let widgetJSON = #"{\"widget_type\": \"poll\", \"extra_data\": {\"question\": \"Lunch?\", \"options\": [\"Pizza\"]}}"#
        let pollMessage = """
            {"id": 700, "sender_id": 5, "sender_full_name": "Poller", "timestamp": 1750000000,
             "type": "stream", "content": "<p>/poll</p>", "stream_id": 10, "subject": "t",
             "display_recipient": "general", "reactions": [],
             "submessages": [{"msg_type": "widget", "sender_id": 5, "content": "\(widgetJSON)"}]}
            """
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(eventId: 1, message: pollMessage, flags: ["read"])))

        let vote = #"{"id": 2, "type": "submessage", "msg_type": "widget", "message_id": 700, "sender_id": 9, "submessage_id": 55, "content": "{\"type\":\"vote\",\"key\":\"canned,0\",\"vote\":1}"}"#
        store.handleEvent(try decodeEvent(vote))

        let message = try #require(store.messages[700])
        guard case .poll(let poll) = MessageWidget.parse(message) else {
            Issue.record("expected poll")
            return
        }
        #expect(poll.options.first?.voterIds == [9])
    }

    @Test func addPollOptionReplaysOwnCounter() async throws {
        let transport = FakeTransport(
            script: [.json(#"{"result": "success", "msg": ""}"#)],
            defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        // A poll where this user (id 1) already added an option with idx 3:
        // the next add must use idx 4 so the option key can't collide.
        let widgetJSON = #"{\"widget_type\": \"poll\", \"extra_data\": {\"question\": \"Lunch?\", \"options\": [\"Pizza\"]}}"#
        let priorOption = #"{\"type\":\"new_option\",\"option\":\"Sushi\",\"idx\":3}"#
        let pollMessage = """
            {"id": 701, "sender_id": 5, "sender_full_name": "Poller", "timestamp": 1750000000,
             "type": "stream", "content": "<p>/poll</p>", "stream_id": 10, "subject": "t",
             "display_recipient": "general", "reactions": [],
             "submessages": [
                {"msg_type": "widget", "sender_id": 5, "content": "\(widgetJSON)"},
                {"msg_type": "widget", "sender_id": 1, "content": "\(priorOption)"}]}
            """
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(eventId: 1, message: pollMessage, flags: ["read"])))

        store.addPollOption(messageId: 701, option: "Ramen")
        try await eventually("submessage sent") { transport.requests.count == 1 }
        let content = try #require(transport.requests[0].formValue("content"))
        #expect(content.contains(#""type":"new_option""#))
        #expect(content.contains(#""idx":4"#))
        #expect(content.contains("Ramen"))
    }
}
