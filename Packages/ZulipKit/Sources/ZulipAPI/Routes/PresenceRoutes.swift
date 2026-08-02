import Foundation

/// Modern-protocol presence info for one user.
public struct PresenceInfo: Decodable, Sendable {
    public var activeTimestamp: Int?
    public var idleTimestamp: Int?
}

public struct UpdatePresenceResult: Decodable, Sendable {
    /// Keyed by user id (as a string).
    public var presences: [String: PresenceInfo]?
    public var presenceLastUpdateId: Int?
}

extension ApiConnection {
    /// POST /users/me/presence — the periodic ping (cadence:
    /// `server_presence_ping_interval_seconds`). Passing `lastUpdateId`
    /// selects the modern protocol: the response carries only what changed
    /// since (everything, on -1).
    public func updatePresence(
        status: String, lastUpdateId: Int, newUserInput: Bool
    ) async throws -> UpdatePresenceResult {
        try await request(
            ApiRequest(
                method: .post, path: "/api/v1/users/me/presence",
                params: [
                    Param("status", status),
                    Param("last_update_id", String(lastUpdateId)),
                    Param("new_user_input", newUserInput ? "true" : "false"),
                ]))
    }
}
