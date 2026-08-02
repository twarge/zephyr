import Foundation

extension ApiConnection {
    /// POST /typing, channel flavor. `op` is "start" or "stop"; cadence rules
    /// come from the register payload's `server_typing_*` constants.
    public func setTyping(op: String, streamId: Int, topic: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/typing",
                params: [
                    Param("op", op),
                    Param("type", "channel"),
                    Param("stream_id", String(streamId)),
                    Param("topic", topic),
                ]))
    }

    /// POST /typing, direct flavor.
    public func setTyping(op: String, userIds: [Int]) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/typing",
                params: [
                    Param("op", op),
                    Param("type", "direct"),
                    Param("to", "[\(userIds.map(String.init).joined(separator: ","))]"),
                ]))
    }
}
