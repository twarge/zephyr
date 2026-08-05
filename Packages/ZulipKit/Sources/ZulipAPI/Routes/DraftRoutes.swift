import Foundation

extension ApiConnection {
    /// POST /drafts — creates drafts, returning their server ids.
    public func createDraft(_ draft: ServerDraft) async throws -> Int {
        struct CreateResult: Decodable {
            var ids: [Int]
        }
        var payload = draft
        payload.id = nil
        let result: CreateResult = try await request(
            ApiRequest(
                method: .post, path: "/api/v1/drafts",
                params: [Param("drafts", try ZulipJSON.encodeString([payload]))]))
        guard let id = result.ids.first else {
            throw ApiError(
                httpStatus: 200, code: ApiError.malformedResponseCode,
                message: "draft create returned no id")
        }
        return id
    }

    /// PATCH /drafts/{id}.
    public func editDraft(id: Int, _ draft: ServerDraft) async throws {
        var payload = draft
        payload.id = id
        _ = try await send(
            ApiRequest(
                method: .patch, path: "/api/v1/drafts/\(id)",
                params: [Param("draft", try ZulipJSON.encodeString(payload))]))
    }

    /// DELETE /drafts/{id}.
    public func deleteDraft(id: Int) async throws {
        _ = try await send(
            ApiRequest(method: .delete, path: "/api/v1/drafts/\(id)"))
    }
}
