import Foundation
import Security
import Synchronization

/// Storage for API keys, keyed by (realm, email). Production is the Keychain;
/// tests and the harness use the in-memory fake.
public protocol CredentialStore: Sendable {
    func apiKey(realmURL: URL, email: String) throws -> String?
    func setAPIKey(_ apiKey: String?, realmURL: URL, email: String) throws
}

public struct KeychainError: Error, Sendable {
    public var status: OSStatus
}

/// The four SecItem calls, behind a seam so the macOS migration logic is
/// testable without a signed binary (an unsigned `swift test` runner can't
/// reach the data-protection keychain at all).
protocol KeychainBackend: Sendable {
    func copyData(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SecItemBackend: KeychainBackend {
    func copyData(_ query: [String: Any]) -> (OSStatus, Data?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// On macOS, keys live in the data-protection keychain (the iOS-style one:
/// no per-app ACL prompts, no login-keychain unlock dependence). Items saved
/// by older builds in the legacy file-based keychain are migrated on first
/// read: copy to the new keychain, then delete the old one — the legacy item
/// is only removed once the new one is known written, so a failure at any
/// step leaves the token readable. Builds without a keychain entitlement
/// (unsigned / ad-hoc) get errSecMissingEntitlement from the data-protection
/// keychain and fall back to the legacy one, so they keep working.
public struct KeychainCredentialStore: CredentialStore {
    public var service: String
    let backend: any KeychainBackend
    /// Whether the data-protection keychain is a separate store to migrate
    /// from. Always true on macOS; iOS-family platforms only have one.
    let usesDataProtectionMigration: Bool

    public init(service: String = "com.twarge.zephyr.api-key") {
        #if os(macOS)
        self.init(service: service, backend: SecItemBackend(), usesDataProtectionMigration: true)
        #else
        self.init(service: service, backend: SecItemBackend(), usesDataProtectionMigration: false)
        #endif
    }

    init(service: String, backend: any KeychainBackend, usesDataProtectionMigration: Bool) {
        self.service = service
        self.backend = backend
        self.usesDataProtectionMigration = usesDataProtectionMigration
    }

    private func accountName(_ realmURL: URL, _ email: String) -> String {
        "\(email) @ \(realmURL.absoluteString)"
    }

    private enum Keychain { case modern, legacy }

    private func baseQuery(_ realmURL: URL, _ email: String, _ keychain: Keychain) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName(realmURL, email),
        ]
        if usesDataProtectionMigration {
            // Always named, false included: a query that leaves the key
            // out reaches BOTH keychains for reads, updates and deletes
            // (only an add defaults to the file-based one). Left out,
            // "drop the legacy copy" deleted the data-protection item
            // just written — no key survived a sign-in or a migration.
            query[kSecUseDataProtectionKeychain as String] = keychain == .modern
        }
        return query
    }

    // MARK: Single-keychain primitives

    private func read(_ realmURL: URL, _ email: String, _ keychain: Keychain) throws -> String? {
        var query = baseQuery(realmURL, email, keychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copyData(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ apiKey: String, _ realmURL: URL, _ email: String, _ keychain: Keychain) throws {
        let base = baseQuery(realmURL, email, keychain)
        let payload = [kSecValueData as String: Data(apiKey.utf8)]
        let updateStatus = backend.update(base, payload)
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data(apiKey.utf8)
            let addStatus = backend.add(add)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else {
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        }
    }

    private func remove(_ realmURL: URL, _ email: String, _ keychain: Keychain) throws {
        let status = backend.delete(baseQuery(realmURL, email, keychain))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static func isMissingEntitlement(_ error: Error) -> Bool {
        (error as? KeychainError)?.status == errSecMissingEntitlement
    }

    // MARK: CredentialStore

    public func apiKey(realmURL: URL, email: String) throws -> String? {
        guard usesDataProtectionMigration else {
            return try read(realmURL, email, .modern)
        }
        do {
            if let key = try read(realmURL, email, .modern) { return key }
        } catch where Self.isMissingEntitlement(error) {
            return try read(realmURL, email, .legacy)
        }
        guard let legacy = try read(realmURL, email, .legacy) else { return nil }
        // Migrate best effort: the caller gets the key either way, and a
        // failed step is simply retried on the next read.
        do {
            try write(legacy, realmURL, email, .modern)
            try? remove(realmURL, email, .legacy)
        } catch {}
        return legacy
    }

    public func setAPIKey(_ apiKey: String?, realmURL: URL, email: String) throws {
        guard usesDataProtectionMigration else {
            if let apiKey {
                try write(apiKey, realmURL, email, .modern)
            } else {
                try remove(realmURL, email, .modern)
            }
            return
        }
        guard let apiKey else {
            // Sign-out clears both, or a stale legacy item would be
            // "migrated" back on the next read.
            var modernError: Error?
            do { try remove(realmURL, email, .modern) } catch where !Self.isMissingEntitlement(error) {
                modernError = error
            } catch {}
            try remove(realmURL, email, .legacy)
            if let modernError { throw modernError }
            return
        }
        do {
            try write(apiKey, realmURL, email, .modern)
        } catch where Self.isMissingEntitlement(error) {
            try write(apiKey, realmURL, email, .legacy)
            return
        }
        // The new key is safely stored; drop any legacy copy so an old
        // key can't resurface later.
        try? remove(realmURL, email, .legacy)
    }
}

public final class InMemoryCredentialStore: CredentialStore {
    private let state = Mutex<[String: String]>([:])

    public init() {}

    private func key(_ realmURL: URL, _ email: String) -> String {
        "\(email)|\(realmURL.absoluteString)"
    }

    public func apiKey(realmURL: URL, email: String) throws -> String? {
        state.withLock { $0[key(realmURL, email)] }
    }

    public func setAPIKey(_ apiKey: String?, realmURL: URL, email: String) throws {
        state.withLock { $0[key(realmURL, email)] = apiKey }
    }
}
