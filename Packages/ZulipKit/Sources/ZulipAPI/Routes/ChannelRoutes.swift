import Foundation

/// One topic in a channel, from GET /users/me/{stream_id}/topics
/// (recency-ordered; `maxId` is the newest message id in the topic).
public struct ChannelTopic: Decodable, Sendable, Hashable {
    public var name: String
    public var maxId: Int
}

extension ApiConnection {
    public func getTopics(streamId: Int) async throws -> [ChannelTopic] {
        struct GetTopicsResult: Decodable {
            var topics: [ChannelTopic]
        }
        let result: GetTopicsResult = try await request(
            ApiRequest(method: .get, path: "/api/v1/users/me/\(streamId)/topics"))
        return result.topics
    }

    /// GET /streams — every channel the user can see (for the browser).
    public func getAllStreams() async throws -> [ZulipStream] {
        struct GetStreamsResult: Decodable {
            var streams: [ZulipStream]
        }
        let result: GetStreamsResult = try await request(
            ApiRequest(method: .get, path: "/api/v1/streams"))
        return result.streams
    }

    /// POST /users/me/subscriptions.
    public func subscribe(toChannel name: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/users/me/subscriptions",
                params: [
                    Param(
                        "subscriptions",
                        "[{\"name\": \(jsonString(name))}]")
                ]))
    }

    /// DELETE /users/me/subscriptions.
    public func unsubscribe(fromChannel name: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .delete, path: "/api/v1/users/me/subscriptions",
                params: [Param("subscriptions", "[\(jsonString(name))]")]))
    }

    /// POST /users/me/subscriptions/properties — per-channel settings
    /// (is_muted, pin_to_top, …).
    public func setSubscriptionProperty(
        streamId: Int, property: String, value: Bool
    ) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/users/me/subscriptions/properties",
                params: [
                    Param(
                        "subscription_data",
                        "[{\"stream_id\": \(streamId), \"property\": \(jsonString(property)), \"value\": \(value)}]")
                ]))
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
