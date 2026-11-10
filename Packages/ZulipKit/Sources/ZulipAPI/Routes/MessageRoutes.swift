import Foundation

public enum MessageAnchor: Sendable, Equatable {
    case newest
    case oldest
    case firstUnread
    case id(Int)
    /// The first message sent at or after this instant — the web's
    /// `date:` search (GET /messages only, FL 445). The server falls back
    /// to the newest message when none is that recent.
    case date(Date)

    var apiValue: String {
        switch self {
        case .newest: "newest"
        case .oldest: "oldest"
        case .firstUnread: "first_unread"
        case .id(let id): String(id)
        case .date: "date"
        }
    }
}

/// One element of a narrow: `{"operator": …, "operand": …}`. Modern operator
/// names only (`channel`, `dm`, …) — all predate our feature-level floor.
public struct NarrowElement: Encodable, Sendable, Hashable {
    public enum Operand: Encodable, Sendable, Hashable {
        case string(String)
        case int(Int)
        case intList([Int])

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .intList(let value): try container.encode(value)
            }
        }
    }

    public var operatorName: String
    public var operand: Operand
    public var negated: Bool?

    enum CodingKeys: String, CodingKey {
        case operatorName = "operator"
        case operand
        case negated
    }

    public init(_ operatorName: String, _ operand: Operand, negated: Bool? = nil) {
        self.operatorName = operatorName
        self.operand = operand
        self.negated = negated
    }
}

public struct GetMessagesResult: Decodable, Sendable {
    public var messages: [Message]
    public var foundNewest: Bool?
    public var foundOldest: Bool?
    public var historyLimited: Bool?
    public var anchor: Int?

    public init(
        messages: [Message], foundNewest: Bool?, foundOldest: Bool?,
        historyLimited: Bool? = nil, anchor: Int? = nil
    ) {
        self.messages = messages
        self.foundNewest = foundNewest
        self.foundOldest = foundOldest
        self.historyLimited = historyLimited
        self.anchor = anchor
    }
}

/// A pending message reminder (Zulip Server 11+): the reminders bot DMs
/// the user about the target message at the scheduled time.
public struct Reminder: Decodable, Sendable, Hashable, Identifiable {
    public var reminderId: Int
    public var reminderTargetMessageId: Int
    public var scheduledDeliveryTimestamp: Int

    public var id: Int { reminderId }
}

/// The server-side progress of a narrow-scoped flag update.
public struct NarrowFlagsResult: Decodable, Sendable {
    public var processedCount: Int
    public var updatedCount: Int
    public var lastProcessedId: Int?
    public var foundNewest: Bool
}

public enum FlagOp: String, Sendable {
    case add
    case remove
}

public struct SendMessageResult: Decodable, Sendable {
    public var id: Int
}

/// One version in a message's edit history.
public struct EditHistoryEntry: Decodable, Sendable {
    public var timestamp: Int
    public var renderedContent: String?
    public var topic: String?
    public var prevTopic: String?
    public var userId: Int?
}

extension ApiConnection {
    /// POST /messages, channel flavor. `queueId` + `localId` enable local
    /// echo: the resulting `message` event carries `local_message_id`.
    public func sendChannelMessage(
        streamId: Int, topic: String, content: String,
        queueId: String? = nil, localId: String? = nil
    ) async throws -> Int {
        var params = [
            Param("type", "channel"),
            Param("to", String(streamId)),
            Param("topic", topic),
            Param("content", content),
        ]
        if (featureLevel ?? 0) >= 236 {
            params.append(Param("read_by_sender", "true"))
        }
        if let queueId, let localId {
            params.append(Param("queue_id", queueId))
            params.append(Param("local_id", localId))
        }
        let result: SendMessageResult = try await request(
            ApiRequest(method: .post, path: "/api/v1/messages", params: params))
        return result.id
    }

    /// POST /messages, direct flavor. `userIds` are the recipients (the
    /// sender may be omitted; the server adds it).
    public func sendDirectMessage(
        userIds: [Int], content: String,
        queueId: String? = nil, localId: String? = nil
    ) async throws -> Int {
        var params = [
            Param("type", "direct"),
            Param("to", "[\(userIds.map(String.init).joined(separator: ","))]"),
            Param("content", content),
        ]
        if (featureLevel ?? 0) >= 236 {
            params.append(Param("read_by_sender", "true"))
        }
        if let queueId, let localId {
            params.append(Param("queue_id", queueId))
            params.append(Param("local_id", localId))
        }
        let result: SendMessageResult = try await request(
            ApiRequest(method: .post, path: "/api/v1/messages", params: params))
        return result.id
    }

    /// POST/DELETE /messages/{id}/reactions.
    public func updateReaction(
        messageId: Int, add: Bool,
        emojiName: String, emojiCode: String, reactionType: String
    ) async throws {
        _ = try await send(
            ApiRequest(
                method: add ? .post : .delete,
                path: "/api/v1/messages/\(messageId)/reactions",
                params: [
                    Param("emoji_name", emojiName),
                    Param("emoji_code", emojiCode),
                    Param("reaction_type", reactionType),
                ]))
    }

    /// DELETE /messages/{id} — permission-gated server-side.
    public func deleteMessage(messageId: Int) async throws {
        _ = try await send(
            ApiRequest(method: .delete, path: "/api/v1/messages/\(messageId)"))
    }

    /// PATCH /messages/{id} — content edit (topic/channel moves are separate).
    public func editMessage(messageId: Int, content: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .patch, path: "/api/v1/messages/\(messageId)",
                params: [Param("content", content)]))
    }

    /// PATCH /messages/{id} — move to another topic, and optionally
    /// another channel (propagateMode: change_one | change_later |
    /// change_all).
    public func moveMessage(
        messageId: Int, newTopic: String, newStreamId: Int? = nil, propagateMode: String
    ) async throws {
        var params = [
            Param("topic", newTopic),
            Param("propagate_mode", propagateMode),
        ]
        if let newStreamId {
            params.append(Param("stream_id", String(newStreamId)))
        }
        _ = try await send(
            ApiRequest(
                method: .patch, path: "/api/v1/messages/\(messageId)", params: params))
    }

    /// GET /messages/{id}/read_receipts — user ids who read the message
    /// (excludes opt-outs and mutes, server-side).
    public func getReadReceipts(messageId: Int) async throws -> [Int] {
        struct ReadReceiptsResult: Decodable {
            var userIds: [Int]
        }
        let result: ReadReceiptsResult = try await request(
            ApiRequest(method: .get, path: "/api/v1/messages/\(messageId)/read_receipts"))
        return result.userIds
    }

    /// GET /messages/{id}/history — the edit/move history, oldest first.
    public func getMessageHistory(messageId: Int) async throws -> [EditHistoryEntry] {
        struct HistoryResult: Decodable {
            var messageHistory: [EditHistoryEntry]
        }
        let result: HistoryResult = try await request(
            ApiRequest(
                method: .get, path: "/api/v1/messages/\(messageId)/history",
                // Empty topics as "" (not "(no topic)"), matching getMessages
                // and the event stream.
                params: [Param("allow_empty_topic_name", "true")]))
        return result.messageHistory
    }

    /// GET /messages/{id} with apply_markdown=false — the raw Zulip markdown
    /// (needed to prefill an edit).
    public func getRawMessageContent(messageId: Int) async throws -> String {
        struct SingleMessageResult: Decodable {
            struct Inner: Decodable {
                var content: String
            }
            var message: Inner
        }
        let result: SingleMessageResult = try await request(
            ApiRequest(
                method: .get, path: "/api/v1/messages/\(messageId)",
                params: [Param("apply_markdown", "false")]))
        return result.message.content
    }

    /// Link previews in rendered drafts (`populate_url_embed_data`, and the
    /// `url_embed_data` event that follows) arrived with Zulip Server 13.
    public static let previewEmbedsFeatureLevel = 513

    /// POST /messages/render — the server-rendered HTML for draft markdown
    /// (compose preview through the production renderer). On Zulip 13+ it
    /// includes the link previews the server already has; the rest arrive
    /// later as a `url_embed_data` event, when the server gets to them.
    public func renderMessage(content: String) async throws -> String {
        struct RenderResult: Decodable {
            var rendered: String
        }
        var params = [Param("content", content)]
        if (featureLevel ?? 0) >= Self.previewEmbedsFeatureLevel {
            params.append(Param("populate_url_embed_data", "true"))
        }
        let result: RenderResult = try await request(
            ApiRequest(method: .post, path: "/api/v1/messages/render", params: params))
        return result.rendered
    }
}

extension ApiConnection {
    /// The `hide_link_previews` flag arrived with Zulip Server 13; older
    /// servers reject it as an invalid flag.
    public static let hideLinkPreviewsFeatureLevel = 510

    /// POST /messages/flags — set/clear a flag (`read`, `starred`, …) on a
    /// set of messages.
    public func updateMessageFlags(messages: [Int], op: FlagOp, flag: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .post,
                path: "/api/v1/messages/flags",
                params: [
                    Param("messages", "[\(messages.map(String.init).joined(separator: ","))]"),
                    Param("op", op.rawValue),
                    Param("flag", flag),
                ]))
    }

    /// POST /messages/flags/narrow — flag updates across a narrow's full
    /// server-side history. One call covers a bounded batch; the caller
    /// continues from `lastProcessedId` until `foundNewest`.
    public func updateMessageFlagsForNarrow(
        anchor: MessageAnchor, includeAnchor: Bool, numBefore: Int, numAfter: Int,
        narrow: [NarrowElement], op: FlagOp, flag: String
    ) async throws -> NarrowFlagsResult {
        try await request(
            ApiRequest(
                method: .post, path: "/api/v1/messages/flags/narrow",
                params: [
                    Param("anchor", anchor.apiValue),
                    Param("include_anchor", includeAnchor ? "true" : "false"),
                    Param("num_before", String(numBefore)),
                    Param("num_after", String(numAfter)),
                    Param("narrow", try ZulipJSON.encodeString(narrow)),
                    Param("op", op.rawValue),
                    Param("flag", flag),
                ]))
    }

    /// POST /reminders — schedules a reminder about a message, delivered as
    /// a DM from the reminders bot at the given time (Zulip Server 11+).
    public func createReminder(messageId: Int, deliveryTimestamp: Int) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/reminders",
                params: [
                    Param("message_id", String(messageId)),
                    Param("scheduled_delivery_timestamp", String(deliveryTimestamp)),
                ]))
    }

    /// GET /reminders — the pending reminders.
    public func getReminders() async throws -> [Reminder] {
        struct GetRemindersResult: Decodable {
            var reminders: [Reminder]
        }
        let result: GetRemindersResult = try await request(
            ApiRequest(method: .get, path: "/api/v1/reminders"))
        return result.reminders
    }

    /// DELETE /reminders/{id} — cancels a pending reminder.
    public func deleteReminder(reminderId: Int) async throws {
        _ = try await send(
            ApiRequest(method: .delete, path: "/api/v1/reminders/\(reminderId)"))
    }

    /// `anchor: date` + `anchor_date` on GET /messages arrived with Zulip
    /// Server 12.
    public static let anchorDateFeatureLevel = 445

    /// `anchor_date` as a full datetime with a numeric offset (the API
    /// docs' form). Never "Z": Python before 3.11 can't parse it.
    static func anchorDateValue(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// GET /messages — anchor-based history fetch. The response's `anchor`
    /// is the message a `.date` anchor resolved to.
    public func getMessages(
        anchor: MessageAnchor,
        numBefore: Int,
        numAfter: Int,
        narrow: [NarrowElement] = []
    ) async throws -> GetMessagesResult {
        var anchor = anchor
        if case .date = anchor, (featureLevel ?? 0) < Self.anchorDateFeatureLevel {
            // Older servers can't place a date: the newest messages, as the
            // server itself falls back to when nothing is that recent.
            anchor = .newest
        }
        var params = [
            Param("anchor", anchor.apiValue),
            Param("num_before", String(numBefore)),
            Param("num_after", String(numAfter)),
            // Empty topic names arrive as "" — matching the event stream's
            // `empty_topic_name` capability. Without this, fetched copies
            // of the same messages read "(no topic)", and the mixed forms
            // break client-side narrow membership. Servers without
            // empty-topic support ignore the unknown parameter.
            Param("allow_empty_topic_name", "true"),
        ]
        if case .date(let date) = anchor {
            params.append(Param("anchor_date", Self.anchorDateValue(date)))
        }
        if !narrow.isEmpty {
            params.append(Param("narrow", try ZulipJSON.encodeString(narrow)))
        }
        return try await request(
            ApiRequest(method: .get, path: "/api/v1/messages", params: params))
    }

    /// POST /submessage — a widget interaction (poll vote, todo strike).
    /// `content` is the JSON-encoded widget event.
    public func sendSubmessage(messageId: Int, content: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/submessage",
                params: [
                    Param("message_id", String(messageId)),
                    Param("msg_type", "widget"),
                    Param("content", content),
                ]))
    }
}
