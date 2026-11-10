import Foundation
import Security
import Synchronization
import Testing
@testable import ZulipModel

/// The real SecItem calls can't be exercised here: an unsigned `swift test`
/// runner has no keychain entitlement, so the data-protection keychain
/// always answers errSecMissingEntitlement. These tests drive the macOS
/// migration logic through a fake backend instead.
struct CredentialStoreTests {
    private let realm = URL(string: "https://chat.example.com")!
    private let email = "me@example.com"

    @Test func readsMigrateLegacyItemIntoDataProtectionKeychain() throws {
        let backend = FakeKeychain()
        backend.seed(legacy: "old-key")
        let store = backend.store()
        #expect(try store.apiKey(realmURL: realm, email: email) == "old-key")
        #expect(backend.modern == ["old-key"])
        #expect(backend.legacy.isEmpty)
        // Second read hits the new keychain only.
        #expect(try store.apiKey(realmURL: realm, email: email) == "old-key")
    }

    @Test func failedMigrationWriteKeepsLegacyItem() throws {
        let backend = FakeKeychain()
        backend.seed(legacy: "old-key")
        backend.failModernAdd = errSecIO
        let store = backend.store()
        #expect(try store.apiKey(realmURL: realm, email: email) == "old-key")
        #expect(backend.legacy == ["old-key"])
        // Once the new keychain accepts it, the next read migrates.
        backend.failModernAdd = nil
        #expect(try store.apiKey(realmURL: realm, email: email) == "old-key")
        #expect(backend.modern == ["old-key"])
        #expect(backend.legacy.isEmpty)
    }

    @Test func failedLegacyDeleteStillReturnsKey() throws {
        let backend = FakeKeychain()
        backend.seed(legacy: "old-key")
        backend.failLegacyDelete = errSecIO
        let store = backend.store()
        #expect(try store.apiKey(realmURL: realm, email: email) == "old-key")
        #expect(backend.modern == ["old-key"])
        // The new copy wins from now on.
        #expect(try store.apiKey(realmURL: realm, email: email) == "old-key")
    }

    @Test func missingEntitlementFallsBackToLegacyKeychain() throws {
        let backend = FakeKeychain()
        backend.missingEntitlement = true
        let store = backend.store()
        try store.setAPIKey("k", realmURL: realm, email: email)
        #expect(backend.legacy == ["k"])
        #expect(try store.apiKey(realmURL: realm, email: email) == "k")
        try store.setAPIKey(nil, realmURL: realm, email: email)
        #expect(try store.apiKey(realmURL: realm, email: email) == nil)
    }

    @Test func writesGoToDataProtectionKeychainAndDropLegacy() throws {
        let backend = FakeKeychain()
        backend.seed(legacy: "old-key")
        let store = backend.store()
        try store.setAPIKey("new-key", realmURL: realm, email: email)
        #expect(backend.modern == ["new-key"])
        #expect(backend.legacy.isEmpty)
    }

    @Test func signOutClearsBothKeychains() throws {
        let backend = FakeKeychain()
        backend.seed(legacy: "old-key")
        backend.seed(modern: "new-key")
        let store = backend.store()
        try store.setAPIKey(nil, realmURL: realm, email: email)
        #expect(try store.apiKey(realmURL: realm, email: email) == nil)
    }

    @Test func nonMacPlatformsUseOneKeychain() throws {
        let backend = FakeKeychain()
        let store = KeychainCredentialStore(
            service: "test", backend: backend, usesDataProtectionMigration: false)
        try store.setAPIKey("k", realmURL: realm, email: email)
        // Without the flag every query lands in the "legacy" (only) bucket.
        #expect(backend.legacy == ["k"])
        #expect(try store.apiKey(realmURL: realm, email: email) == "k")
    }
}

/// Two dictionaries standing in for the two macOS keychains, picked by
/// kSecUseDataProtectionKeychain. Single-account, which is all the tests need.
private final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool: String] = [:]
    var missingEntitlement = false
    var failModernAdd: OSStatus?
    var failLegacyDelete: OSStatus?

    var modern: [String] { lock.withLock { items[true].map { [$0] } ?? [] } }
    var legacy: [String] { lock.withLock { items[false].map { [$0] } ?? [] } }

    func seed(legacy value: String) { lock.withLock { items[false] = value } }
    func seed(modern value: String) { lock.withLock { items[true] = value } }

    func store() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "test", backend: self, usesDataProtectionMigration: true)
    }

    private func isModern(_ query: [String: Any]) -> Bool {
        query[kSecUseDataProtectionKeychain as String] as? Bool == true
    }

    func copyData(_ query: [String: Any]) -> (OSStatus, Data?) {
        let modern = isModern(query)
        if modern && missingEntitlement { return (errSecMissingEntitlement, nil) }
        return lock.withLock {
            items[modern].map { (errSecSuccess, Data($0.utf8)) } ?? (errSecItemNotFound, nil)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let modern = isModern(attributes)
        if modern && missingEntitlement { return errSecMissingEntitlement }
        if modern, let failModernAdd { return failModernAdd }
        let value = String(decoding: attributes[kSecValueData as String] as! Data, as: UTF8.self)
        return lock.withLock {
            if items[modern] != nil { return errSecDuplicateItem }
            items[modern] = value
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        let modern = isModern(query)
        if modern && missingEntitlement { return errSecMissingEntitlement }
        let value = String(decoding: attributes[kSecValueData as String] as! Data, as: UTF8.self)
        return lock.withLock {
            guard items[modern] != nil else { return errSecItemNotFound }
            items[modern] = value
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let modern = isModern(query)
        if modern && missingEntitlement { return errSecMissingEntitlement }
        if !modern, let failLegacyDelete { return failLegacyDelete }
        return lock.withLock {
            items.removeValue(forKey: modern) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}
