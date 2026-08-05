import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

/// Timing probes for the launch/open hot paths — not correctness tests.
/// Run `swift test -c release --filter LoadBenchmarks` for honest numbers
/// (debug timings are several times inflated). Sizes model a large public
/// realm (chat.zulip.org scale).
@MainActor
@Suite(.serialized)
struct LoadBenchmarks {
    private let clock = ContinuousClock()

    private func report(_ label: String, _ duration: Duration) {
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        print(String(format: "[bench] %@: %.1f ms", label, ms))
    }

    // MARK: Synthetic big-realm register payload

    private func bigRegisterJSON(
        users: Int, channels: Int, unreadTopics: Int, unreadsPerTopic: Int, recentDms: Int
    ) -> String {
        let userRows = (1...users).map {
            """
            {"user_id": \($0), "email": "user\($0)@example.com", \
            "full_name": "User Number \($0)", "is_bot": false, "is_active": true, \
            "avatar_url": "https://example.com/avatar/\($0).png"}
            """
        }.joined(separator: ",")
        let streamRows = (1...channels).map {
            """
            {"stream_id": \($0), "name": "channel-\($0)", \
            "description": "The description of channel number \($0)", "invite_only": false}
            """
        }.joined(separator: ",")
        let subRows = (1...channels).map {
            """
            {"stream_id": \($0), "name": "channel-\($0)", \
            "description": "The description of channel number \($0)", \
            "color": "#76ce90", "is_muted": false}
            """
        }.joined(separator: ",")
        var nextId = 1_000_000
        let unreadStreamRows = (1...unreadTopics).map { topic -> String in
            let ids = (0..<unreadsPerTopic).map { _ -> String in
                nextId += 1
                return String(nextId)
            }.joined(separator: ",")
            return """
            {"stream_id": \(topic % channels + 1), "topic": "topic \(topic)", \
            "unread_message_ids": [\(ids)]}
            """
        }.joined(separator: ",")
        let dmRows = (2...(recentDms + 1)).map {
            """
            {"other_user_id": \($0), "unread_message_ids": [\(2_000_000 + $0)]}
            """
        }.joined(separator: ",")
        let recentDmRows = (2...(recentDms + 1)).map {
            """
            {"max_message_id": \(2_000_000 + $0), "user_ids": [\($0)]}
            """
        }.joined(separator: ",")
        let unreads = """
            {"count": \(unreadTopics * unreadsPerTopic + recentDms),
             "pms": [\(dmRows)], "streams": [\(unreadStreamRows)],
             "huddles": [], "mentions": [], "old_unreads_missing": false}
            """
        return """
            {"result": "success", "msg": "",
             "queue_id": "bench", "last_event_id": -1,
             "zulip_version": "12.0", "zulip_feature_level": 400,
             "event_queue_longpoll_timeout_seconds": 90,
             "realm_name": "Bench Realm", "max_message_length": 10000,
             "recent_private_conversations": [\(recentDmRows)],
             "realm_users": [\(userRows)],
             "streams": [\(streamRows)],
             "subscriptions": [\(subRows)],
             "unread_msgs": \(unreads)}
            """
    }

    /// Register-payload decode + store construction — the warm-launch
    /// (cached snapshot) and post-register main-thread work.
    @Test func snapshotDecodeAndStoreBuild() throws {
        let json = bigRegisterJSON(
            users: 60_000, channels: 600,
            unreadTopics: 600, unreadsPerTopic: 25, recentDms: 300)
        let data = Data(json.utf8)
        print("[bench] register payload size: \(data.count / 1024) KB")

        var snapshot: InitialSnapshot?
        let decodeTime = try clock.measure {
            snapshot = try ZulipJSON.decoder.decode(InitialSnapshot.self, from: data)
        }
        report("snapshot decode (60k users)", decodeTime)

        let account = Account(
            realmURL: URL(string: "https://bench.example")!,
            email: "self@example.com", userId: 1)
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: FakeTransport(script: [], defaultResponse: .hang))
        var store: PerAccountStore?
        let buildTime = clock.measure {
            store = PerAccountStore(account: account, connection: connection, snapshot: snapshot!)
        }
        report("PerAccountStore build", buildTime)
        #expect(store!.users.count == 60_000)
    }

    /// The cold-launch SQLite restore: newest 50 messages of every cached
    /// conversation, decoded from payload blobs.
    @Test func databaseRestore() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try MessageDatabase(path: path)

        // 200 conversations x 60 messages, interleaved ids.
        var messages: [Message] = []
        for id in 0..<12_000 {
            let topic = "topic-\(id % 200)"
            let json = Fixtures.channelMessageJSON(
                id: 100_000 + id, streamId: id % 40 + 1, topic: topic,
                content: "<p>Benchmark message body \(id) with some plausible text.</p>",
                flags: ["read"])
            messages.append(
                try ZulipJSON.decoder.decode(Message.self, from: Data(json.utf8)))
        }

        let upsertTime = try clock.measure {
            try database.upsert(messages, selfUserId: 1)
        }
        report("db upsert 12k messages", upsertTime)

        var restored: [Message] = []
        let restoreTime = try clock.measure {
            restored = try database.recentPerConversation(50)
        }
        report("db restore (recentPerConversation 50)", restoreTime)
        #expect(restored.count == 200 * 50)
    }

    /// The feed's items-array assembly (day grouping) over a full 600-message
    /// window — recomputed on every SwiftUI body evaluation of the feed.
    @Test func feedGrouping() throws {
        var messages: [Message] = []
        for id in 0..<600 {
            let json = Fixtures.channelMessageJSON(
                id: 100_000 + id, topic: "topic-\(id % 20)",
                timestamp: 1_750_000_000 + id * 3600, flags: ["read"])
            messages.append(
                try ZulipJSON.decoder.decode(Message.self, from: Data(json.utf8)))
        }
        var count = 0
        let groupTime = clock.measure {
            for _ in 0..<100 {
                var lastDay: DateComponents?
                var lastSender: Int?
                var lastTimestamp = 0
                for message in messages {
                    let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                    let day = Calendar.current.dateComponents(
                        [.year, .month, .day], from: date)
                    if day != lastDay {
                        lastDay = day
                        lastSender = nil
                        count += 1
                    }
                    let showHeader = message.senderId != lastSender
                        || message.timestamp - lastTimestamp > 300
                    if showHeader { count += 1 }
                    lastSender = message.senderId
                    lastTimestamp = message.timestamp
                }
            }
        }
        report("feed grouping, 600 msgs x 100 passes", groupTime)
        #expect(count > 0)
    }
}
