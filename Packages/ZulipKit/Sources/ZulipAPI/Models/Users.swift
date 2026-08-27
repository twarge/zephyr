import Foundation

/// A realm user, as it appears in `realm_users` and `realm_user` events.
/// `avatarUrl` is optional because we register with the
/// `user_avatar_url_field_optional` capability (fetch via `GET /avatar/{id}`).
public struct User: Decodable, Sendable, Hashable, Identifiable {
    public var userId: Int
    public var email: String
    public var fullName: String
    public var isBot: Bool
    public var isActive: Bool?
    public var avatarUrl: String?

    public var id: Int { userId }

    public init(
        userId: Int, email: String, fullName: String, isBot: Bool = false,
        isActive: Bool? = true, avatarUrl: String? = nil
    ) {
        self.userId = userId
        self.email = email
        self.fullName = fullName
        self.isBot = isBot
        self.isActive = isActive
        self.avatarUrl = avatarUrl
    }
}

/// The partial `person` payload of a `realm_user` / `update` event: only the
/// changed fields are present.
public struct RealmUserUpdate: Decodable, Sendable {
    public var userId: Int
    public var fullName: String?
    public var avatarUrl: String?
    public var isActive: Bool?
}

/// Response of `GET /users/me` (subset).
public struct OwnUser: Decodable, Sendable {
    public var userId: Int
    public var email: String
    public var fullName: String
}
