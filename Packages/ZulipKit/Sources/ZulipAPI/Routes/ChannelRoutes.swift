import Foundation

/// One topic in a channel, from GET /users/me/{stream_id}/topics
/// (recency-ordered; `maxId` is the newest message id in the topic).
public struct ChannelTopic: Decodable, Sendable, Hashable {
    public var name: String
    public var maxId: Int

    public init(name: String, maxId: Int) {
        self.name = name
        self.maxId = maxId
    }
}

extension ApiConnection {
    public func getTopics(streamId: Int) async throws -> [ChannelTopic] {
        struct GetTopicsResult: Decodable {
            var topics: [ChannelTopic]
        }
        let result: GetTopicsResult = try await request(
            ApiRequest(
                method: .get, path: "/api/v1/users/me/\(streamId)/topics",
                // "" for the empty topic, matching the event stream (see
                // getMessages); ignored by servers without empty topics.
                params: [Param("allow_empty_topic_name", "true")]))
        return result.topics
    }

    /// GET /streams — every channel the user can see (for the browser).
    /// `includeArchived` adds archived channels, flagged by `isArchived`
    /// (older servers ignore the unknown parameter and return none).
    public func getAllStreams(includeArchived: Bool = false) async throws -> [ZulipStream] {
        struct GetStreamsResult: Decodable {
            var streams: [ZulipStream]
        }
        var params: [Param] = []
        if includeArchived {
            params.append(Param("exclude_archived", "false"))
        }
        let result: GetStreamsResult = try await request(
            ApiRequest(method: .get, path: "/api/v1/streams", params: params))
        return result.streams
    }

    /// PATCH /streams/{stream_id} — rename, description edit, and/or
    /// unarchive (`isArchived: false`, the only direction the server
    /// allows; feature level 388). Permissions are server-enforced;
    /// plain-string params since feature level 64.
    public func updateStream(
        streamId: Int, newName: String? = nil, description: String? = nil,
        isArchived: Bool? = nil
    ) async throws {
        var params: [Param] = []
        if let newName { params.append(Param("new_name", newName)) }
        if let description { params.append(Param("description", description)) }
        if let isArchived {
            params.append(Param("is_archived", isArchived ? "true" : "false"))
        }
        _ = try await send(
            ApiRequest(
                method: .patch, path: "/api/v1/streams/\(streamId)", params: params))
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

    /// GET /streams/{stream_id}/members — the subscriber user ids.
    public func getSubscribers(streamId: Int) async throws -> [Int] {
        struct GetSubscribersResult: Decodable {
            var subscribers: [Int]
        }
        let result: GetSubscribersResult = try await request(
            ApiRequest(method: .get, path: "/api/v1/streams/\(streamId)/members"))
        return result.subscribers
    }

    /// POST /users/me/subscriptions with principals — subscribes other
    /// users to the channel (permission-gated server-side).
    public func subscribe(userIds: [Int], toChannel name: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .post, path: "/api/v1/users/me/subscriptions",
                params: [
                    Param("subscriptions", "[{\"name\": \(jsonString(name))}]"),
                    Param(
                        "principals",
                        "[\(userIds.map(String.init).joined(separator: ","))]"),
                ]))
    }

    /// DELETE /users/me/subscriptions with principals — unsubscribes other
    /// users from the channel (permission-gated server-side).
    public func unsubscribe(userIds: [Int], fromChannel name: String) async throws {
        _ = try await send(
            ApiRequest(
                method: .delete, path: "/api/v1/users/me/subscriptions",
                params: [
                    Param("subscriptions", "[\(jsonString(name))]"),
                    Param(
                        "principals",
                        "[\(userIds.map(String.init).joined(separator: ","))]"),
                ]))
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
