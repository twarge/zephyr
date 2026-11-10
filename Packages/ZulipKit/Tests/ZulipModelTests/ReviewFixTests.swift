import Foundation
import Synchronization
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

/// A transport that parks every request until the test answers it, in
/// arrival order — for asserting what's in flight at a given moment.
final class GatedTransport: ApiTransport {
    /// Records requests (RecordedRequest has no public initializer).
    private let recorder = FakeTransport(defaultResponse: .json("{}"))
    private let parked = Mutex<[CheckedContinuation<FakeResponse, Never>]>([])

    var requests: [RecordedRequest] { recorder.requests }
    var parkedCount: Int { parked.withLock { $0.count } }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = await withCheckedContinuation { continuation in
            parked.withLock { $0.append(continuation) }
            // Recorded after parking, so a recorded request is answerable.
            Task { _ = try? await self.recorder.perform(request) }
        }
        switch response {
        case .json(let body, let status):
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        case .timeout:
            throw URLError(.timedOut)
        default:
            throw URLError(.notConnectedToInternet)
        }
    }

    /// Answers the oldest parked request.
    func answerNext(_ response: FakeResponse) {
        let next = parked.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        next?.resume(returning: response)
    }
}

@MainActor
private func makeStore(
    transport: any ApiTransport, offline: OfflineStore? = nil,
    unreads: String = Fixtures.emptyUnreadsJSON, queueId: String = "q1"
) throws -> PerAccountStore {
    let account = Account(
        realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
    let snapshot = try ZulipJSON.decoder.decode(
        InitialSnapshot.self,
        from: Data(Fixtures.registerJSON(queueId: queueId, unreadMsgs: unreads).utf8))
    let connection = ApiConnection(
        realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
    return PerAccountStore(
        account: account, connection: connection, snapshot: snapshot, offline: offline)
}

private func tempOffline() -> OfflineStore {
    OfflineStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("zephyr-review-tests-\(UUID().uuidString)"))
}

private func unreadsJSON(topic: String = "greetings", ids: [Int]) -> String {
    """
    {"count": \(ids.count), "pms": [], "huddles": [], "mentions": [],
     "streams": [{"stream_id": 10, "topic": "\(topic)",
                  "unread_message_ids": [\(ids.map(String.init).joined(separator: ","))]}],
     "old_unreads_missing": false}
    """
}

private func moveEventJSON(
    eventId: Int, ids: [Int], from: String = "greetings", to: String?, newStreamId: Int? = nil,
    mode: String = "change_all"
) -> String {
    let subject = to.map { #", "subject": "\#($0)""# } ?? ""
    let stream = newStreamId.map { #", "new_stream_id": \#($0)"# } ?? ""
    return """
        {"id": \(eventId), "type": "update_message", "user_id": 2, "rendering_only": false,
         "message_id": \(ids.max()!), "message_ids": [\(ids.map(String.init).joined(separator: ","))],
         "flags": [], "edit_timestamp": 1750000100, "stream_id": 10,
         "orig_subject": "\(from)"\(subject)\(stream), "propagate_mode": "\(mode)"}
        """
}

@MainActor
struct MoveBookkeepingTests {
    @Test func topicRenameRekeysUnreadsAndSidebarForUnloadedIds() throws {
        let store = try makeStore(
            transport: FakeTransport(defaultResponse: .hang),
            unreads: unreadsJSON(ids: [100, 101]))
        let old = ConversationKey.topic(streamId: 10, topic: "greetings")
        let new = ConversationKey.topic(streamId: 10, topic: "renamed")
        #expect(store.conversations.conversations.contains { $0.key == old })

        // Neither message is loaded: the event's id list alone drives it.
        try store.handleEvent(decodeEvent(moveEventJSON(eventId: 1, ids: [100, 101], to: "renamed")))
        #expect(store.unreads.unreadIds[old] == nil)
        #expect(store.unreads.unreadIds[new] == [100, 101])
        #expect(store.unreads.unreadCount(inChannel: 10) == 2)
        // No ghost row for the old topic; the new one carries the recency.
        #expect(!store.conversations.conversations.contains { $0.key == old })
        #expect(store.conversations.conversations.first { $0.key == new }?.lastMessageId == 101)
    }

    @Test func partialMoveLeavesSourceAtItsNewestRemainingMessage() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        for id in [100, 101] {
            try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
                eventId: id, message: Fixtures.channelMessageJSON(id: id))))
        }
        try store.handleEvent(decodeEvent(
            moveEventJSON(eventId: 5, ids: [101], to: "split", mode: "change_one")))
        let old = ConversationKey.topic(streamId: 10, topic: "greetings")
        let new = ConversationKey.topic(streamId: 10, topic: "split")
        #expect(store.unreads.unreadIds[old] == [100])
        #expect(store.unreads.unreadIds[new] == [101])
        #expect(store.conversations.conversations.first { $0.key == old }?.lastMessageId == 100)
        #expect(store.conversations.conversations.first { $0.key == new }?.lastMessageId == 101)
        #expect(store.messages[101]?.subject == "split")
    }

    @Test func channelMoveKeepsTopicNameAndRekeys() throws {
        let store = try makeStore(
            transport: FakeTransport(defaultResponse: .hang), unreads: unreadsJSON(ids: [100]))
        try store.handleEvent(decodeEvent(
            moveEventJSON(eventId: 1, ids: [100], to: nil, newStreamId: 11)))
        #expect(store.unreads.unreadIds[.topic(streamId: 11, topic: "greetings")] == [100])
        #expect(store.unreads.unreadCount(inChannel: 10) == 0)
    }

    @Test func messagesMovedIntoAnOpenTopicAppear() async throws {
        let transport = FakeTransport(
            script: [.json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 50, topic: "renamed", flags: ["read"]),
                Fixtures.channelMessageJSON(id: 200, topic: "renamed", flags: ["read"]),
            ]))],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 100), flags: ["read"])))
        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "renamed"))
        await list.fetchInitial()
        #expect(list.messages.map(\.id) == [50, 200])

        try store.handleEvent(decodeEvent(moveEventJSON(eventId: 2, ids: [100], to: "renamed")))
        #expect(list.messages.map(\.id) == [50, 100, 200])
    }

    @Test func unloadedMovedIntoAnOpenTopicRefetchesTheWindow() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.getMessagesJSON([
                    Fixtures.channelMessageJSON(id: 50, topic: "renamed", flags: ["read"]),
                ])),
                .json(Fixtures.getMessagesJSON([
                    Fixtures.channelMessageJSON(id: 50, topic: "renamed", flags: ["read"]),
                    Fixtures.channelMessageJSON(id: 120, topic: "renamed", flags: ["read"]),
                ])),
            ],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "renamed"))
        await list.fetchInitial()
        try store.handleEvent(decodeEvent(moveEventJSON(eventId: 2, ids: [120], to: "renamed")))
        try await eventually("refetched span shows the moved message") {
            list.messages.map(\.id) == [50, 120]
        }
    }
}

@MainActor
struct FlagEventTests {
    @Test func markUnreadFilesUnloadedMessagesFromDetails() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        try store.handleEvent(decodeEvent("""
            {"id": 1, "type": "update_message_flags", "op": "remove", "flag": "read",
             "messages": [300, 301], "all": false,
             "message_details": {
                "300": {"type": "stream", "stream_id": 10, "topic": "old news", "mentioned": true},
                "301": {"type": "private", "user_ids": [2]}}}
            """))
        #expect(store.unreads.unreadIds[.topic(streamId: 10, topic: "old news")] == [300])
        #expect(store.unreads.unreadIds[.dm("2")] == [301])
        #expect(store.unreads.mentionIds == [300])
    }

    @Test func markUnreadRestoresMentionsOfLoadedMessages() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 100),
            flags: ["read", "mentioned"])))
        #expect(store.unreads.mentionIds.isEmpty)
        try store.handleEvent(decodeEvent(Fixtures.flagsEventJSON(
            eventId: 2, op: "remove", flag: "read", messages: [100])))
        #expect(store.unreads.mentionIds == [100])
        #expect(store.unreads.totalCount == 1)
    }

    @Test func flagsForUnloadedMessagesReachTheDatabase() async throws {
        let offline = tempOffline()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang), offline: offline)
        let database = try #require(store.database)
        let stored = try ZulipJSON.decoder.decode(
            Message.self, from: Data(Fixtures.channelMessageJSON(id: 300, flags: []).utf8))
        try database.upsert([stored], selfUserId: 1)

        try store.handleEvent(decodeEvent(Fixtures.flagsEventJSON(
            eventId: 1, op: "add", flag: "starred", messages: [300])))
        try store.handleEvent(decodeEvent(Fixtures.flagsEventJSON(
            eventId: 2, op: "add", flag: "read", messages: [300])))
        await database.waitForWrites()
        let row = try #require(
            try database.older(than: .max, matching: .combined, limit: 10).first { $0.id == 300 })
        #expect(Set(row.flags ?? []) == ["starred", "read"])
    }

    @Test func conversationMarkReadFlipsLoadedCopies() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 100))))
        store.markConversationRead(.topic(streamId: 10, topic: "greetings"))
        #expect(store.messages[100]?.flags?.contains("read") == true)
        #expect(store.unreads.totalCount == 0)

        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 2, message: Fixtures.channelMessageJSON(id: 101))))
        store.markChannelRead(10)
        #expect(store.messages[101]?.flags?.contains("read") == true)
    }

    @Test func deleteAfterPendingUpsertDoesNotResurrect() async throws {
        let offline = tempOffline()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang), offline: offline)
        let database = try #require(store.database)
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 100))))
        store.persistMessageCache()  // Upsert enqueued…
        try store.handleEvent(decodeEvent(
            #"{"id": 2, "type": "delete_message", "message_ids": [100], "message_type": "stream"}"#))
        await database.waitForWrites()  // …then the delete, in order.
        #expect(try database.messageCount() == 0)
    }
}

@MainActor
struct EventDecodingFixTests {
    @Test func renderingOnlyUpdateIsNotAnEdit() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 100))))
        try store.handleEvent(decodeEvent("""
            {"id": 2, "type": "update_message", "user_id": null, "rendering_only": true,
             "message_id": 100, "message_ids": [100], "flags": [], "edit_timestamp": 1750000200,
             "rendered_content": "<p>hello</p><div class=\\"message_embed\\"></div>"}
            """))
        #expect(store.messages[100]?.content.contains("message_embed") == true)
        #expect(store.messages[100]?.lastEditTimestamp == nil)

        try store.handleEvent(decodeEvent("""
            {"id": 3, "type": "update_message", "user_id": 2, "rendering_only": false,
             "message_id": 100, "message_ids": [100], "flags": [], "edit_timestamp": 1750000300,
             "rendered_content": "<p>edited</p>"}
            """))
        #expect(store.messages[100]?.lastEditTimestamp == 1750000300)
    }

    @Test func realmEmojiEventsUpdateTheMap() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        try store.handleEvent(decodeEvent("""
            {"id": 1, "type": "realm_emoji", "op": "add",
             "emoji": {"id": "7", "name": "party_parrot", "source_url": "/e/7.gif",
                       "still_url": null, "deactivated": false, "author_id": 2}}
            """))
        #expect(store.realmEmoji["7"]?.name == "party_parrot")
        try store.handleEvent(decodeEvent(
            #"{"id": 2, "type": "realm_emoji", "op": "update_one", "emoji_id": "7", "data": {"deactivated": true}}"#))
        #expect(store.realmEmoji["7"]?.deactivated == true)
        try store.handleEvent(decodeEvent("""
            {"id": 3, "type": "realm_emoji", "op": "update", "realm_emoji": {
                "8": {"id": "8", "name": "ship", "source_url": "/e/8.png", "deactivated": false}}}
            """))
        #expect(Set(store.realmEmoji.keys) == ["8"])
    }

    @Test func channelFolderEventsMaintainTheSidebarGroups() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        for (id, name, order) in [(1, "Eng", 0), (2, "Ops", 1)] {
            try store.handleEvent(decodeEvent("""
                {"id": \(id), "type": "channel_folder", "op": "add",
                 "channel_folder": {"id": \(id), "name": "\(name)", "order": \(order),
                    "description": "", "rendered_description": "", "is_archived": false,
                    "date_created": null, "creator_id": null}}
                """))
        }
        #expect(store.channelFolders.map(\.name) == ["Eng", "Ops"])
        try store.handleEvent(decodeEvent(
            #"{"id": 3, "type": "channel_folder", "op": "reorder", "order": [2, 1]}"#))
        #expect(store.channelFolders.map(\.id) == [2, 1])
        try store.handleEvent(decodeEvent(
            #"{"id": 4, "type": "channel_folder", "op": "update", "channel_folder_id": 1, "data": {"name": "Engineering"}}"#))
        #expect(store.channelFolders.last?.name == "Engineering")
        try store.handleEvent(decodeEvent(
            #"{"id": 5, "type": "channel_folder", "op": "update", "channel_folder_id": 2, "data": {"is_archived": true}}"#))
        #expect(store.channelFolders.map(\.id) == [1])
        try store.handleEvent(decodeEvent(
            #"{"id": 6, "type": "stream", "op": "update", "stream_id": 10, "name": "general", "property": "folder_id", "value": 1}"#))
        #expect(store.channels[10]?.folderId == 1)
        try store.handleEvent(decodeEvent(
            #"{"id": 7, "type": "stream", "op": "update", "stream_id": 10, "name": "general", "property": "folder_id", "value": null}"#))
        #expect(store.channels[10]?.folderId == nil)
    }
}

@MainActor
struct OfflineQueueFixTests {
    @Test func transientActionFailureRetriesWhileThePollIsHealthy() async throws {
        let transport = FakeTransport(
            script: [.networkError, .json(#"{"result": "success", "msg": ""}"#)],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        store.setStarred(true, messageId: 100)
        try await eventually("queued") { store.pendingActions.count == 1 }
        // No flushPending: the store's own retry replays it.
        try await eventually("replayed by the retry") {
            store.pendingActions.isEmpty && transport.requests.count == 2
        }
    }

    @Test func transientSendFailureRetriesWhileThePollIsHealthy() async throws {
        let transport = FakeTransport(
            script: [.networkError, .json(#"{"result": "success", "id": 900}"#)],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        store.send("hi", to: .dm(userIds: [2]))
        try await eventually("resent by the retry") {
            transport.requests.count == 2 && store.outbox.first?.state == .sending
        }
    }

    @Test func actionsRunOneAtATimeInOrder() async throws {
        let transport = GatedTransport()
        let store = try makeStore(transport: transport)
        store.setStarred(true, messageId: 100)
        store.setStarred(false, messageId: 100)
        try await eventually("first in flight") { transport.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(transport.requests.count == 1)  // The unstar waits its turn.
        transport.answerNext(.json(#"{"result": "success", "msg": ""}"#))
        try await eventually("second follows") { transport.requests.count == 2 }
        #expect(transport.requests[0].formValue("op") == "add")
        #expect(transport.requests[1].formValue("op") == "remove")
        transport.answerNext(.json(#"{"result": "success", "msg": ""}"#))
    }

    @Test func handoverCarriesInFlightSendsWithoutResending() async throws {
        let offline = tempOffline()
        defer { try? FileManager.default.removeItem(at: offline.directory) }
        let transport = GatedTransport()
        // Queued from an earlier session (a live failure would also arm
        // the retry timer, racing the test).
        offline.saveOutbox([OutboxMessage(
            id: "queued-local", destination: .dm(userIds: [2]), content: "queued one",
            timestamp: 1750000000, state: .queued)])
        let old = try makeStore(transport: transport, offline: offline)
        #expect(old.outbox.first?.state == .queued)
        old.send("in flight", to: .dm(userIds: [2]))
        try await eventually("send out") { transport.parkedCount == 1 }

        // The rebuild's replacement loads the same files…
        let new = try makeStore(transport: transport, offline: offline, queueId: "q2")
        new.adoptPendingWork(from: old)
        #expect(old.isRetired)
        // …but takes the in-memory states: in flight is not "failed".
        #expect(new.outbox.map(\.state) == [.queued, .sending])

        // The retired store neither flushes nor retries.
        old.flushPending()
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.requests.count == 1)

        // The old send lands: its echo died with the old queue, so the
        // entry clears in the new store.
        transport.answerNext(.json(#"{"result": "success", "id": 900}"#))
        try await eventually("accepted send cleared") { new.outbox.count == 1 }

        // Only the queued entry resends, on the new queue.
        new.flushPending()
        try await eventually("resent once") { transport.requests.count == 2 }
        #expect(transport.requests[1].formValue("content") == "queued one")
        #expect(transport.requests[1].formValue("queue_id") == "q2")
        #expect(offline.loadOutbox().map(\.content) == ["queued one"])
        transport.answerNext(.json(#"{"result": "success", "id": 901}"#))
    }

    @Test func retiredStoreForwardsLateActionFailures() async throws {
        let transport = GatedTransport()
        let old = try makeStore(transport: transport)
        old.setStarred(true, messageId: 100)
        try await eventually("in flight") { transport.parkedCount == 1 }
        let new = try makeStore(transport: transport, queueId: "q2")
        new.adoptPendingWork(from: old)
        transport.answerNext(.networkError)
        try await eventually("backlog moved to the successor") { new.pendingActions.count == 1 }
        #expect(old.pendingActions.isEmpty)
    }
}

@MainActor
struct ActionFailureTests {
    @Test func refusedMuteRollsBackAndSurfaces() async throws {
        let transport = FakeTransport(
            script: [.json(Fixtures.errorJSON(code: "BAD_REQUEST", msg: "nope"), status: 400)],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        store.setChannelMuted(10, muted: true)
        #expect(store.subscriptions[10]?.muted == true)
        try await eventually("rolled back") { store.subscriptions[10]?.muted == false }
        let failure = try #require(store.lastActionFailure)
        #expect(failure.message.contains("#general"))
        store.clearActionFailure()
        #expect(store.lastActionFailure == nil)
    }

    @Test func refusedTopicFollowRollsBack() async throws {
        let transport = FakeTransport(
            script: [.json(Fixtures.errorJSON(code: "BAD_REQUEST"), status: 400)],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        store.setTopicVisibility(streamId: 10, topic: "greetings", policy: .followed)
        #expect(store.topicVisibility(streamId: 10, topic: "greetings") == .followed)
        try await eventually("rolled back") {
            store.topicVisibility(streamId: 10, topic: "greetings") == .none
                && store.lastActionFailure != nil
        }
    }

    @Test func refusedRenameRestoresTheName() async throws {
        let transport = FakeTransport(
            script: [.json(Fixtures.errorJSON(code: "BAD_REQUEST"), status: 400)],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        store.renameChannel(10, to: "town square")
        #expect(store.channels[10]?.name == "town square")
        try await eventually("restored") { store.channels[10]?.name == "general" }
        #expect(store.subscriptions[10]?.name == "general")
    }
}

@MainActor
struct MemoryBoundTests {
    @Test func evictionKeepsListsUnreadsAndDropsTheOldest() async throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        let messages = try (1...50).map { id in
            try ZulipJSON.decoder.decode(
                Message.self,
                from: Data(Fixtures.channelMessageJSON(
                    id: id, topic: id <= 10 ? "kept" : "other", flags: ["read"]).utf8))
        }
        store.reconcileFetchedMessages(messages)
        // An unread old message, and an open list over the oldest topic.
        try store.handleEvent(decodeEvent(Fixtures.flagsEventJSON(
            eventId: 1, op: "remove", flag: "read", messages: [12])))
        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "kept"))
        list.showCachedPreview()
        #expect(list.messages.count == 10)

        store.evictMessages(downTo: 20)
        #expect(store.messages.count == 20)
        #expect((1...10).allSatisfy { store.messages[$0] != nil })
        #expect(store.messages[12] != nil)
        #expect(store.messages[50] != nil)
        #expect(store.messages[11] == nil)
        _ = list
    }
}

@MainActor
struct RebuildLifecycleTests {
    private func makeGlobalStore(transport: FakeTransport) throws -> (GlobalStore, Account) {
        let global = try GlobalStore(
            accountsStore: InMemoryAccountsStore(),
            credentials: InMemoryCredentialStore(),
            transport: transport, enablePresencePings: false, persistsToDisk: false,
            sleep: { _ in })
        let account = try global.addAccount(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", userId: 1)
        return (global, account)
    }

    @Test func rejectedCredentialsStopPollingAndAskForSignIn() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.registerJSON(queueId: "q1")),
                .json(Fixtures.errorJSON(code: "UNAUTHORIZED", msg: "Invalid API key"), status: 401),
            ],
            defaultResponse: .json(Fixtures.errorJSON(code: "UNAUTHORIZED"), status: 401))
        let (global, account) = try makeGlobalStore(transport: transport)
        let store = try await global.perAccountStore(for: account.id)
        try await eventually("signed out") {
            store.needsReauthentication
                && global.accountsNeedingReauthentication.contains(account.id)
        }
        let count = transport.requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(transport.requests.count == count)  // No retry loop.
        #expect(!store.isRecoveringEventStream)
        await global.shutdown(deleteQueues: false)
    }

    @Test func rebuildStopsOnRejectedCredentials() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.registerJSON(queueId: "q1")),
                .json(Fixtures.errorJSON(code: "BAD_EVENT_QUEUE_ID"), status: 400),
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.errorJSON(code: "UNAUTHORIZED"), status: 401),
            ],
            defaultResponse: .hang)
        let (global, account) = try makeGlobalStore(transport: transport)
        _ = try await global.perAccountStore(for: account.id)
        try await eventually("stopped, signed out") {
            global.accountsNeedingReauthentication.contains(account.id)
        }
        #expect(transport.requests.count == 5)
        await global.shutdown(deleteQueues: false)
    }

    @Test func disablingDuringRebuildDoesNotReviveTheAccount() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.registerJSON(queueId: "q1")),
                .json(Fixtures.errorJSON(code: "BAD_EVENT_QUEUE_ID"), status: 400),
                .json(Fixtures.serverSettingsJSON()),
                // The re-register answers only after the disable.
            ],
            defaultResponse: .hang)
        let (global, account) = try makeGlobalStore(transport: transport)
        _ = try await global.perAccountStore(for: account.id)
        try await eventually("re-register in flight") { transport.requests.count == 5 }
        global.setAccountEnabled(account.id, enabled: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(global.stores[account.id] == nil)
        // No register after the cancelled one (the disable's queue delete
        // is the only later request).
        #expect(transport.requests.count(where: { $0.path == "/api/v1/register" }) == 2)
        #expect(transport.requests.count <= 6)
    }
}

@MainActor
struct MessagesVersionTests {
    @Test func versionBumpsOnRowChanges() async throws {
        let transport = FakeTransport(
            script: [.json(Fixtures.getMessagesJSON([
                Fixtures.channelMessageJSON(id: 100, flags: []),
            ]))],
            defaultResponse: .hang)
        let store = try makeStore(transport: transport)
        let list = MessageListModel(store: store, narrow: .topic(streamId: 10, topic: "greetings"))
        await list.fetchInitial()
        let fetched = list.messagesVersion
        store.setStarred(true, messageId: 100)
        #expect(list.messagesVersion > fetched)
        let starred = list.messagesVersion
        try store.handleEvent(decodeEvent(Fixtures.messageEventJSON(
            eventId: 1, message: Fixtures.channelMessageJSON(id: 101))))
        #expect(list.messagesVersion > starred)
    }
}
