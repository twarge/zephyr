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

    /// PATCH /streams/{stream_id} — rename the channel (permissions are
    /// server-enforced; plain-string params since feature level 64).
    public func updateStream(streamId: Int, newName: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .patch, path: "/api/v1/streams/\(streamId)",
                params: [Param("new_name", newName)]))
    }

    /// POST /users/me/subscriptions with a new name — creates the channel
    /// (permission-gated server-side) and subscribes to it. `announce`
    /// posts the server's "new channel" notice.
    public func createChannel(
        name: String, description: String, inviteOnly: Bool, announce: Bool
    ) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/users/me/subscriptions",
                params: [
                    Param(
                        "subscriptions",
                        "[{\"name\": \(jsonString(name)), \"description\": \(jsonString(description))}]"),
                    Param("invite_only", inviteOnly ? "true" : "false"),
                    Param("announce", announce ? "true" : "false"),
                ]))
    }

    /// DELETE /streams/{id} — archives the channel (Zulip never hard
    /// deletes; history is preserved server-side).
    public func archiveStream(streamId: Int) async throws {
        _ = try await send(
            ApiRequest(method: .delete, path: "/api/v1/streams/\(streamId)"))
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

    /// String-valued subscription property (color).
    public func setSubscriptionProperty(
        streamId: Int, property: String, value: String
    ) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/users/me/subscriptions/properties",
                params: [
                    Param(
                        "subscription_data",
                        "[{\"stream_id\": \(streamId), \"property\": \(jsonString(property)), \"value\": \(jsonString(value))}]")
                ]))
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// POST /user_topics — per-topic visibility (0 none, 1 muted, 2 unmuted,
    /// 3 followed).
    public func setTopicVisibility(streamId: Int, topic: String, policy: Int) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/user_topics",
                params: [
                    Param("stream_id", String(streamId)),
                    Param("topic", topic),
                    Param("visibility_policy", String(policy)),
                ]))
    }
}
