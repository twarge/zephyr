import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

/// Timing probes for View Links over a large stored history — what decided
/// on an index maintained at write time over scanning on demand. Off by
/// default: `ZEPHYR_BENCH=1 swift test -c release --filter TopicLinkBenchmarks`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ZEPHYR_BENCH"] != nil))
struct TopicLinkBenchmarks {
    private let clock = ContinuousClock()
    private static let messageCount = 200_000
    private static let topics = 2_000
    private static let channels = 40

    private func report(_ label: String, _ duration: Duration) {
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        print(String(format: "[bench] %@: %.1f ms", label, ms))
    }

    /// ~600 bytes of body per message; one in 30 links to another topic
    /// (alternating message links and anchored topic links).
    private func messages(_ range: Range<Int>) throws -> [Message] {
        let filler = String(
            repeating: "Some plausible message text, a sentence or two long. ", count: 10)
        return try range.map { index in
            let topic = index % Self.topics
            var content = "<p>\(filler) \(index)</p>"
            if index % 30 == 0 {
                let target = (index * 7 + 13) % Self.topics
                let channel = target % Self.channels + 1
                let path = "/#narrow/channel/\(channel)-c/topic/topic-\(target)"
                content += index % 60 == 0
                    ? "<p><a class=\"message-link\" href=\"\(path)/near/\(100_000 + target)\">#c &gt; topic-\(target) @ 💬</a></p>"
                    : "<p><a class=\"stream-topic\" data-stream-id=\"\(channel)\" href=\"\(path)/with/\(100_000 + target)\">#c &gt; topic-\(target)</a></p>"
            }
            let json = Fixtures.channelMessageJSON(
                id: 100_000 + index, streamId: topic % Self.channels + 1,
                topic: "topic-\(topic)", content: content, flags: ["read"])
            return try ZulipJSON.decoder.decode(Message.self, from: Data(json.utf8))
        }
    }

    /// Write cost: the same 20k messages new, then rewritten in place.
    @Test func upsertCost() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("links-upsert-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try MessageDatabase(path: path)
        let batch = try messages(0..<20_000)
        report("upsert 20k new", try clock.measure { try database.upsert(batch, selfUserId: 1) })
        report(
            "upsert 20k existing",
            try clock.measure { try database.upsert(batch, selfUserId: 1) })
        var found = 0
        let extract = clock.measure {
            for message in batch {
                found += TopicLink.links(inHTML: message.content, realmURL: nil).count
            }
        }
        report("extract links from 20k messages (\(found))", extract)
    }

    @Test func indexVersusScan() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("links-bench-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = try MessageDatabase(path: path)
        for start in stride(from: 0, to: Self.messageCount, by: 20_000) {
            try database.upsert(
                try messages(start..<min(start + 20_000, Self.messageCount)), selfUserId: 1)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        print("[bench] database size: \(size / 1_048_576) MB, links: \(try database.linkCount())")

        // On demand, without the index: every stored channel message whose
        // payload mentions a narrow link, decoded and scanned.
        var scanned = 0
        let scanTime = try clock.measure {
            for data in try database.linkCandidatePayloads() {
                let message = try ZulipJSON.decoder.decode(Message.self, from: data)
                scanned += TopicLink.links(inHTML: message.content, realmURL: nil).count
            }
        }
        report("scan: every stored link (\(scanned))", scanTime)

        // The index's queries.
        var incoming: [TopicLinkRecord] = []
        let toTime = try clock.measure {
            incoming = try database.links(to: 14, topic: "topic-13")
        }
        report("index: links(to:) (\(incoming.count) rows)", toTime)
        var outgoing: [TopicLinkRecord] = []
        let fromTime = try clock.measure {
            outgoing = try database.links(from: 1, topic: "topic-0")
        }
        report("index: links(from:) (\(outgoing.count) rows)", fromTime)
        var all: [TopicLinkRecord] = []
        let allTime = try clock.measure { all = try database.allLinks() }
        report("index: allLinks (\(all.count) rows)", allTime)
        #expect(all.count == scanned)

        // A database written before the index existed, indexed in batches.
        try database.resetLinkIndex()
        var batches = 0
        var slowest = Duration.zero
        let total = try clock.measure {
            while true {
                var more = false
                let batch = try clock.measure { more = try database.backfillLinks() }
                slowest = max(slowest, batch)
                batches += 1
                if !more { break }
            }
        }
        report("backfill \(Self.messageCount) messages in \(batches) batches", total)
        report("backfill slowest batch", slowest)
        #expect(try database.linkCount() == scanned)
    }
}
