import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

private let mentionHTML = #"<p><span class="user-mention" data-user-id="1">@Self</span> Can you review this?</p>"#

private func activityMessage(
    _ id: Int, sender: Int = 2, topic: String = "Home", content: String = "<p>Update</p>"
) throws -> Message {
    try ZulipJSON.decoder.decode(Message.self, from: Data(Fixtures.channelMessageJSON(
        id: id, senderId: sender, topic: topic, content: content,
        timestamp: 1_750_000_000 + id, flags: ["read"]).utf8))
}

private func reaction(_ messageId: Int, op: String = "add", user: Int = 1) throws -> Event {
    try decodeEvent("""
        {"id":99,"type":"reaction","op":"\(op)","message_id":\(messageId),
        "user_id":\(user),"emoji_name":"check","emoji_code":"2705","reaction_type":"unicode_emoji"}
        """)
}

private actor RacingActivityTransport: ApiTransport {
    let underlying: FakeTransport
    var race: (@Sendable () async -> Void)?
    init(underlying: FakeTransport, race: @escaping @Sendable () async -> Void) {
        self.underlying = underlying
        self.race = race
    }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = try await underlying.perform(request)
        if let race {
            self.race = nil
            await race()
        }
        return response
    }
}

@MainActor private final class ActivityStoreHolder { var store: PerAccountStore? }

struct TopicActivityTests {
    @Test func readMentionStaysRedAndUnreadDoesNotHideIt() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        index.upsert(try activityMessage(10, content: mentionHTML))
        let row = try #require(index.activities(since: 0).first)
        #expect(row.unansweredMentionIds == [10])
        #expect(row.indicator(unreadCount: 0) == .awaitingResponse)
        #expect(row.indicator(unreadCount: 4) == .awaitingResponse)
    }

    @Test func readingAloneIsNotParticipation() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        index.upsert(try activityMessage(10))
        let row = try #require(index.activities(since: 0).first)
        #expect(row.indicator(unreadCount: 1) == .unseen)
        #expect(row.indicator(unreadCount: 0) == .seen)
    }

    @Test func replyMustFollowMentionAndNewActivityWinsOverCheck() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        index.upsert(try activityMessage(5, sender: 1))
        index.upsert(try activityMessage(10, content: mentionHTML))
        #expect(index.activities(since: 0).first?.unansweredMentionIds == [10])
        index.upsert(try activityMessage(20, sender: 1))
        let row = try #require(index.activities(since: 0).first)
        #expect(row.unansweredMentionIds.isEmpty)
        #expect(row.indicator(unreadCount: 0) == .participated)
        #expect(row.indicator(unreadCount: 3) == .unseen)
        index.upsert(try activityMessage(30, content: mentionHTML))
        #expect(index.activities(since: 0).first?.unansweredMentionIds == [30])
    }

    @Test func reactionAcknowledgesOnlyItsOwnMention() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        index.upsert(try activityMessage(10, content: mentionHTML))
        index.upsert(try activityMessage(11, content: mentionHTML))
        index.upsert(try activityMessage(12))
        for id in [12, 10] {
            if case .reaction(let event) = try reaction(id).kind { index.applyReaction(event) }
        }
        #expect(index.activities(since: 0).first?.unansweredMentionIds == [11])
        if case .reaction(let event) = try reaction(11).kind { index.applyReaction(event) }
        #expect(index.activities(since: 0).first?.indicator(unreadCount: 0) == .participated)
        if case .reaction(let event) = try reaction(10, op: "remove").kind { index.applyReaction(event) }
        #expect(index.activities(since: 0).first?.unansweredMentionIds == [10])
    }

    @Test func deletedReplyReopensAndDeletedMentionClears() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        index.upsert(try activityMessage(10, content: mentionHTML))
        index.upsert(try activityMessage(20, sender: 1))
        index.remove([20])
        #expect(index.activities(since: 0).first?.unansweredMentionIds == [10])
        index.remove([10])
        #expect(index.activities(since: 0).isEmpty)
    }

    @Test func silentBroadcastGroupQuotedAndSelfMentionsDoNotRequireReply() throws {
        let excluded = [
            #"<p><span class="user-mention silent" data-user-id="1">@Self</span></p>"#,
            #"<p><span class="user-mention" data-user-id="*">@all</span></p>"#,
            #"<p><span class="user-group-mention" data-user-group-id="1">@Team</span></p>"#,
            "<blockquote>\(mentionHTML)</blockquote>",
            #"<p><span class="user-mention" data-user-id="2">@Other</span></p>"#,
        ]
        var index = TopicActivityIndex(selfUserId: 1)
        for (id, html) in excluded.enumerated() { index.upsert(try activityMessage(id, content: html)) }
        index.upsert(try activityMessage(9, sender: 1, content: mentionHTML))
        #expect(index.activities(since: 0).allSatisfy { $0.unansweredMentionIds.isEmpty })
    }

    @Test func editedMentionDoesNotUseEarlierReplyOrOldReaction() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        var message = try activityMessage(10)
        index.upsert(message)
        index.upsert(try activityMessage(20, sender: 1))
        message.content = mentionHTML
        message.lastEditTimestamp = message.timestamp + 30
        message.reactions = [Reaction(emojiName: "check", emojiCode: "2705", reactionType: "unicode_emoji", userId: 1)]
        index.upsert(message)
        #expect(index.activities(since: 0).first?.unansweredMentionIds == [10])
        #expect(index.activities(since: 0).first?.needsReactionReview == true)
        if case .reaction(let event) = try reaction(10).kind { index.applyReaction(event) }
        #expect(index.activities(since: 0).first?.unansweredMentionIds.isEmpty == true)
        message.content = "<p>No longer a request</p>"
        index.upsert(message)
        #expect(index.mentionMessages.isEmpty)
    }

    @Test func liveOrderDistinguishesRepliesFromMentionEditsInSameSecond() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        var message = try activityMessage(10)
        index.upsert(message, live: true)
        let earlierReply = try activityMessage(20, sender: 1)
        index.upsert(earlierReply, live: true)
        message.content = mentionHTML
        message.lastEditTimestamp = earlierReply.timestamp
        index.upsert(message, live: true)
        #expect(index.activities(since: 0).first?.unansweredMentionIds == [10])
        var laterReply = try activityMessage(21, sender: 1)
        laterReply.timestamp = earlierReply.timestamp
        index.upsert(laterReply, live: true)
        #expect(index.activities(since: 0).first?.unansweredMentionIds.isEmpty == true)
    }

    @Test func topicIdentityHandlesCaseEmptyNamesMovesAndMerges() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        var message = try activityMessage(10, topic: "HOME", content: mentionHTML)
        index.upsert(message)
        index.upsert(try activityMessage(20, sender: 1, topic: "Home"))
        #expect(index.activities(since: 0).count == 1)
        #expect(index.activities(since: 0).first?.unansweredMentionIds.isEmpty == true)
        message.subject = "Elsewhere"
        index.upsert(message)
        #expect(index.activities(since: 0).count == 2)
        #expect(index.activities(since: 0).first(where: { $0.topic == "Elsewhere" })?.unansweredMentionIds == [10])
        #expect(TopicActivityID(streamId: 10, topic: "") == TopicActivityID(streamId: 10, topic: TopicName.legacyEmptyName))
    }

    @Test func oldUnansweredMentionSurvivesRecentWindow() throws {
        var index = TopicActivityIndex(selfUserId: 1)
        index.upsert(try activityMessage(10, content: mentionHTML))
        #expect(index.activities(since: 1_800_000_000).count == 1)
        index.upsert(try activityMessage(20, sender: 1))
        #expect(index.activities(since: 1_800_000_000).isEmpty)
    }
}

@MainActor
struct TopicActivityStoreTests {
    private func networkStore(_ script: [FakeResponse], fallback: FakeResponse = .hang) throws -> (PerAccountStore, FakeTransport) {
        let transport = FakeTransport(script: script, defaultResponse: fallback)
        let account = Account(realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q").utf8))
        let connection = ApiConnection(realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        return (PerAccountStore(account: account, connection: connection, snapshot: snapshot), transport)
    }

    private func response(_ messages: [Message], limited: Bool = false) throws -> FakeResponse {
        let json = Fixtures.getMessagesJSON(try messages.map { try ZulipJSON.encodeString($0) })
            .replacingOccurrences(of: "\"found_oldest\": false", with: "\"found_oldest\": true")
            .replacingOccurrences(of: "\"history_limited\": false", with: "\"history_limited\": \(limited)")
        return .json(json)
    }

    private func recent(
        _ id: Int, sender: Int = 2, topic: String = "Home", content: String = "<p>Update</p>"
    ) throws -> Message {
        var message = try activityMessage(id, sender: sender, topic: topic, content: content)
        message.timestamp = Int(Date().timeIntervalSince1970) - 100 + id
        return message
    }

    @Test func refreshFindsReplyBeyondSummarySliceWithoutMarkingAnythingRead() async throws {
        let mention = try recent(10, content: mentionHTML)
        let reply = try recent(20, sender: 1)
        let newest = try recent(40)
        let (store, transport) = try networkStore([
            response([mention, newest]), response([mention]), response([newest]),
            response([reply]), response([mention]),
        ])
        await store.topicActivity.refresh()
        let row = try #require(store.topicActivity.activities.first)
        #expect(row.unansweredMentionIds.isEmpty)
        #expect(row.hasReplied)
        #expect(store.topicActivity.verifiedTopics.contains(row.id))
        #expect(!store.topicActivity.refreshFailed)
        #expect(transport.requests.allSatisfy { $0.method == "GET" })
        #expect(transport.requests.contains { $0.queryValue("narrow")?.contains("sender") == true })
    }

    @Test func refreshRemovesDeletedCachedReplyAndInvalidatesItsSummary() async throws {
        let mention = try recent(10, content: mentionHTML)
        let deletedReply = try recent(20, sender: 1)
        let newest = try recent(40)
        let (store, _) = try networkStore([
            response([mention, newest]), response([mention]), response([mention, newest]), response([]),
        ])
        store.reconcileFetchedMessages([mention, deletedReply, newest])
        store.topicActivity.saveSummary(TopicSummary(topic: TopicActivityID(mention)!, fingerprint: "old", text: "You replied.", sourceIds: [20]), source: [deletedReply])
        await store.topicActivity.refresh()
        let row = try #require(store.topicActivity.activities.first)
        #expect(row.unansweredMentionIds == [10])
        #expect(!row.hasReplied)
        #expect(!row.messages.contains { $0.id == 20 })
        #expect(store.topicActivity.summaries.isEmpty)
    }

    @Test func refreshUsesCrossDeviceReactionEvenWhenCanonicalCopyAlreadyExists() async throws {
        let old = try recent(10, content: mentionHTML)
        var confirmed = old
        confirmed.reactions = [Reaction(emojiName: "check", emojiCode: "2705", reactionType: "unicode_emoji", userId: 1)]
        let newest = try recent(40)
        let (store, _) = try networkStore([
            response([confirmed, newest]), response([confirmed]), response([confirmed, newest]), response([]),
        ])
        store.reconcileFetchedMessages([old])
        await store.topicActivity.refresh()
        let row = try #require(store.topicActivity.activities.first)
        #expect(row.unansweredMentionIds.isEmpty)
        #expect(row.hasReacted)
        #expect(row.indicator(unreadCount: 0) == .participated)
    }

    @Test func limitedHistoryIsNotReportedAsVerified() async throws {
        let mention = try recent(10, content: mentionHTML)
        let (store, _) = try networkStore([
            response([mention]), response([mention]), response([mention]), response([], limited: true),
        ])
        await store.topicActivity.refresh()
        #expect(store.topicActivity.historyIsLimited)
        #expect(store.topicActivity.verifiedTopics.isEmpty)
        #expect(store.topicActivity.activities.first?.unansweredMentionIds == [10])
    }

    @Test func cancelledRefreshStopsLoadingAndCanBeRetried() async throws {
        let (store, _) = try networkStore([])
        let refresh = Task { await store.topicActivity.refresh() }
        await Task.yield()
        refresh.cancel()
        await refresh.value
        #expect(!store.topicActivity.isLoading)
        #expect(!store.topicActivity.refreshFailed)
    }

    @Test func failedPassKeepsItsNoticeUntilAPassSucceeds() async throws {
        let message = try recent(10)
        let (store, transport) = try networkStore([.networkError])
        await store.topicActivity.refresh()
        #expect(store.topicActivity.refreshFailed)

        // Summary retries on its own, and the saved-activity notice has to
        // hold steady through each attempt rather than blink off at its
        // start; neither a running pass nor a cancelled one takes it down.
        let retry = Task { await store.topicActivity.refresh() }
        await Task.yield()
        #expect(store.topicActivity.isLoading)
        #expect(store.topicActivity.refreshFailed)
        retry.cancel()
        await retry.value
        #expect(store.topicActivity.refreshFailed)

        for reply in [try response([message]), try response([]),
                      try response([message]), try response([])] {
            transport.enqueue(reply)
        }
        await store.topicActivity.refresh()
        #expect(!store.topicActivity.refreshFailed)
        #expect(store.topicActivity.activities.count == 1)
    }

    @Test func oldMentionChecksHaveABoundedRequestBudget() async throws {
        let mentions = try (1...61).map { try recent($0, content: mentionHTML) }
        let newest = try recent(90)
        let (store, transport) = try networkStore([
            response(mentions + [newest]), response(mentions), response([newest]), response([]),
        ], fallback: response([]))
        await store.topicActivity.refresh()
        #expect(transport.requests.count == 64)
        #expect(store.topicActivity.historyIsLimited)
        #expect(store.topicActivity.verifiedTopics.isEmpty)
        #expect(store.topicActivity.activities.first?.unansweredMentionIds == [61])
    }

    @Test func staleFetchCannotResurrectMessageDeletedWhileRequestWasRunning() async throws {
        let mention = try recent(10, content: mentionHTML)
        let holder = ActivityStoreHolder()
        let backing = FakeTransport(script: [try response([mention]), try response([])], defaultResponse: .hang)
        let deletion = try decodeEvent(#"{"id":1,"type":"delete_message","message_ids":[10]}"#)
        let transport = RacingActivityTransport(underlying: backing) {
            await MainActor.run { holder.store?.handleEvent(deletion) }
        }
        let account = Account(realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q").utf8))
        let connection = ApiConnection(realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)
        holder.store = store
        store.reconcileFetchedMessages([mention])
        await store.topicActivity.refresh()
        #expect(store.messages[10] == nil)
        #expect(store.topicActivity.activities.isEmpty)
    }

    @Test func readFlagsDoNotResolveMentionAndOptimisticReactionsWaitForEvent() throws {
        let store = try makeStore()
        let message = try activityMessage(10, content: mentionHTML)
        store.reconcileFetchedMessages([message])
        store.topicActivity.rebuild(now: Date(timeIntervalSince1970: 1_750_000_100))
        store.markMessagesRead(ids: [10])
        #expect(store.topicActivity.activities.first?.unansweredMentionIds == [10])
        store.toggleReaction(message: message, emojiName: "check", emojiCode: "2705", reactionType: "unicode_emoji")
        store.topicActivity.rebuild(now: Date(timeIntervalSince1970: 1_750_000_100))
        #expect(store.topicActivity.activities.first?.unansweredMentionIds == [10])
        store.handleEvent(try reaction(10))
        store.topicActivity.rebuild(now: Date(timeIntervalSince1970: 1_750_000_100))
        #expect(store.topicActivity.activities.first?.unansweredMentionIds.isEmpty == true)
    }

    @Test func summaryIsInvalidatedOnDeleteAndLateGenerationCannotRestoreIt() throws {
        let store = try makeStore()
        let message = try activityMessage(10, content: mentionHTML)
        store.reconcileFetchedMessages([message])
        let summary = TopicSummary(topic: TopicActivityID(message)!, fingerprint: "test", text: "A review was requested.", sourceIds: [10])
        store.topicActivity.saveSummary(summary, source: [message])
        #expect(store.topicActivity.summaries.count == 1)
        store.handleEvent(try decodeEvent(#"{"id":3,"type":"delete_message","message_ids":[10]}"#))
        #expect(store.topicActivity.summaries.isEmpty)
        store.topicActivity.saveSummary(summary, source: [message])
        #expect(store.topicActivity.summaries.isEmpty)
    }

    @Test func pendingRequestsPersistAndAccountCachesAreIsolated() throws {
        let first = OfflineStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let second = OfflineStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer {
            try? FileManager.default.removeItem(at: first.directory)
            try? FileManager.default.removeItem(at: second.directory)
        }
        let activity = TopicActivityStore(selfUserId: 1, offline: first)
        activity.seedMissing([try activityMessage(10, content: mentionHTML)])
        activity.rebuild()
        let restored = TopicActivityStore(selfUserId: 1, offline: first)
        restored.rebuild()
        #expect(restored.activities.first?.unansweredMentionIds == [10])
        let other = TopicActivityStore(selfUserId: 1, offline: second)
        other.rebuild()
        #expect(other.activities.isEmpty)
    }

    @Test func unchangedPendingRequestsAreNotRewrittenOnEveryRebuild() throws {
        let offline = OfflineStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let file = offline.directory.appendingPathComponent("home-mentions.json")
        let activity = TopicActivityStore(selfUserId: 1, offline: offline)
        activity.seedMissing([try activityMessage(10, content: mentionHTML)])
        activity.rebuild()
        #expect(FileManager.default.fileExists(atPath: file.path))
        // A rebuild follows any channel event within 60ms; ordinary traffic
        // that leaves the pending set alone must not write the same records
        // again. The removed file reappearing would mean it did.
        try FileManager.default.removeItem(at: file)
        activity.seedMissing([try activityMessage(11)])
        activity.rebuild()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Answering the request does change the set, so that is written.
        activity.seedMissing([try activityMessage(20, sender: 1)])
        activity.rebuild()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(TopicActivityStore(selfUserId: 1, offline: offline).activities.isEmpty)
    }

    @Test func rowsBeyondTheRefreshLimitAreVerifiedOnceDisplayed() async throws {
        let all = [try recent(10), try recent(20, topic: "Other")]
        let (store, transport) = try networkStore([], fallback: try response(all))
        await store.topicActivity.refresh(limit: 1)
        let shown = store.topicActivity.activities.map(\.id)
        #expect(shown.count == 2)
        // Only the first row is covered by the refresh itself; a sidebar
        // filter can put the other one on screen.
        #expect(store.topicActivity.verifiedTopics == [shown[0]])
        await store.topicActivity.verifyVisible(Set(shown))
        #expect(store.topicActivity.verifiedTopics == Set(shown))
        // An already-verified row is not fetched again.
        let settled = transport.requests.count
        await store.topicActivity.verifyVisible(Set(shown))
        #expect(transport.requests.count == settled)
    }
}
