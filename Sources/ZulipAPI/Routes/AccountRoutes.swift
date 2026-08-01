import Foundation

public struct ExternalAuthMethod: Decodable, Sendable {
    public var name: String
    public var displayName: String
    public var loginUrl: String
    public var signupUrl: String?
    public var displayIcon: String?
}

/// Response of GET /server_settings (unauthenticated realm discovery).
public struct ServerSettings: Decodable, Sendable {
    public var zulipVersion: String
    /// Absent on pre-3.0 servers; treat as 0 (far below our floor).
    public var zulipFeatureLevel: Int?
    public var realmName: String?
    public var emailAuthEnabled: Bool?
    public var requireEmailFormatUsernames: Bool?
    public var externalAuthenticationMethods: [ExternalAuthMethod]?
    public var pushNotificationsEnabled: Bool?

    private var realmUrl: String?
    private var realmUri: String?

    /// The canonical realm URL (`realm_url`, with the deprecated `realm_uri`
    /// as fallback).
    public var realmURL: URL? {
        (realmUrl ?? realmUri).flatMap(URL.init(string:))
    }
}

public struct FetchApiKeyResult: Decodable, Sendable {
    public var apiKey: String
    public var email: String
    public var userId: Int?
}

extension ApiConnection {
    /// GET /server_settings — unauthenticated; drives the login UI and the
    /// minimum-server check.
    public static func getServerSettings(
        realm: URL,
        transport: any ApiTransport = URLSessionTransport.shared
    ) async throws -> ServerSettings {
        let connection = ApiConnection(realmURL: realm, transport: transport)
        return try await connection.request(
            ApiRequest(method: .get, path: "/api/v1/server_settings"))
    }

    /// POST /fetch_api_key — password login; only works on realms with the
    /// email/LDAP auth backends enabled.
    public static func fetchApiKey(
        realm: URL,
        username: String,
        password: String,
        transport: any ApiTransport = URLSessionTransport.shared
    ) async throws -> FetchApiKeyResult {
        let connection = ApiConnection(realmURL: realm, transport: transport)
        return try await connection.request(
            ApiRequest(
                method: .post,
                path: "/api/v1/fetch_api_key",
                params: [Param("username", username), Param("password", password)]))
    }

    /// GET /users/me — identity check; the source of `userId` when the API key
    /// was entered manually.
    public func getOwnUser() async throws -> OwnUser {
        try await request(ApiRequest(method: .get, path: "/api/v1/users/me"))
    }
}
