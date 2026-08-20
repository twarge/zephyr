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

    @Test func dmWithMentionCountsOnceInBadge() throws {
        let store = try makeStore()
        // A DM that also mentions you: in unreadIds AND mentionIds.
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.dmMessageJSON(id: 100),
                    flags: ["mentioned"])))
        #expect(store.unreads.dmCount == 1)
        #expect(store.unreads.mentionIds == [100])
        #expect(store.unreads.dmAndMentionCount == 1)
        // A channel mention adds one; a plain DM adds one more.
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 2, message: Fixtures.channelMessageJSON(id: 101),
                    flags: ["mentioned"])))
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 3, message: Fixtures.dmMessageJSON(id: 102))))
        #expect(store.unreads.dmAndMentionCount == 3)
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

    @Test func createChannelSendsSubscriptionWithFlags() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        try await store.createChannel(
            name: "ops", description: "Operations", inviteOnly: true, announce: false)
        let request = try #require(transport.requests.first)
        #expect(request.path.hasSuffix("/users/me/subscriptions"))
        let subscriptions = try #require(request.formValue("subscriptions"))
        #expect(subscriptions.contains(#""name": "ops""#))
        #expect(subscriptions.contains(#""description": "Operations""#))
        #expect(request.formValue("invite_only") == "true")
        #expect(request.formValue("announce") == "false")

        store.archiveChannel(10)
        try await eventually("archive sent") { transport.requests.count == 2 }
        #expect(transport.requests[1].method == "DELETE")
        #expect(transport.requests[1].path.hasSuffix("/streams/10"))
    }

    @Test func descriptionEditAndUnarchivePatchStream() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.setChannelDescription(10, description: "War room")
        #expect(store.channels[10]?.description == "War room")
        #expect(store.subscriptions[10]?.description == "War room")
        try await eventually("description sent") { transport.requests.count == 1 }
        #expect(transport.requests[0].method == "PATCH")
        #expect(transport.requests[0].path.hasSuffix("/streams/10"))
        #expect(transport.requests[0].formValue("description") == "War room")

        try await store.unarchiveChannel(10)
        #expect(transport.requests[1].formValue("is_archived") == "false")
    }

    @Test func subscriberManagementUsesPrincipals() async throws {
        let transport = FakeTransport(
            script: [
                .json(#"{"result": "success", "msg": "", "subscribers": [1, 5]}"#),
            ], defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        let subscribers = try await store.fetchSubscribers(streamId: 10)
        #expect(subscribers == [1, 5])

        try await store.addSubscriber(userId: 7, toChannel: 10)
        #expect(transport.requests[1].method == "POST")
        #expect(transport.requests[1].formValue("principals") == "[7]")

        // DELETE params ride the query string.
        try await store.removeSubscriber(userId: 5, fromChannel: 10)
        #expect(transport.requests[2].method == "DELETE")
        #expect(transport.requests[2].queryValue("principals") == "[5]")
        #expect(transport.requests[2].queryValue("subscriptions")?.contains("general") == true)
    }

    @Test func archivedStreamEventRemovesChannelAndSubscription() throws {
        let store = try makeStore()
        #expect(store.subscriptions[10] != nil)
        try store.handleEvent(
            decodeEvent(
                #"{"id": 1, "type": "stream", "op": "update", "stream_id": 10, "property": "is_archived", "value": true}"#))
        #expect(store.channels[10] == nil)
        #expect(store.subscriptions[10] == nil)
    }

    @Test func streamRenameEventUpdatesChannelAndSubscription() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                #"{"id": 1, "type": "stream", "op": "update", "stream_id": 10, "property": "name", "value": "renamed"}"#))
        #expect(store.channels[10]?.name == "renamed")
        #expect(store.subscriptions[10]?.name == "renamed")
    }

    @Test func renameChannelPatchesStreamAndAppliesOptimistically() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.renameChannel(10, to: "  engineering ")
        #expect(store.subscriptions[10]?.name == "engineering")
        #expect(store.channels[10]?.name == "engineering")
        try await eventually("rename sent") { transport.requests.count == 1 }
        let request = transport.requests[0]
        #expect(request.method == "PATCH")
        #expect(request.path.hasSuffix("/streams/10"))
        #expect(request.formValue("new_name") == "engineering")
    }

    @Test func markUnreadFromHereRemovesReadOverNarrowUntilNewest() async throws {
        let transport = FakeTransport(
            script: [
                // First batch stops short; the second reaches the newest.
                .json(#"""
                    {"result": "success", "msg": "", "processed_count": 5000,
                     "updated_count": 5000, "first_processed_id": 100,
                     "last_processed_id": 5099, "found_oldest": false, "found_newest": false}
                    """#),
                .json(#"""
                    {"result": "success", "msg": "", "processed_count": 40,
                     "updated_count": 40, "first_processed_id": 5100,
                     "last_processed_id": 5139, "found_oldest": false, "found_newest": true}
                    """#),
            ], defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: ["read"])))

        store.markUnreadFromHere(try #require(store.messages[100]))
        try await eventually("both batches sent") { transport.requests.count == 2 }

        let first = transport.requests[0]
        #expect(first.path.hasSuffix("/messages/flags/narrow"))
        #expect(first.formValue("op") == "remove")
        #expect(first.formValue("flag") == "read")
        #expect(first.formValue("anchor") == "100")
        #expect(first.formValue("include_anchor") == "true")
        #expect(first.formValue("num_before") == "0")
        let narrow = try #require(first.formValue("narrow"))
        #expect(narrow.contains(#""operand":10"#))
        #expect(narrow.contains("greetings"))

        let second = transport.requests[1]
        #expect(second.formValue("anchor") == "5099")
        #expect(second.formValue("include_anchor") == "false")
    }

    @Test func markChannelUnreadStartsAtOldestWithChannelNarrow() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"""
                {"result": "success", "msg": "", "processed_count": 1,
                 "updated_count": 1, "first_processed_id": 1,
                 "last_processed_id": 1, "found_oldest": true, "found_newest": true}
                """#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.markChannelUnread(10)
        try await eventually("flags sent") { transport.requests.count == 1 }
        let request = transport.requests[0]
        #expect(request.path.hasSuffix("/messages/flags/narrow"))
        #expect(request.formValue("anchor") == "oldest")
        #expect(request.formValue("op") == "remove")
        let narrow = try #require(request.formValue("narrow"))
        #expect(narrow.contains(#""operator":"channel""#))
        #expect(narrow.contains(#""operand":10"#))
    }

    @Test func markChannelAllReadSweepsChannelNarrowAccumulatingCount() async throws {
        let transport = FakeTransport(
            script: [
                // First batch stops short; the second reaches the newest.
                .json(#"""
                    {"result": "success", "msg": "", "processed_count": 5000,
                     "updated_count": 4800, "first_processed_id": 1,
                     "last_processed_id": 5000, "found_oldest": true, "found_newest": false}
                    """#),
                .json(#"""
                    {"result": "success", "msg": "", "processed_count": 240,
                     "updated_count": 240, "first_processed_id": 5001,
                     "last_processed_id": 5240, "found_oldest": false, "found_newest": true}
                    """#),
            ], defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.markChannelAllRead(10)
        #expect(store.markReadSweep == .running(markedCount: 0))
        try await eventually("both batches sent") { transport.requests.count == 2 }

        let first = transport.requests[0]
        #expect(first.path.hasSuffix("/messages/flags/narrow"))
        #expect(first.formValue("op") == "add")
        #expect(first.formValue("flag") == "read")
        #expect(first.formValue("anchor") == "oldest")
        #expect(first.formValue("include_anchor") == "true")
        #expect(first.formValue("num_before") == "0")
        let narrow = try #require(first.formValue("narrow"))
        #expect(narrow.contains(#""operator":"channel""#))
        #expect(narrow.contains(#""operand":10"#))

        let second = transport.requests[1]
        #expect(second.formValue("anchor") == "5000")
        #expect(second.formValue("include_anchor") == "false")
        try await eventually("sweep finished with the summed count") {
            store.markReadSweep == .finished(markedCount: 5040)
        }
    }

    @Test func markAllReadSweepsEmptyNarrow() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"""
                {"result": "success", "msg": "", "processed_count": 7,
                 "updated_count": 7, "first_processed_id": 1,
                 "last_processed_id": 7, "found_oldest": true, "found_newest": true}
                """#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.markAllRead()
        try await eventually("flags sent") { transport.requests.count == 1 }
        let request = transport.requests[0]
        #expect(request.path.hasSuffix("/messages/flags/narrow"))
        #expect(request.formValue("op") == "add")
        #expect(request.formValue("narrow") == "[]")
        try await eventually("sweep finished") {
            store.markReadSweep == .finished(markedCount: 7)
        }
    }

    @Test func markAllReadFailureSurfacesInSweepState() async throws {
        let transport = FakeTransport(defaultResponse: .networkError)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.markAllRead()
        try await eventually("sweep failed") { store.markReadSweep == .failed }
    }

    @Test func setChannelColorSendsStringPropertyAndAppliesOptimistically() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.setChannelColor(10, hex: "#76ce90")
        #expect(store.subscriptions[10]?.color == "#76ce90")
        try await eventually("property sent") { transport.requests.count == 1 }
        let data = try #require(transport.requests[0].formValue("subscription_data"))
        #expect(data.contains(#""property": "color""#))
        #expect(data.contains(##""value": "#76ce90""##))
    }

    @Test func reminderRefreshPopulatesAndCancelDeletes() async throws {
        let transport = FakeTransport(
            script: [
                .json(#"""
                    {"result": "success", "msg": "", "reminders": [
                        {"reminder_id": 7, "reminder_target_message_id": 100,
                         "scheduled_delivery_timestamp": 1800000000}]}
                    """#),
                .json(#"{"result": "success", "msg": ""}"#),
                .json(#"{"result": "success", "msg": "", "reminders": []}"#),
            ], defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        await store.refreshReminders()
        #expect(store.reminders[7]?.reminderTargetMessageId == 100)
        #expect(store.reminderForMessage(100)?.reminderId == 7)

        store.cancelReminder(7)
        #expect(store.reminders.isEmpty)
        try await eventually("delete and refetch sent") { transport.requests.count == 3 }
        #expect(transport.requests[1].method == "DELETE")
        #expect(transport.requests[1].path.hasSuffix("/reminders/7"))
        #expect(transport.requests[2].method == "GET")
    }

    @Test func remindAboutMessagePostsReminder() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.remindAboutMessage(100, at: Date(timeIntervalSince1970: 1_800_000_000))
        // >= not ==: the create is followed by a reminders refetch
        // (request #2), and under CI load the first poll can land after
        // both — an exact ==1 then never holds (the flake this replaced).
        try await eventually("reminder sent") { transport.requests.count >= 1 }
        let request = transport.requests[0]
        #expect(request.path.hasSuffix("/reminders"))
        #expect(request.formValue("message_id") == "100")
        #expect(request.formValue("scheduled_delivery_timestamp") == "1800000000")
    }

    @Test func resolveTopicMovesWholeTopicWithPrefix() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: ["read"])))

        store.setTopicResolved(streamId: 10, topic: "greetings", resolved: true)
        try await eventually("move sent") { transport.requests.count == 1 }
        let request = transport.requests[0]
        #expect(request.path.hasSuffix("/messages/100"))
        #expect(request.formValue("topic") == "✔ greetings")
        #expect(request.formValue("propagate_mode") == "change_all")

        // Already-resolved is a no-op.
        store.setTopicResolved(streamId: 10, topic: "✔ done", resolved: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.requests.count == 1)
    }

    @Test func moveMessageAcrossChannelsSendsStreamId() async throws {
        let transport = FakeTransport(
            defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        store.moveMessage(100, toTopic: "planning", toChannel: 20, propagateMode: "change_all")
        try await eventually("move sent") { transport.requests.count == 1 }
        let request = transport.requests[0]
        #expect(request.method == "PATCH")
        #expect(request.path.hasSuffix("/messages/100"))
        #expect(request.formValue("topic") == "planning")
        #expect(request.formValue("stream_id") == "20")
        #expect(request.formValue("propagate_mode") == "change_all")

        // A same-channel move omits stream_id entirely.
        store.moveMessage(101, toTopic: "planning", propagateMode: "change_one")
        try await eventually("second move sent") { transport.requests.count == 2 }
        #expect(transport.requests[1].formValue("stream_id") == nil)
    }

    @Test func markMessageUnreadFlipsFlagAndRefiles() throws {
        let store = try makeStore()
        try store.handleEvent(
            decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 100),
                    flags: ["read"])))
        #expect(store.unreads.totalCount == 0)

        store.markMessageUnread(100)
        #expect(store.messages[100]?.flags?.contains("read") == false)
        #expect(store.unreads.totalCount == 1)
    }

    @Test func starFlagsMaintainStarredCount() throws {
        let store = try makeStore()
        #expect(store.starredMessageIds.isEmpty)
        try store.handleEvent(
            decodeEvent(
                Fixtures.flagsEventJSON(
                    eventId: 1, op: "add", flag: "starred", messages: [100, 101])))
        #expect(store.starredMessageIds == [100, 101])
        store.setStarred(true, messageId: 102)
        #expect(store.starredMessageIds.count == 3)
        try store.handleEvent(
            decodeEvent(
                Fixtures.flagsEventJSON(
                    eventId: 2, op: "remove", flag: "starred", messages: [100])))
        #expect(store.starredMessageIds == [101, 102])
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

    @Test func addTodoTaskReplaysOwnCounterAndTitleEventApplies() async throws {
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

        // A todo list where this user (id 1) already added a task with
        // key 2: the next add must use key 3.
        let widgetJSON = #"{\"widget_type\": \"todo\", \"extra_data\": {\"task_list_title\": \"Chores\", \"tasks\": [{\"task\": \"Dishes\", \"desc\": \"\"}]}}"#
        let priorTask = #"{\"type\":\"new_task\",\"key\":2,\"task\":\"Sweep\",\"desc\":\"\",\"completed\":false}"#
        let todoMessage = """
            {"id": 801, "sender_id": 5, "sender_full_name": "Lister", "timestamp": 1750000000,
             "type": "stream", "content": "<p>/todo</p>", "stream_id": 10, "subject": "t",
             "display_recipient": "general", "reactions": [],
             "submessages": [
                {"msg_type": "widget", "sender_id": 5, "content": "\(widgetJSON)"},
                {"msg_type": "widget", "sender_id": 1, "content": "\(priorTask)"}]}
            """
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(eventId: 1, message: todoMessage, flags: ["read"])))

        store.addTodoTask(messageId: 801, task: "Laundry", detail: "whites")
        try await eventually("submessage sent") { transport.requests.count == 1 }
        let content = try #require(transport.requests[0].formValue("content"))
        #expect(content.contains(#""type":"new_task""#))
        #expect(content.contains(#""key":3"#))
        #expect(content.contains("Laundry"))

        // A live retitle event (author) updates the parsed widget.
        let retitle = #"{"id": 2, "type": "submessage", "msg_type": "widget", "message_id": 801, "sender_id": 5, "submessage_id": 60, "content": "{\"type\":\"new_task_list_title\",\"title\":\"Weekend chores\"}"}"#
        store.handleEvent(try decodeEvent(retitle))
        let message = try #require(store.messages[801])
        guard case .todoList(let list) = MessageWidget.parse(message) else {
            Issue.record("expected todo list")
            return
        }
        #expect(list.title == "Weekend chores")
    }
}

@MainActor
@Suite struct ReconcileRefreshTests {
    private static let widgetJSON = #"{\"widget_type\": \"todo\", \"extra_data\": {\"tasks\": [{\"task\": \"Dishes\", \"desc\": \"\"}]}}"#
    private static let strike = #"{\"type\":\"strike\",\"key\":\"canned,0\"}"#

    private func todoMessage(submessages: String) -> String {
        """
        {"id": 900, "sender_id": 5, "sender_full_name": "Lister", "timestamp": 1750000000,
         "type": "stream", "content": "<p>/todo</p>", "stream_id": 10, "subject": "t",
         "display_recipient": "general", "reactions": [], "flags": ["read"],
         "submessages": [\(submessages)]}
        """
    }

    @Test func refetchRefreshesSubmessagesButKeepsLocalFlags() throws {
        let transport = FakeTransport(defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)

        // In memory without strikes (e.g. fetched before the app closed)…
        let initial = try ZulipJSON.decoder.decode(
            Message.self,
            from: Data(todoMessage(
                submessages: #"{"msg_type": "widget", "sender_id": 5, "content": "\#(Self.widgetJSON)"}"#).utf8))
        store.reconcileFetchedMessages([initial])
        // …locally starred meanwhile (optimistic flag change)…
        store.setStarred(true, messageId: 900)
        #expect(store.messages[900]?.flags?.contains("starred") == true)

        // …then a refetch arrives carrying a strike made in the gap.
        let refetched = try ZulipJSON.decoder.decode(
            Message.self,
            from: Data(todoMessage(
                submessages: #"{"msg_type": "widget", "sender_id": 5, "content": "\#(Self.widgetJSON)"}, {"msg_type": "widget", "sender_id": 9, "content": "\#(Self.strike)"}"#).utf8))
        store.reconcileFetchedMessages([refetched])

        let message = try #require(store.messages[900])
        guard case .todoList(let list) = MessageWidget.parse(message) else {
            Issue.record("expected todo list")
            return
        }
        #expect(list.tasks.first?.completed == true)
        #expect(message.flags?.contains("starred") == true)
    }
}

