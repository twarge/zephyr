import Foundation
// internal: GRDB's extensions (SQL string literals, Collection.joined,
// query interpolation) must not leak into importers' overload resolution —
// they can silently change what a plain string literal infers to.
internal import GRDB
import ZulipAPI

/// The per-account SQLite message store: full retained history with FTS5,
/// replacing the bounded `messages.json` cache. Three jobs:
///
///  1. **Cold launch**: `recentPerConversation` restores the newest slice of
///     every conversation into the in-memory store in one indexed query.
///  2. **Offline scrollback**: `older(than:matching:)` pages history into a
///     transcript when the network fetch fails.
///  3. **Offline search**: `search(_:)` runs the query against an FTS5 index
///     of message text, topics, and sender names.
///
/// Rows keep the full `Message` as a `ZulipJSON` payload blob (so no field
/// mapping can drift), plus indexed columns for conversation identity and an
/// FTS shadow table maintained by triggers. One database per account, in the
/// account's offline directory.
public final class MessageDatabase: Sendable {
    private let queue: DatabaseQueue

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE message (
                    id INTEGER PRIMARY KEY,
                    stream_id INTEGER,
                    topic TEXT,
                    dm_key TEXT,
                    sender_id INTEGER NOT NULL,
                    sender_name TEXT NOT NULL,
                    timestamp INTEGER NOT NULL,
                    plain_text TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX message_topic ON message(stream_id, topic COLLATE NOCASE, id);
                CREATE INDEX message_dm ON message(dm_key, id);
                CREATE VIRTUAL TABLE message_fts USING fts5(
                    topic, sender, body, content='message', content_rowid='id');
                CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                    INSERT INTO message_fts(rowid, topic, sender, body)
                    VALUES (new.id, new.topic, new.sender_name, new.plain_text);
                END;
                CREATE TRIGGER message_ad AFTER DELETE ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, topic, sender, body)
                    VALUES ('delete', old.id, old.topic, old.sender_name, old.plain_text);
                END;
                CREATE TRIGGER message_au AFTER UPDATE ON message BEGIN
                    INSERT INTO message_fts(message_fts, rowid, topic, sender, body)
                    VALUES ('delete', old.id, old.topic, old.sender_name, old.plain_text);
                    INSERT INTO message_fts(rowid, topic, sender, body)
                    VALUES (new.id, new.topic, new.sender_name, new.plain_text);
                END;
                """)
        }
        try migrator.migrate(queue)
    }

    // MARK: Writes

    public func upsert(_ messages: [Message], selfUserId: Int) throws {
        guard !messages.isEmpty else { return }
        try queue.write { db in
            for message in messages {
                try Self.upsertRow(db, message: message, selfUserId: selfUserId)
            }
        }
    }

    public func upsertAsync(_ messages: [Message], selfUserId: Int) async throws {
        guard !messages.isEmpty else { return }
        try await queue.write { db in
            for message in messages {
                try Self.upsertRow(db, message: message, selfUserId: selfUserId)
            }
        }
    }

    private static func upsertRow(_ db: Database, message: Message, selfUserId: Int) throws {
        var streamId: Int?
        var topic: String?
        var dmKey: String?
        switch Unreads.conversationKey(for: message, selfUserId: selfUserId) {
        case .topic(let id, let name):
            streamId = id
            topic = name
        case .dm(let joined):
            dmKey = joined
        case nil:
            return
        }
        let payload = try ZulipJSON.encoder.encode(message)
        try db.execute(
            sql: """
                INSERT INTO message
                    (id, stream_id, topic, dm_key, sender_id, sender_name,
                     timestamp, plain_text, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    stream_id = excluded.stream_id,
                    topic = excluded.topic,
                    dm_key = excluded.dm_key,
                    sender_id = excluded.sender_id,
                    sender_name = excluded.sender_name,
                    timestamp = excluded.timestamp,
                    plain_text = excluded.plain_text,
                    payload = excluded.payload
                """,
            arguments: [
                message.id, streamId, topic, dmKey, message.senderId,
                message.senderFullName, message.timestamp,
                Self.plainText(fromHTML: message.content), payload,
            ])
    }

    public func delete(ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM message WHERE id IN (\(ids.map { String($0) }.joined(separator: ",")))")
        }
    }

    // MARK: Reads

    /// The newest `perConversation` messages of every conversation, ascending
    /// by id — the cold-launch restore set.
    public func recentPerConversation(_ perConversation: Int) throws -> [Message] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT payload FROM (
                        SELECT payload, id, ROW_NUMBER() OVER (
                            PARTITION BY stream_id, topic COLLATE NOCASE, dm_key
                            ORDER BY id DESC) AS rank
                        FROM message
                    ) WHERE rank <= ? ORDER BY id ASC
                    """,
                arguments: [perConversation])
            return Self.decode(rows)
        }
    }

    /// The narrows the database can page offline (server-only concepts like
    /// full-text or mentions narrows are excluded).
    public enum Filter: Sendable {
        case combined
        case channel(streamId: Int)
        case topic(streamId: Int, topic: String)
        case dm(key: String)

        public init?(narrow: Narrow, selfUserId: Int) {
            switch narrow {
            case .combinedFeed:
                self = .combined
            case .channel(let streamId):
                self = .channel(streamId: streamId)
            case .topic(let streamId, let topic):
                self = .topic(streamId: streamId, topic: topic)
            case .dm(let userIds):
                guard case .dm(let joined) = Unreads.dmKey(
                    participantIds: userIds, selfUserId: selfUserId)
                else { return nil }
                self = .dm(key: joined)
            case .mentions, .starred, .custom:
                return nil
            }
        }

        var condition: (sql: String, arguments: StatementArguments) {
            switch self {
            case .combined:
                ("1", [])
            case .channel(let streamId):
                ("stream_id = ?", [streamId])
            case .topic(let streamId, let topic):
                ("stream_id = ? AND topic = ? COLLATE NOCASE", [streamId, topic])
            case .dm(let key):
                ("dm_key = ?", [key])
            }
        }
    }

    /// Messages older than `id` in a narrow, ascending, newest `limit`.
    public func older(than id: Int, matching filter: Filter, limit: Int) throws -> [Message] {
        try queue.read { db in
            let (condition, arguments) = filter.condition
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT payload FROM message
                    WHERE \(condition) AND id < ?
                    ORDER BY id DESC LIMIT ?
                    """,
                arguments: arguments + [id, limit])
            return Self.decode(rows).sorted { $0.id < $1.id }
        }
    }

    /// Full-text search over body, topic, and sender name; newest first.
    public func search(_ text: String, limit: Int = 100) throws -> [Message] {
        let terms = text.split(whereSeparator: \.isWhitespace)
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
        guard !terms.isEmpty else { return [] }
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT message.payload FROM message_fts
                    JOIN message ON message.id = message_fts.rowid
                    WHERE message_fts MATCH ?
                    ORDER BY message.id DESC LIMIT ?
                    """,
                arguments: [terms.joined(separator: " "), limit])
            return Self.decode(rows).sorted { $0.id < $1.id }
        }
    }

    public func messageCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message") ?? 0
        }
    }

    private static func decode(_ rows: [Row]) -> [Message] {
        rows.compactMap { row in
            guard let data = row["payload"] as Data? else { return nil }
            return try? ZulipJSON.decoder.decode(Message.self, from: data)
        }
    }

    // MARK: HTML → indexable text

    /// A cheap tag-strip for the FTS index (not for display — rendering has
    /// the real parser; search just needs the words).
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
        ]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
