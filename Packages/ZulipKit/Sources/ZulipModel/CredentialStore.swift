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

public struct KeychainCredentialStore: CredentialStore {
    public var service: String

    public init(service: String = "com.twarge.zephyr.api-key") {
        self.service = service
    }

    private func accountName(_ realmURL: URL, _ email: String) -> String {
        "\(email) @ \(realmURL.absoluteString)"
    }

    private func baseQuery(_ realmURL: URL, _ email: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName(realmURL, email),
        ]
    }

    public func apiKey(realmURL: URL, email: String) throws -> String? {
        var query = baseQuery(realmURL, email)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func setAPIKey(_ apiKey: String?, realmURL: URL, email: String) throws {
        let base = baseQuery(realmURL, email)
        guard let apiKey else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }
        let payload = [kSecValueData as String: Data(apiKey.utf8)]
        let updateStatus = SecItemUpdate(base as CFDictionary, payload as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data(apiKey.utf8)
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else {
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        }
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
