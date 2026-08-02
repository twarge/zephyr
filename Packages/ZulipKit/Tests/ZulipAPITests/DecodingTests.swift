import Foundation
import Testing
import ZulipTestSupport
@testable import ZulipAPI

struct MessageDecodingTests {
    @Test func channelMessage() throws {
        let message = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.channelMessageJSON(id: 7, flags: ["read"]).utf8))
        #expect(message.id == 7)
        #expect(message.type == .stream)
        #expect(message.topic == "greetings")
        #expect(message.displayRecipient == .channelName("general"))
        #expect(message.flags == ["read"])
    }

    @Test func dmMessage() throws {
        let message = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.dmMessageJSON(id: 8, recipientIds: [1, 2]).utf8))
        #expect(message.type == .private)
        guard case .users(let recipients) = message.displayRecipient else {
            Issue.record("expected users recipient")
            return
        }
        #expect(recipients.map(\.id) == [1, 2])
    }

    @Test func initialSnapshot() throws {
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        #expect(snapshot.queueId == "q1")
        #expect(snapshot.lastEventId == -1)
        #expect(snapshot.realmUsers?.count == 2)
        #expect(snapshot.streams?.first?.name == "general")
        #expect(snapshot.unreadMsgs?.count == 0)
    }

    @Test func serverSettingsRealmURLFallback() throws {
        let modern = try ZulipJSON.decoder.decode(
            ServerSettings.self, from: Data(Fixtures.serverSettingsJSON().utf8))
        #expect(modern.realmURL?.absoluteString == "https://test.example")

        let legacy = try ZulipJSON.decoder.decode(
            ServerSettings.self,
            from: Data(#"{"zulip_version": "9.0", "realm_uri": "https://old.example"}"#.utf8))
        #expect(legacy.realmURL?.absoluteString == "https://old.example")
        #expect(legacy.zulipFeatureLevel == nil)
    }
}

struct EventDecodingTests {
    private func decodeEvents(_ json: String) throws -> [Event] {
        try ZulipJSON.decoder.decode(GetEventsResult.self, from: Data(json.utf8)).events
    }

    @Test func messageEvent() throws {
        let events = try decodeEvents(
            Fixtures.eventsJSON([
                Fixtures.messageEventJSON(
                    eventId: 3,
                    message: Fixtures.channelMessageJSON(id: 100),
                    flags: ["mentioned"]),
            ]))
        #expect(events.count == 1)
        #expect(events[0].id == 3)
        guard case .message(let e) = events[0].kind else {
            Issue.record("expected message event")
            return
        }
        #expect(e.message.id == 100)
        #expect(e.flags == ["mentioned"])
    }

    @Test func heartbeatAndFlags() throws {
        let events = try decodeEvents(
            Fixtures.eventsJSON([
                Fixtures.heartbeatJSON(eventId: 4),
                Fixtures.flagsEventJSON(eventId: 5, op: "add", flag: "read", messages: [100, 101]),
            ]))
        guard case .heartbeat = events[0].kind else {
            Issue.record("expected heartbeat")
            return
        }
        guard case .updateMessageFlags(let e) = events[1].kind else {
            Issue.record("expected flags event")
            return
        }
        #expect(e.op == "add")
        #expect(e.flag == "read")
        #expect(e.messages == [100, 101])
        #expect(e.all == false)
    }

    @Test func unknownEventTypeIsForwardCompatible() throws {
        let events = try decodeEvents(
            Fixtures.eventsJSON([
                #"{"id": 9, "type": "presence", "user_id": 2}"#,
                #"{"id": 10, "type": "realm_user", "op": "add", "person": {"user_id": 5, "email": "new@example.com", "full_name": "New", "is_bot": false}}"#,
            ]))
        guard case .unexpected(let type, _) = events[0].kind else {
            Issue.record("expected unexpected event")
            return
        }
        #expect(type == "presence")
        guard case .realmUserAdd(let user) = events[1].kind else {
            Issue.record("expected realm_user add")
            return
        }
        #expect(user.userId == 5)
    }

    @Test func malformedKnownEventThrows() {
        // A known type with a broken payload must throw (crunchy shell):
        // the sync layer turns this into a store rebuild.
        #expect(throws: (any Error).self) {
            try decodeEvents(
                Fixtures.eventsJSON([#"{"id": 11, "type": "message", "message": {"id": "oops"}}"#]))
        }
    }
}

struct RouteRequestTests {
    @Test func registerQueueRequest() async throws {
        let transport = FakeTransport(script: [.json(Fixtures.registerJSON(queueId: "q9"))])
        let connection = ApiConnection(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", transport: transport)
        let result = try await connection.registerQueue(idleQueueTimeoutSeconds: 3600)
        #expect(result.snapshot.queueId == "q9")

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/register")
        #expect(request.formValue("apply_markdown") == "true")
        let capabilities = try #require(request.formValue("client_capabilities"))
        #expect(capabilities.contains("\"empty_topic_name\":true"))
        #expect(capabilities.contains("\"bulk_message_deletion\":true"))
        #expect(request.headers["Authorization"]?.hasPrefix("Basic ") == true)
        // Feature level unknown (nil) → idle_queue_timeout must be omitted.
        #expect(request.formValue("idle_queue_timeout") == nil)
    }

    @Test func idleQueueTimeoutGatedByFeatureLevel() async throws {
        let transport = FakeTransport(script: [.json(Fixtures.registerJSON(queueId: "q1"))])
        let connection = ApiConnection(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", transport: transport)
        connection.featureLevel = 481
        _ = try await connection.registerQueue(idleQueueTimeoutSeconds: 3600)
        #expect(transport.requests.first?.formValue("idle_queue_timeout") == "3600")
    }

    @Test func getEventsRequest() async throws {
        let transport = FakeTransport(script: [.json(Fixtures.eventsJSON([]))])
        let connection = ApiConnection(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", transport: transport)
        _ = try await connection.getEvents(queueId: "q1", lastEventId: 42)
        let request = try #require(transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v1/events")
        #expect(request.queryValue("queue_id") == "q1")
        #expect(request.queryValue("last_event_id") == "42")
        #expect(request.queryValue("dont_block") == nil)
    }

    @Test func narrowEncoding() async throws {
        let transport = FakeTransport(script: [.json(Fixtures.getMessagesJSON([]))])
        let connection = ApiConnection(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", transport: transport)
        _ = try await connection.getMessages(
            anchor: .firstUnread, numBefore: 50, numAfter: 50,
            narrow: [NarrowElement("channel", .int(10)), NarrowElement("topic", .string("hi +1"))])
        let request = try #require(transport.requests.first)
        #expect(request.queryValue("anchor") == "first_unread")
        let narrow = try #require(request.queryValue("narrow"))
        #expect(narrow.contains(#""operator":"channel""#))
        #expect(narrow.contains(#""operand":10"#))
        #expect(narrow.contains("hi +1"))
    }

    @Test func apiErrorMapping() async throws {
        let transport = FakeTransport(script: [
            .json(Fixtures.errorJSON(code: "BAD_EVENT_QUEUE_ID"), status: 400)
        ])
        let connection = ApiConnection(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", transport: transport)
        await #expect {
            _ = try await connection.getEvents(queueId: "dead", lastEventId: -1)
        } throws: { error in
            (error as? ApiError)?.isBadEventQueueId == true
        }
    }

    @Test func malformedSuccessResponseIsTypedError() async throws {
        let transport = FakeTransport(script: [.json(#"{"result": "success", "events": "nope"}"#)])
        let connection = ApiConnection(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", transport: transport)
        await #expect {
            _ = try await connection.getEvents(queueId: "q1", lastEventId: -1)
        } throws: { error in
            (error as? ApiError)?.isMalformedResponse == true
        }
    }
}
