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

    /// Signing in: dropping the legacy copy after a write must not take
    /// the new item with it (a query that doesn't name a keychain deletes
    /// from both).
    @Test func savedKeyReadsBack() throws {
        let backend = FakeKeychain()
        let store = backend.store()
        try store.setAPIKey("k", realmURL: realm, email: email)
        #expect(backend.modern == ["k"])
        #expect(try store.apiKey(realmURL: realm, email: email) == "k")
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

/// Two slots standing in for the two macOS keychains, routed the way
/// SecItem routes a query there: an explicit kSecUseDataProtectionKeychain
/// picks one keychain, and a query WITHOUT the key reaches both for reads,
/// updates and deletes (only an add defaults to the file-based one).
/// Single-account, which is all the tests need.
private final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private enum Slot { case modern, legacy }

    private let lock = NSLock()
    private var items: [Slot: String] = [:]
    var missingEntitlement = false
    var failModernAdd: OSStatus?
    var failLegacyDelete: OSStatus?

    var modern: [String] { lock.withLock { items[.modern].map { [$0] } ?? [] } }
    var legacy: [String] { lock.withLock { items[.legacy].map { [$0] } ?? [] } }

    func seed(legacy value: String) { lock.withLock { items[.legacy] = value } }
    func seed(modern value: String) { lock.withLock { items[.modern] = value } }

    func store() -> KeychainCredentialStore {
        KeychainCredentialStore(service: "test", backend: self, usesDataProtectionMigration: true)
    }

    /// The keychains a read, update or delete reaches, or the entitlement
    /// error when it asks for the data-protection one alone and can't have
    /// it (asked for both, that half is skipped — as SecItem does).
    private func slots(_ query: [String: Any]) -> Result<[Slot], KeychainError> {
        switch query[kSecUseDataProtectionKeychain as String] as? Bool {
        case true?:
            missingEntitlement
                ? .failure(KeychainError(status: errSecMissingEntitlement)) : .success([.modern])
        case false?:
            .success([.legacy])
        case nil:
            .success(missingEntitlement ? [.legacy] : [.modern, .legacy])
        }
    }

    func copyData(_ query: [String: Any]) -> (OSStatus, Data?) {
        switch slots(query) {
        case .failure(let error):
            return (error.status, nil)
        case .success(let slots):
            return lock.withLock {
                slots.lazy.compactMap { self.items[$0] }.first
                    .map { (errSecSuccess, Data($0.utf8)) } ?? (errSecItemNotFound, nil)
            }
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let modern = attributes[kSecUseDataProtectionKeychain as String] as? Bool == true
        if modern && missingEntitlement { return errSecMissingEntitlement }
        if modern, let failModernAdd { return failModernAdd }
        let slot: Slot = modern ? .modern : .legacy
        let value = String(decoding: attributes[kSecValueData as String] as! Data, as: UTF8.self)
        return lock.withLock {
            if items[slot] != nil { return errSecDuplicateItem }
            items[slot] = value
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        let value = String(decoding: attributes[kSecValueData as String] as! Data, as: UTF8.self)
        switch slots(query) {
        case .failure(let error):
            return error.status
        case .success(let slots):
            return lock.withLock {
                let present = slots.filter { items[$0] != nil }
                for slot in present { items[slot] = value }
                return present.isEmpty ? errSecItemNotFound : errSecSuccess
            }
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        switch slots(query) {
        case .failure(let error):
            return error.status
        case .success(let slots):
            if slots.contains(.legacy), let failLegacyDelete { return failLegacyDelete }
            return lock.withLock {
                let removed = slots.filter { items.removeValue(forKey: $0) != nil }
                return removed.isEmpty ? errSecItemNotFound : errSecSuccess
            }
        }
    }
}
