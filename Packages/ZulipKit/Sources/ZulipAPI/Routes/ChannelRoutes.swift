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
}
