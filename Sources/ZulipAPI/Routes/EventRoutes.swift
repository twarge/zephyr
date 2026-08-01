import Foundation

/// The client capabilities we declare on /register — zulip-flutter's set.
/// The types in our models assume these settings (e.g. optional `avatarUrl`).
public struct ClientCapabilities: Encodable, Sendable {
    public var notificationSettingsNull = true
    public var bulkMessageDeletion = true
    public var userAvatarUrlFieldOptional = true
    public var streamTypingNotifications = true
    public var userSettingsObject = true
    public var includeDeactivatedGroups = true
    public var emptyTopicName = true
    public var individualEmojiChanges = true

    public init() {}
}

public struct GetEventsResult: Decodable, Sendable {
    public var events: [Event]
}

extension ApiConnection {
    /// POST /register — creates the event queue and returns the initial
    /// snapshot. `apply_markdown: true` (content arrives as rendered HTML)
    /// and unfiltered event types for now (M0; filter before shipping).
    public func registerQueue(idleQueueTimeoutSeconds: Int? = nil) async throws -> InitialSnapshot {
        var params: [Param] = [
            Param("apply_markdown", "true"),
            Param("client_gravatar", "false"),
            Param("client_capabilities", try ZulipJSON.encodeString(ClientCapabilities())),
        ]
        if let idleQueueTimeoutSeconds, (featureLevel ?? 0) >= 481 {
            params.append(Param("idle_queue_timeout", String(idleQueueTimeoutSeconds)))
        }
        return try await request(
            ApiRequest(method: .post, path: "/api/v1/register", params: params))
    }

    /// GET /events — the long poll. `timeoutSeconds` should exceed the
    /// server's `event_queue_longpoll_timeout_seconds`.
    public func getEvents(
        queueId: String,
        lastEventId: Int,
        dontBlock: Bool = false,
        timeoutSeconds: Double = 100
    ) async throws -> [Event] {
        var params = [
            Param("queue_id", queueId),
            Param("last_event_id", String(lastEventId)),
        ]
        if dontBlock {
            params.append(Param("dont_block", "true"))
        }
        let result: GetEventsResult = try await request(
            ApiRequest(method: .get, path: "/api/v1/events", params: params, timeout: timeoutSeconds))
        return result.events
    }

    /// DELETE /events — clean up the queue on sign-out.
    public func deleteEventQueue(queueId: String) async throws {
        _ = try await send(
            ApiRequest(method: .delete, path: "/api/v1/events", params: [Param("queue_id", queueId)]))
    }
}
