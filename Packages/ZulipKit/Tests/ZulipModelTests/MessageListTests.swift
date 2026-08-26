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

    @Test func warmReopenReaimsMarkerAtArrivalsWhileParked() async throws {
        let (store, _) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 100, flags: ["read"]),
                Fixtures.channelMessageJSON(id: 101, flags: ["read"]),
            ]))
        ])
        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "greetings"))
        await list.fetchInitial()
        #expect(list.firstUnreadMarkerId == nil)

        // Two messages arrive while the model is parked; the viewport was
        // last at the bottom with 101 newest.
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 102), flags: [])))
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 2, message: Fixtures.channelMessageJSON(id: 103), flags: [])))

        // The reopen's resume point is the first while-parked arrival.
        #expect(list.firstUnreadId(after: 101) == 102)
        // Nothing arrived past the live bottom: the restore stands.
        #expect(list.firstUnreadId(after: 103) == nil)
        // No park-time id recorded (empty window): any unread counts.
        #expect(list.firstUnreadId(after: nil) == 102)

        list.reaimUnreadMarker(to: 102)
        #expect(list.firstUnreadMarkerId == 102)
        // An id no longer in the window is ignored.
        list.reaimUnreadMarker(to: 999)
        #expect(list.firstUnreadMarkerId == 102)
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

    @Test func staleFirstUnreadBacklogReanchorsToNewest() async throws {
        // The fixture timestamp (June 2025) is far in the past: a
        // first-unread window that stale re-anchors at the newest messages
        // and suppresses the NEW marker.
        let (store, transport) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 100)], foundNewest: false)),
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 900),
                Fixtures.channelMessageJSON(id: 901),
            ])),
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].queryValue("anchor") == "newest")
        #expect(list.messages.map(\.id) == [900, 901])
        #expect(list.haveNewest)
        #expect(list.firstUnreadMarkerId == nil)
    }

    @Test func recentFirstUnreadBacklogKeepsAnchor() async throws {
        // A backlog whose newest fetched message is recent stays anchored
        // at the first unread (normal Zulip semantics).
        let now = Int(Date.now.timeIntervalSince1970)
        let (store, transport) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 100, timestamp: now - 3600)],
                foundNewest: false))
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()
        #expect(transport.requests.count == 1)
        #expect(list.messages.map(\.id) == [100])
        #expect(!list.haveNewest)
        #expect(list.firstUnreadMarkerId == 100)
    }

    @Test func pagingForwardTrimsWindow() async throws {
        let now = Int(Date.now.timeIntervalSince1970)
        let initial = (0..<550).map {
            Fixtures.channelMessageJSON(id: 1000 + $0, timestamp: now, flags: ["read"])
        }
        let newer = (0..<100).map {
            Fixtures.channelMessageJSON(id: 1550 + $0, timestamp: now, flags: ["read"])
        }
        let (store, _) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON(initial, foundNewest: false)),
            .json(Fixtures.getMessagesJSON(newer)),
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()
        await list.fetchNewer()
        #expect(list.messages.count == 600)
        #expect(list.messages.first?.id == 1050)
        #expect(list.messages.last?.id == 1649)
        #expect(!list.haveOldest)
        #expect(list.haveNewest)
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

    /// "" and "(no topic)" are the same thread server-side (responses use
    /// one or the other depending on allow_empty_topic_name), so membership
    /// checks must treat them as equal in either direction.
    @Test func emptyTopicAliasMembership() throws {
        let legacy = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.channelMessageJSON(id: 6, topic: "(no topic)").utf8))
        let modern = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.channelMessageJSON(id: 7, topic: "").utf8))
        #expect(Narrow.topic(streamId: 10, topic: "").containsMessage(legacy, selfUserId: 1))
        #expect(Narrow.topic(streamId: 10, topic: "(no topic)")
            .containsMessage(modern, selfUserId: 1))
        #expect(!Narrow.topic(streamId: 10, topic: "real topic")
            .containsMessage(modern, selfUserId: 1))

        #expect(SendDestination.topic(streamId: 10, topic: "")
            .matches(narrow: .topic(streamId: 10, topic: "(no topic)"), selfUserId: 1))
        #expect(SendDestination.topic(streamId: 10, topic: "(no topic)")
            .matches(narrow: .topic(streamId: 10, topic: ""), selfUserId: 1))
    }

    /// Regression: a message whose stored subject is the event-stream form
    /// ("") of the empty topic must survive change events (a reaction, a
    /// flag flip) in a list opened under the fetch form ("(no topic)") —
    /// it used to be evicted by the literal membership re-check.
    @Test func emptyTopicAliasSurvivesChangeEvents() async throws {
        let (store, _) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 100, topic: "(no topic)", flags: ["read"])
            ]))
        ])
        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "(no topic)"))
        await list.fetchInitial()
        #expect(list.messages.map(\.id) == [100])

        // A live arrival carries the capability form of the same thread.
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 101, topic: ""), flags: [])))
        #expect(list.messages.map(\.id) == [100, 101])

        // A change event re-evaluates membership; both forms stay.
        store.handleEvent(
            try decodeEvent(
                Fixtures.flagsEventJSON(eventId: 2, op: "add", flag: "read", messages: [100, 101])))
        #expect(list.messages.map(\.id) == [100, 101])
    }

    /// Regression: a live arrival while the window doesn't reach the newest
    /// message (mid-history anchor) is held and merged once a jump fetch
    /// re-establishes haveNewest — even when that fetch's server snapshot
    /// predates the message. It used to be dropped, which lost just-sent
    /// replies outright (their one echo event also clears the outbox row).
    @Test func liveArrivalMidHistoryMergesAfterJump() async throws {
        let now = Int(Date.now.timeIntervalSince1970)
        let (store, _) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 100, timestamp: now)], foundNewest: false)),
            // The jump's snapshot doesn't include the echo yet.
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 400, timestamp: now, flags: ["read"]),
                Fixtures.channelMessageJSON(id: 401, timestamp: now, flags: ["read"]),
            ])),
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()
        #expect(!list.haveNewest)

        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 500), flags: [])))
        // Not appended mid-history — held for the jump below.
        #expect(list.messages.map(\.id) == [100])

        await list.jumpToNewest()
        #expect(list.messages.map(\.id) == [400, 401, 500])
        #expect(list.haveNewest)
    }

    /// Regression: a jump's wholesale replace must not wipe messages that
    /// were live-appended while its fetch was in flight.
    @Test func jumpReplaceKeepsLiveTail() async throws {
        let now = Int(Date.now.timeIntervalSince1970)
        let (store, _) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 100, timestamp: now, flags: ["read"])])),
            // The re-fetch's snapshot predates the appended arrival.
            .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 100, timestamp: now, flags: ["read"])])),
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1, message: Fixtures.channelMessageJSON(id: 101), flags: [])))
        #expect(list.messages.map(\.id) == [100, 101])

        await list.jumpToNewest()
        #expect(list.messages.map(\.id) == [100, 101])
    }

    /// Regression: an own-send echo buffered by a mid-history window (its
    /// send-time jump failed) is surfaced by the reconnect recovery hook —
    /// the echo consumed the outbox row, so nothing else represents it.
    @Test func buriedOwnSendRecoversViaJump() async throws {
        let now = Int(Date.now.timeIntervalSince1970)
        let (store, transport) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 100, timestamp: now)], foundNewest: false)),
            .networkError,  // The send-time jump fails.
            .json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 400, timestamp: now, flags: ["read"]),
                Fixtures.channelMessageJSON(id: 500, senderId: 1, timestamp: now),
            ])),
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()
        #expect(!list.haveNewest)

        // Our own send's echo arrives mid-history and is buffered.
        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1,
                    message: Fixtures.channelMessageJSON(id: 500, senderId: 1, timestamp: now),
                    flags: [])))
        #expect(list.messages.map(\.id) == [100])

        await list.jumpToNewest()  // The send-time jump: fails.
        #expect(!list.haveNewest)

        list.recoverBuriedOwnSends()
        for _ in 0..<500 where !list.haveNewest { await Task.yield() }
        #expect(list.haveNewest)
        #expect(list.messages.map(\.id) == [400, 500])
        #expect(transport.requests.count == 3)
    }

    /// Buffered arrivals from others don't trigger the recovery jump — the
    /// reader parked mid-history on purpose.
    @Test func buriedOthersArrivalDoesNotAutoJump() async throws {
        let now = Int(Date.now.timeIntervalSince1970)
        let (store, transport) = try makeStoreWithTransport(script: [
            .json(Fixtures.getMessagesJSON(
                [Fixtures.channelMessageJSON(id: 100, timestamp: now)], foundNewest: false))
        ])
        let list = MessageListModel(store: store, narrow: .channel(streamId: 10))
        await list.fetchInitial()

        store.handleEvent(
            try decodeEvent(
                Fixtures.messageEventJSON(
                    eventId: 1,
                    message: Fixtures.channelMessageJSON(id: 500, timestamp: now), flags: [])))
        list.recoverBuriedOwnSends()
        for _ in 0..<50 { await Task.yield() }
        #expect(!list.haveNewest)
        #expect(list.messages.map(\.id) == [100])
        #expect(transport.requests.count == 1)
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
