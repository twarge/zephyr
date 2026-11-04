import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

struct TopicLinkExtractionTests {
    private let realm = URL(string: "https://chat.example.com")!

    @Test func topicAndMessageLinks() {
        let html = """
            <p>See <a class="stream-topic" data-stream-id="9" \
            href="/#narrow/channel/9-design/topic/link.20views">#design &gt; link views</a> \
            and <a class="message-link" \
            href="/#narrow/channel/9-design/topic/link.20views/near/123">#design &gt; link views @ 💬</a></p>
            """
        #expect(TopicLink.links(inHTML: html, realmURL: realm) == [
            TopicLink(streamId: 9, topic: "link views", messageId: nil, kind: .topic),
            TopicLink(streamId: 9, topic: "link views", messageId: 123, kind: .message),
        ])
    }

    @Test func topicPermalinkIsAnchoredTopicLink() {
        // What the server renders #**design>link views** as.
        let html = """
            <p><a class="stream-topic" data-stream-id="9" \
            href="/#narrow/channel/9-design/topic/link.20views/with/456">#design &gt; link views</a></p>
            """
        #expect(TopicLink.links(inHTML: html, realmURL: realm) == [
            TopicLink(streamId: 9, topic: "link views", messageId: 456, kind: .topic),
        ])
    }

    @Test func channelDMAndExternalLinksDontCount() {
        let html = """
            <p><a class="stream" data-stream-id="9" href="/#narrow/channel/9-design">#design</a> \
            <a href="/#narrow/dm/2,3-dm/near/5">dm</a> \
            <a href="https://example.org/#narrow/channel/9-x/topic/y">elsewhere</a> \
            <a href="https://zulip.com/help/">help</a></p>
            """
        #expect(TopicLink.links(inHTML: html, realmURL: realm).isEmpty)
    }

    @Test func absoluteLinksNeedTheRealmHost() {
        let html = """
            <p><a href="https://chat.example.com/#narrow/channel/9-design/topic/a">a</a> \
            <a href="#narrow/channel/9-design/topic/b">b</a></p>
            """
        #expect(TopicLink.links(inHTML: html, realmURL: realm).map(\.topic) == ["a", "b"])
        // Not knowing the realm, only relative links count.
        #expect(TopicLink.links(inHTML: html, realmURL: nil).map(\.topic) == ["b"])
    }

    @Test func emptyTopicAndEntities() {
        let html = """
            <p><a class="stream-topic" data-stream-id="9" \
            href="/#narrow/channel/9-design/topic//with/7">#design &gt; <em>general chat</em></a> \
            <a href="/#narrow/channel/9-design/topic/R.26D">R&amp;D</a> \
            <a href="/#narrow/channel/9-design/topic/a&amp;b">odd</a></p>
            """
        #expect(TopicLink.links(inHTML: html, realmURL: realm) == [
            TopicLink(streamId: 9, topic: "", messageId: 7, kind: .topic),
            TopicLink(streamId: 9, topic: "R&D", messageId: nil, kind: .topic),
            TopicLink(streamId: 9, topic: "a&b", messageId: nil, kind: .topic),
        ])
    }

    @Test func narrowTextOutsideLinksIsIgnored() {
        // In code, "<" is escaped, so no anchor can hide there.
        let html = "<pre><code>&lt;a href=\"/#narrow/channel/9-x/topic/y\"&gt;</code></pre>"
        #expect(TopicLink.mentionsNarrow(html))
        #expect(TopicLink.links(inHTML: html, realmURL: realm).isEmpty)
        #expect(!TopicLink.mentionsNarrow("<p>no links here</p>"))
    }
}

struct EmptyTopicInternalLinkTests {
    private let realm = URL(string: "https://chat.example.com")!

    @Test func emptyTopicOperand() {
        #expect(
            InternalLink.parse(href: "/#narrow/channel/9-design/topic/", realmURL: realm)
                == .topic(streamId: 9, topic: "", nearMessageId: nil))
        #expect(
            InternalLink.parse(href: "/#narrow/channel/9-design/topic//near/12", realmURL: realm)
                == .topic(streamId: 9, topic: "", nearMessageId: 12))
    }

    @Test func otherEmptyComponentsStillDropOut() {
        #expect(
            InternalLink.parse(href: "/#narrow/channel/9-design/", realmURL: realm)
                == .channel(streamId: 9))
        #expect(
            InternalLink.parse(href: "/#narrow/channel/9-design/topic/topic/", realmURL: realm)
                == .topic(streamId: 9, topic: "topic", nearMessageId: nil))
        #expect(InternalLink.parse(href: "/#recent/", realmURL: realm) == .recent)
    }
}

struct TopicLinkListsTests {
    private func record(
        _ id: Int, from: (Int, String), to: (Int, String), message: Int? = nil,
        kind: TopicLink.Kind = .topic, sender: String? = nil
    ) -> TopicLinkRecord {
        TopicLinkRecord(
            fromMessageId: id, fromStreamId: from.0, fromTopic: from.1,
            target: TopicLink(streamId: to.0, topic: to.1, messageId: message, kind: kind),
            sender: sender)
    }

    @Test func linksToDedupesAndKeepsOrder() {
        let here = (10, "plans")
        let lists = TopicLinkLists(
            streamId: 10, topic: "Plans",
            outgoing: [
                record(5, from: here, to: (10, "Budget"), message: 40, kind: .message),
                record(3, from: here, to: (10, "budget")),
                // Anchored differently, still the same topic.
                record(4, from: here, to: (10, "Budget"), message: 9),
                // A second link to the same message is one row; another
                // message in the topic is its own.
                record(6, from: here, to: (10, "budget"), message: 40, kind: .message),
                record(7, from: here, to: (10, "budget"), message: 41, kind: .message),
                // Links within the topic itself are left out.
                record(8, from: here, to: (10, "PLANS"), message: 2, kind: .message),
            ],
            incoming: [])
        #expect(lists.linksTo.map(\.topic) == ["budget", "Budget", "budget"])
        #expect(lists.linksTo.map(\.messageId) == [nil, 40, 41])
        #expect(lists.linksTo.map(\.isMessageLink) == [false, true, true])
        #expect(lists.linkedFrom.isEmpty)
    }

    @Test func linkedFromIsOneRowPerConversationAtItsOldestLink() {
        let lists = TopicLinkLists(
            streamId: 10, topic: "plans",
            outgoing: [],
            incoming: [
                record(9, from: (10, "standup"), to: (10, "plans"), sender: "B"),
                record(4, from: (10, "standup"), to: (10, "plans"), sender: "A"),
                record(6, from: (10, "retro"), to: (10, "Plans"), message: 1, kind: .message),
                // Resolved elsewhere (its target message moved away).
                record(7, from: (10, "ideas"), to: (10, "archive"), message: 2, kind: .message),
                // From within the topic itself.
                record(8, from: (10, "plans"), to: (10, "plans")),
            ])
        #expect(lists.linkedFrom.map(\.topic) == ["standup", "retro"])
        #expect(lists.linkedFrom.map(\.messageId) == [4, 6])
        #expect(lists.linkedFrom.first?.sender == "A")
        #expect(lists.linkedFrom.allSatisfy { $0.isMessageLink })
    }

    @Test func hiddenChannelsAndEmptyTopicAliases() {
        let lists = TopicLinkLists(
            streamId: 10, topic: "",
            outgoing: [
                record(1, from: (10, "(no topic)"), to: (20, "secret")),
                record(2, from: (10, ""), to: (10, "open")),
                // The legacy name for the same empty topic.
                record(3, from: (10, ""), to: (10, "(no topic)")),
            ],
            incoming: [record(4, from: (20, "secret"), to: (10, "(no topic)"))],
            isVisible: { $0 == 10 })
        #expect(lists.linksTo.map(\.topic) == ["open"])
        #expect(lists.linkedFrom.isEmpty)
    }

    @Test func linkedTopicsCoversBothEnds() {
        let linked = TopicLinkIndex.linkedTopics(from: [
            record(1, from: (10, "Plans"), to: (20, "budget")),
            record(2, from: (10, "plans"), to: (10, "PLANS")),
        ])
        #expect(linked == [
            TopicLinkIndex.key(streamId: 10, topic: "plans"): [20],
            TopicLinkIndex.key(streamId: 20, topic: "Budget"): [10],
        ])
    }

    @Test func searchWordsComeFromBothNames() {
        #expect(
            TopicLinkIndex.searchWords(channel: "dev-ops", topic: "✔ link views!")
                == "dev ops link views")
        #expect(TopicLinkIndex.searchWords(channel: "general", topic: "") == nil)
        #expect(TopicLinkIndex.searchWords(channel: "general", topic: "🎉") == nil)
    }
}

/// The database's link index: maintained as messages are written, edited,
/// moved and deleted, and backfilled for rows written before it existed.
struct TopicLinkDatabaseTests {
    private func tempDatabase() throws -> (MessageDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zephyr-link-tests-\(UUID().uuidString)")
        let offline = OfflineStore(directory: directory)
        let database = try #require(
            offline.openDatabase(realmURL: URL(string: "https://test.example")!))
        return (database, directory)
    }

    private func message(
        _ id: Int, topic: String, streamId: Int = 10, links: [String] = [],
        sender: String = "Other"
    ) throws -> Message {
        let anchors = links.map { "<a href=\"\($0)\">link</a>" }.joined(separator: " ")
        return try ZulipJSON.decoder.decode(
            Message.self,
            from: Data(Fixtures.channelMessageJSON(
                id: id, senderName: sender, streamId: streamId, topic: topic,
                content: "<p>text \(anchors)</p>").utf8))
    }

    private func lists(_ database: MessageDatabase, _ topic: String) throws -> TopicLinkLists {
        TopicLinkLists(
            streamId: 10, topic: topic,
            outgoing: try database.links(from: 10, topic: topic),
            incoming: try database.links(to: 10, topic: topic))
    }

    @Test func bothDirectionsFromStoredHistory() throws {
        let (database, directory) = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try database.upsert([
            try message(1, topic: "budget", sender: "Ann"),
            try message(2, topic: "plans", links: [
                "/#narrow/channel/10-general/topic/budget/near/1",
                "https://test.example/#narrow/channel/10-general/topic/ideas",
            ]),
            try message(3, topic: "standup", links: ["/#narrow/channel/10-general/topic/plans"]),
        ], selfUserId: 1)

        let plans = try lists(database, "Plans")
        #expect(plans.linksTo.map(\.topic) == ["budget", "ideas"])
        #expect(plans.linksTo.first?.messageId == 1)
        // A stored target message describes its row.
        #expect(plans.linksTo.first?.sender == "Ann")
        #expect(plans.linkedFrom.map(\.topic) == ["standup"])
        #expect(plans.linkedFrom.first?.messageId == 3)
        #expect(try lists(database, "budget").linkedFrom.map(\.topic) == ["plans"])
        #expect(try database.allLinks().count == 3)
    }

    @Test func linkTargetsMatchTopicsLikeTopicNames() throws {
        let (database, directory) = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try database.upsert([
            // Beyond ASCII case folding, and the empty topic's legacy name.
            try message(1, topic: "a", links: ["/#narrow/channel/10-general/topic/.C3.9Cber"]),
            try message(2, topic: "b", links: ["/#narrow/channel/10-general/topic/(no.20topic)"]),
        ], selfUserId: 1)
        #expect(try lists(database, "über").linkedFrom.map(\.topic) == ["a"])
        #expect(try lists(database, "").linkedFrom.map(\.topic) == ["b"])
    }

    @Test func linksFollowTheirMessagesAcrossMoves() throws {
        let (database, directory) = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try database.upsert([
            try message(1, topic: "budget"),
            try message(2, topic: "plans", links: [
                "/#narrow/channel/10-general/topic/budget/with/1",
            ]),
        ], selfUserId: 1)

        // The anchor moves (a rename of "budget"): the link follows it.
        try database.move(ids: [1], toStreamId: nil, topic: "budget 2027", selfUserId: 1)
        #expect(try lists(database, "plans").linksTo.map(\.topic) == ["budget 2027"])
        #expect(try lists(database, "budget 2027").linkedFrom.map(\.topic) == ["plans"])
        #expect(try lists(database, "budget").linkedFrom.isEmpty)

        // The linking message moves: its links start from the new topic.
        try database.move(ids: [2], toStreamId: nil, topic: "roadmap", selfUserId: 1)
        #expect(try lists(database, "roadmap").linksTo.map(\.topic) == ["budget 2027"])
        #expect(try lists(database, "plans").isEmpty)
        // The moved copy is what the transcript reads too.
        #expect(try database.older(than: 10, matching: .topic(streamId: 10, topic: "roadmap"),
                                   limit: 10).map(\.subject) == ["roadmap"])
    }

    @Test func editsAndDeletesUpdateTheIndex() throws {
        let (database, directory) = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        var linking = try message(2, topic: "plans", links: [
            "/#narrow/channel/10-general/topic/budget",
        ])
        try database.upsert([linking], selfUserId: 1)
        #expect(try database.linkCount() == 1)

        linking.content = "<p><a href=\"/#narrow/channel/10-general/topic/ideas\">x</a></p>"
        try database.upsert([linking], selfUserId: 1)
        #expect(try lists(database, "plans").linksTo.map(\.topic) == ["ideas"])

        try database.delete(ids: [2])
        #expect(try database.linkCount() == 0)
    }

    @Test func aLinkToADirectMessageIsVoid() throws {
        let (database, directory) = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dm = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.dmMessageJSON(id: 1).utf8))
        try database.upsert([
            dm,
            try message(2, topic: "plans", links: ["/#narrow/channel/10-general/topic/x/near/1"]),
        ], selfUserId: 1)
        #expect(try lists(database, "plans").isEmpty)
    }

    @Test func backfillIndexesEarlierRows() throws {
        let (database, directory) = try tempDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        try database.upsert((1...25).map { id in
            try message(id, topic: "t\(id)", links: id.isMultiple(of: 5)
                ? ["/#narrow/channel/10-general/topic/hub"] : [])
        }, selfUserId: 1)
        try database.resetLinkIndex()
        #expect(try database.linkCount() == 0)

        var batches = 0
        while try database.backfillLinks(batchSize: 10) { batches += 1 }
        #expect(batches == 2)
        #expect(try lists(database, "hub").linkedFrom.map(\.topic) == ["t5", "t10", "t15", "t20", "t25"])
        // Done: further calls do nothing.
        #expect(try database.backfillLinks() == false)
    }
}

/// The store's index: which topics offer View Links, kept current as
/// messages arrive, and the server top-up when the lists open.
@MainActor
struct TopicLinkIndexTests {
    private func makeStore(
        script: [FakeResponse] = []
    ) throws -> (PerAccountStore, FakeTransport, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zephyr-link-index-\(UUID().uuidString)")
        let transport = FakeTransport(script: script, defaultResponse: .hang)
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        let store = PerAccountStore(
            account: account, connection: connection, snapshot: snapshot,
            offline: OfflineStore(directory: directory))
        return (store, transport, directory)
    }

    private func messageJSON(_ id: Int, topic: String, links: [String] = []) -> String {
        let anchors = links.map { "<a href=\"\($0)\">link</a>" }.joined(separator: " ")
        return Fixtures.channelMessageJSON(id: id, topic: topic, content: "<p>\(anchors)</p>")
    }

    @Test func storedHistoryAndNewMessagesOfferViewLinks() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Written before this session (and before the index existed).
        try store.database?.upsert([
            try ZulipJSON.decoder.decode(Message.self, from: Data(messageJSON(
                1, topic: "plans", links: ["/#narrow/channel/10-general/topic/budget"]).utf8)),
        ], selfUserId: 1)
        try store.database?.resetLinkIndex()
        await store.restoreOfflineCache()
        try await eventually("backfilled") {
            store.topicLinks.hasLinks(streamId: 10, topic: "budget")
        }
        #expect(store.topicLinks.hasLinks(streamId: 10, topic: "Plans"))
        #expect(!store.topicLinks.hasLinks(streamId: 10, topic: "ideas"))

        // A new message with a link lands, is written, and counts.
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1,
            message: messageJSON(
                2, topic: "ideas", links: ["/#narrow/channel/10-general/topic/plans/near/1"]),
            flags: ["read"])))
        let lists = await store.topicLinks.lists(streamId: 10, topic: "plans")
        #expect(lists.linksTo.map(\.topic) == ["budget"])
        #expect(lists.linkedFrom.map(\.topic) == ["ideas"])
        try await eventually("new message indexed") {
            store.topicLinks.hasLinks(streamId: 10, topic: "ideas")
        }
    }

    @Test func editsAndMovesReachStoredCopiesNotInMemory() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.database?.upsert([
            try ZulipJSON.decoder.decode(
                Message.self, from: Data(messageJSON(1, topic: "plans").utf8)),
            try ZulipJSON.decoder.decode(
                Message.self, from: Data(messageJSON(2, topic: "budget").utf8)),
        ], selfUserId: 1)
        #expect(store.messages.isEmpty)

        // An edit adds a link to a message only the database holds.
        try store.handleEvent(decodeEvent("""
            {"id": 1, "type": "update_message", "message_id": 1, \
            "rendered_content": "<p><a href=\\"/#narrow/channel/10-general/topic/budget/near/2\\">x</a></p>"}
            """))
        try await eventually("edit indexed") {
            store.topicLinks.hasLinks(streamId: 10, topic: "budget")
        }
        // The linked message is renamed: the link follows it.
        try store.handleEvent(decodeEvent("""
            {"id": 2, "type": "update_message", "message_id": 2, "message_ids": [2], \
            "stream_id": 10, "orig_subject": "budget", "subject": "budget 2027"}
            """))
        try await eventually("move applied") {
            store.topicLinks.hasLinks(streamId: 10, topic: "budget 2027")
        }
        #expect(!store.topicLinks.hasLinks(streamId: 10, topic: "budget"))
        let lists = await store.topicLinks.lists(streamId: 10, topic: "plans")
        #expect(lists.linksTo.map(\.topic) == ["budget 2027"])
    }

    @Test func linksToUnknownChannelsDontCount() async throws {
        let (store, _, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.database?.upsert([
            try ZulipJSON.decoder.decode(Message.self, from: Data(messageJSON(
                1, topic: "plans", links: ["/#narrow/channel/99-secret/topic/budget"]).utf8)),
        ], selfUserId: 1)
        await store.restoreOfflineCache()
        try await eventually("refreshed") { !store.topicLinks.linkedTopics.isEmpty }
        #expect(!store.topicLinks.hasLinks(streamId: 10, topic: "plans"))
        #expect(await store.topicLinks.lists(streamId: 10, topic: "plans").isEmpty)
    }

    @Test func serverFillsInLinkingMessages() async throws {
        // The topic's own linked messages, then the two searches; FIFO
        // order doesn't matter, as each query's reply is the same set.
        let reply = Fixtures.getMessagesJSON([
            messageJSON(30, topic: "retro", links: ["/#narrow/channel/10-general/topic/plans"]),
            messageJSON(31, topic: "plans", links: ["/#narrow/channel/10-general/topic/budget"]),
            messageJSON(32, topic: "other", links: ["https://zulip.com/"]),
        ])
        let (store, transport, directory) = try makeStore(
            script: [.json(reply), .json(reply), .json(reply)])
        defer { try? FileManager.default.removeItem(at: directory) }

        let lists = try #require(
            await store.topicLinks.listsIncludingServer(streamId: 10, topic: "plans"))
        #expect(lists.linkedFrom.map(\.topic) == ["retro"])
        #expect(lists.linksTo.map(\.topic) == ["budget"])
        // Only messages with conversation links were stored.
        #expect(try store.database?.messageCount() == 2)
        let narrows = transport.requests.compactMap { $0.queryValue("narrow") }
        #expect(narrows.count == 3)
        #expect(narrows.contains { $0.contains("\"topic\"") && $0.contains("\"has\"") })
        #expect(narrows.contains { $0.contains("general plans") && !$0.contains("public") })
        #expect(narrows.contains { $0.contains("general plans") && $0.contains("public") })
        // Asked once a while.
        #expect(await store.topicLinks.listsIncludingServer(streamId: 10, topic: "plans") == nil)
    }
}
