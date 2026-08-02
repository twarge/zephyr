import Foundation

public enum MessageAnchor: Sendable, Equatable {
    case newest
    case oldest
    case firstUnread
    case id(Int)

    var apiValue: String {
        switch self {
        case .newest: "newest"
        case .oldest: "oldest"
        case .firstUnread: "first_unread"
        case .id(let id): String(id)
        }
    }
}

/// One element of a narrow: `{"operator": …, "operand": …}`. Modern operator
/// names only (`channel`, `dm`, …) — all predate our feature-level floor.
public struct NarrowElement: Encodable, Sendable, Equatable {
    public enum Operand: Encodable, Sendable, Equatable {
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
}

public enum FlagOp: String, Sendable {
    case add
    case remove
}

extension ApiConnection {
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

    /// GET /messages — anchor-based history fetch.
    public func getMessages(
        anchor: MessageAnchor,
        numBefore: Int,
        numAfter: Int,
        narrow: [NarrowElement] = []
    ) async throws -> GetMessagesResult {
        var params = [
            Param("anchor", anchor.apiValue),
            Param("num_before", String(numBefore)),
            Param("num_after", String(numAfter)),
        ]
        if !narrow.isEmpty {
            params.append(Param("narrow", try ZulipJSON.encodeString(narrow)))
        }
        return try await request(
            ApiRequest(method: .get, path: "/api/v1/messages", params: params))
    }
}
