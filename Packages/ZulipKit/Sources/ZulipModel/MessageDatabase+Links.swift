import Foundation
internal import GRDB
import ZulipAPI

/// The conversation-link index behind View Links: one row per link in a
/// stored channel message (`TopicLink.links(inHTML:)`), written with the
/// message and dropped with it. Rows name only the linking message — where
/// that message is now comes from its own row, so a move rewrites no link
/// rows — and the target as its URL gives it; a target message that's
/// stored overrides the URL's location when read.
extension MessageDatabase {
    static func createLinkIndex(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE message_link (
                from_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                stream_id INTEGER NOT NULL,
                topic TEXT NOT NULL,
                topic_key TEXT NOT NULL,
                message_id INTEGER,
                is_message_link INTEGER NOT NULL
            );
            CREATE INDEX message_link_from ON message_link(from_id);
            CREATE INDEX message_link_topic ON message_link(stream_id, topic_key);
            CREATE INDEX message_link_message ON message_link(message_id);
            CREATE TABLE message_link_backfill (below_id INTEGER NOT NULL);
            INSERT INTO message_link_backfill SELECT COALESCE(MAX(id), 0) + 1 FROM message;
            """)
    }

    /// How a link's topic is matched: `TopicName.matches` as a column —
    /// Unicode case folding (SQLite's NOCASE folds ASCII only), the empty
    /// topic's legacy name collapsed.
    static func topicKey(_ topic: String) -> String {
        TopicName.canonical(topic).lowercased()
    }

    /// Replaces a message's indexed links with those in `content` ("" for
    /// a DM, which never links anywhere tracked), once each, in document
    /// order — rowids keep it. Runs for every row written, so its
    /// statements are cached.
    static func indexLinks(
        _ db: Database, messageId: Int, content: String, realmURL: URL?
    ) throws {
        try db.cachedStatement(sql: "DELETE FROM message_link WHERE from_id = ?")
            .execute(arguments: [messageId])
        var seen: Set<TopicLink> = []
        for link in TopicLink.links(inHTML: content, realmURL: realmURL)
        where seen.insert(link).inserted {
            try db.cachedStatement(sql: """
                INSERT INTO message_link
                    (from_id, stream_id, topic, topic_key, message_id, is_message_link)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
                .execute(arguments: [
                    messageId, link.streamId, link.topic, topicKey(link.topic),
                    link.messageId, link.kind == .message,
                ])
        }
    }

    // MARK: Backfill

    /// Indexes one batch of the rows stored before the link index existed,
    /// newest first, in its own transaction so other reads and writes
    /// interleave. Only rows whose payload mentions a narrow link are
    /// decoded. Returns whether rows remain.
    public func backfillLinks(batchSize: Int = 4000) throws -> Bool {
        let realmURL = realmURL
        return try queue.write { db -> Bool in
            guard let below = try Int.fetchOne(
                db, sql: "SELECT below_id FROM message_link_backfill"), below > 0
            else { return false }
            let floor = try Int.fetchOne(
                db,
                sql: "SELECT id FROM message WHERE id < ? ORDER BY id DESC LIMIT 1 OFFSET ?",
                arguments: [below, batchSize - 1]) ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, payload FROM message
                    WHERE id < ? AND id >= ? AND stream_id IS NOT NULL
                    AND instr(payload, '#narrow') > 0
                    """,
                arguments: [below, floor])
            for row in rows {
                guard let data = row["payload"] as Data?,
                      let message = try? ZulipJSON.decoder.decode(Message.self, from: data)
                else { continue }
                try Self.indexLinks(
                    db, messageId: row["id"], content: message.content, realmURL: realmURL)
            }
            try db.execute(sql: "UPDATE message_link_backfill SET below_id = ?", arguments: [floor])
            return floor > 0
        }
    }

    // MARK: Reads

    /// Links in the messages of one topic ("Links to"), each target
    /// resolved; `sender`/`timestamp` describe a stored target message.
    public func links(from streamId: Int, topic: String) throws -> [TopicLinkRecord] {
        try queue.read { db in
            let (condition, arguments) = Self.topicCondition(
                "src", streamId: streamId, topic: topic)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.linkColumns) FROM message AS src
                    JOIN message_link AS l ON l.from_id = src.id
                    LEFT JOIN message AS dst ON dst.id = l.message_id
                    WHERE \(condition)
                    ORDER BY l.from_id, l.rowid
                    """,
                arguments: arguments)
            return rows.compactMap { Self.record($0, describing: "dst") }
        }
    }

    /// Links whose target resolves to one topic ("Linked from"): by the
    /// URL's location, plus links to a stored message now in the topic
    /// (moved there since); `sender`/`timestamp` describe the linking
    /// message. Rows that resolve elsewhere come back too — the caller's
    /// grouping keeps only those that land here.
    public func links(to streamId: Int, topic: String) throws -> [TopicLinkRecord] {
        try queue.read { db in
            let (byMessage, messageArguments) = Self.topicCondition(
                "dst", streamId: streamId, topic: topic)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.linkColumns) FROM message_link AS l
                    JOIN message AS src ON src.id = l.from_id
                    LEFT JOIN message AS dst ON dst.id = l.message_id
                    WHERE l.stream_id = ? AND l.topic_key = ?
                    UNION
                    SELECT \(Self.linkColumns) FROM message AS dst
                    JOIN message_link AS l ON l.message_id = dst.id
                    JOIN message AS src ON src.id = l.from_id
                    WHERE \(byMessage)
                    ORDER BY from_id, link_order
                    """,
                arguments: [streamId, Self.topicKey(topic)] + messageArguments)
            return rows.compactMap { Self.record($0, describing: "src") }
        }
    }

    /// Every stored link as source and resolved target — what decides
    /// which topics offer View Links.
    public func allLinks() throws -> [TopicLinkRecord] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.linkColumns) FROM message_link AS l
                    JOIN message AS src ON src.id = l.from_id
                    LEFT JOIN message AS dst ON dst.id = l.message_id
                    """)
            return rows.compactMap { Self.record($0, describing: nil) }
        }
    }

    public func linkCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_link") ?? 0
        }
    }

    /// The scan the index replaces — every channel payload that mentions a
    /// narrow link — kept for the benchmarks' comparison.
    func linkCandidatePayloads() throws -> [Data] {
        try queue.read { db in
            try Data.fetchAll(
                db,
                sql: """
                    SELECT payload FROM message
                    WHERE stream_id IS NOT NULL AND instr(payload, '#narrow') > 0
                    """)
        }
    }

    /// Back to a database written before the index (tests, benchmarks).
    func resetLinkIndex() throws {
        try queue.write { db in
            try db.execute(sql: """
                DELETE FROM message_link;
                UPDATE message_link_backfill
                SET below_id = (SELECT COALESCE(MAX(id), 0) + 1 FROM message);
                """)
        }
    }

    private static let linkColumns = """
        l.from_id, l.rowid AS link_order, src.stream_id AS src_stream, src.topic AS src_topic,
        src.sender_name AS src_sender, src.timestamp AS src_timestamp,
        l.stream_id, l.topic, l.message_id, l.is_message_link,
        dst.id AS dst_id, dst.stream_id AS dst_stream, dst.topic AS dst_topic,
        dst.sender_name AS dst_sender, dst.timestamp AS dst_timestamp
        """

    /// A result row as a record. A target message that's stored decides
    /// where the link goes — one in a DM makes the link void, as the web
    /// app treats it.
    private static func record(_ row: Row, describing side: String?) -> TopicLinkRecord? {
        guard let fromStream: Int = row["src_stream"] else { return nil }
        let kind: TopicLink.Kind = row["is_message_link"] ? .message : .topic
        var target = TopicLink(
            streamId: row["stream_id"], topic: row["topic"],
            messageId: row["message_id"], kind: kind)
        if (row["dst_id"] as Int?) != nil {
            guard let stream: Int = row["dst_stream"], let topic: String = row["dst_topic"]
            else { return nil }
            target.streamId = stream
            target.topic = topic
        }
        var record = TopicLinkRecord(
            fromMessageId: row["from_id"], fromStreamId: fromStream,
            fromTopic: row["src_topic"] ?? "", target: target)
        if let side {
            record.sender = row["\(side)_sender"]
            record.timestamp = row["\(side)_timestamp"]
        }
        return record
    }

    /// `Filter.topic`'s condition on one message table of a join.
    private static func topicCondition(
        _ table: String, streamId: Int, topic: String
    ) -> (String, StatementArguments) {
        if TopicName.canonical(topic).isEmpty {
            ("\(table).stream_id = ? AND \(table).topic IN ('', ?)",
             [streamId, TopicName.legacyEmptyName])
        } else {
            ("\(table).stream_id = ? AND \(table).topic = ? COLLATE NOCASE", [streamId, topic])
        }
    }

    // MARK: Edits and moves

    /// Applies a topic or channel move to stored copies the in-memory store
    /// doesn't hold (it saves its own), so transcripts and links resolve
    /// to where the messages are now.
    public func move(
        ids: [Int], toStreamId streamId: Int?, topic: String?, selfUserId: Int
    ) throws {
        guard streamId != nil || topic != nil else { return }
        try rewrite(ids: ids, selfUserId: selfUserId) { message in
            guard message.streamId != nil else { return false }
            if let streamId { message.streamId = streamId }
            if let topic { message.subject = topic }
            return true
        }
    }

    /// Applies a content edit to a stored copy the in-memory store doesn't
    /// hold, re-indexing its links.
    public func edit(
        id: Int, content: String, editTimestamp: Int?, selfUserId: Int
    ) throws {
        try rewrite(ids: [id], selfUserId: selfUserId) { message in
            message.content = content
            message.lastEditTimestamp = editTimestamp ?? message.lastEditTimestamp
            return true
        }
    }

    /// Decodes each stored row, lets `change` amend it (false skips it),
    /// and writes it back the way an upsert does.
    func rewrite(
        ids: [Int], selfUserId: Int, _ change: (inout Message) -> Bool
    ) throws {
        guard !ids.isEmpty else { return }
        let realmURL = realmURL
        try queue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT payload FROM message
                    WHERE id IN (\(ids.map { String($0) }.joined(separator: ",")))
                    """)
            for row in rows {
                guard let data = row["payload"] as Data?,
                      var message = try? ZulipJSON.decoder.decode(Message.self, from: data),
                      change(&message)
                else { continue }
                try Self.upsertRow(
                    db, message: message, selfUserId: selfUserId, realmURL: realmURL)
            }
        }
    }
}
