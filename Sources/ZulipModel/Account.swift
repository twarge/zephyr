import Foundation
import Synchronization

public enum ServerCompat {
    /// Zulip Server 9.0 — matches zulip-flutter's floor; modern API names
    /// (`channel`, `dm`, `direct`) are all safe unconditionally above this.
    public static let minFeatureLevel = 277
    public static let minVersionLabel = "9.0"
}

public enum ModelError: Error, Sendable {
    case accountNotFound
    case missingCredentials
    case serverTooOld(version: String, featureLevel: Int)
}

/// A signed-in account. The API key is deliberately NOT here — it lives in the
/// `CredentialStore` (Keychain in production).
public struct Account: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var realmURL: URL
    public var email: String
    public var userId: Int
    public var realmName: String?
    public var zulipVersion: String?
    public var zulipFeatureLevel: Int?

    public init(
        id: UUID = UUID(),
        realmURL: URL,
        email: String,
        userId: Int,
        realmName: String? = nil,
        zulipVersion: String? = nil,
        zulipFeatureLevel: Int? = nil
    ) {
        self.id = id
        self.realmURL = realmURL
        self.email = email
        self.userId = userId
        self.realmName = realmName
        self.zulipVersion = zulipVersion
        self.zulipFeatureLevel = zulipFeatureLevel
    }
}

/// Persistence for the account list (not credentials).
public protocol AccountsStore: Sendable {
    func load() throws -> [Account]
    func save(_ accounts: [Account]) throws
}

/// Production backend: a JSON file in Application Support.
public struct JSONFileAccountsStore: AccountsStore {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: ~/Library/Application Support/com.twarge.zulip/accounts.json
    public static func standard() throws -> JSONFileAccountsStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("com.twarge.zulip", isDirectory: true)
        return JSONFileAccountsStore(fileURL: dir.appendingPathComponent("accounts.json"))
    }

    public func load() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Account].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ accounts: [Account]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: fileURL, options: .atomic)
    }
}

public final class InMemoryAccountsStore: AccountsStore {
    private let state = Mutex<[Account]>([])

    public init() {}

    public func load() throws -> [Account] {
        state.withLock { $0 }
    }

    public func save(_ accounts: [Account]) throws {
        state.withLock { $0 = accounts }
    }
}
