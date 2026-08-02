import Foundation
import Observation
import ZulipAPI
import ZulipModel

/// App-level state: owns the GlobalStore (real backends: accounts file +
/// Keychain) and the launch/login phase.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case launching
        case needsAccount
        case loading
        /// Resolve the store via `global.stores[id]` at render time — the
        /// GlobalStore replaces stores on event-queue rebuild.
        case ready(Account.ID)
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    let global: GlobalStore

    init() {
        do {
            global = try GlobalStore(
                accountsStore: try JSONFileAccountsStore.standard(),
                credentials: KeychainCredentialStore())
        } catch {
            // Unreadable accounts file: start fresh (in-memory never throws).
            global = try! GlobalStore(
                accountsStore: InMemoryAccountsStore(),
                credentials: KeychainCredentialStore())
        }
    }

    func start() async {
        guard case .launching = phase else { return }
        guard let account = global.accounts.first else {
            phase = .needsAccount
            return
        }
        await load(accountId: account.id)
    }

    func load(accountId: Account.ID) async {
        phase = .loading
        do {
            let store = try await global.perAccountStore(for: accountId)
            phase = .ready(accountId)
            await store.seedConversations()
        } catch let error as ModelError {
            if case .serverTooOld(let version, let level) = error {
                phase = .failed(
                    "This server runs Zulip \(version) (feature level \(level)); Zulip \(ServerCompat.minVersionLabel)+ is required.")
            } else {
                phase = .failed(String(describing: error))
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Called by LoginView with a validated API key.
    func addAccount(realm: URL, email: String, apiKey: String, userId: Int, realmName: String?) async {
        do {
            let account = try global.addAccount(
                realmURL: realm, email: email, apiKey: apiKey,
                userId: userId, realmName: realmName)
            await load(accountId: account.id)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        for account in global.accounts {
            try? await global.removeAccount(account.id)
        }
        phase = .needsAccount
    }
}
