import Foundation
import Observation
import ZulipAPI
import ZulipModel

/// App-level state: owns the GlobalStore (real backends: accounts file +
/// Keychain), the launch/login phase, and notification routing.
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

    /// Set by MainSplitView; used to suppress banners for the conversation
    /// being read.
    var activeConversation: ConversationKey?
    /// Set by notification clicks; MainSplitView consumes it as navigation.
    var pendingDestination: Destination?

    var activeAccountId: Account.ID? {
        if case .ready(let id) = phase { return id }
        return nil
    }

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
        global.eventObserver = { [weak self] accountId, event in
            guard let self, case .message(let messageEvent) = event.kind,
                  let store = self.global.stores[accountId] else { return }
            NotificationManager.shared.handleMessageEvent(
                messageEvent, accountId: accountId, store: store)
        }
    }

    func start() async {
        guard case .launching = phase else { return }
        guard let account = global.accounts.first else {
            phase = .needsAccount
            return
        }
        NotificationManager.shared.setup(appModel: self)
        await load(accountId: account.id)
    }

    func load(accountId: Account.ID) async {
        if global.hasLiveStore(accountId) {
            phase = .ready(accountId)
            return
        }
        // Warm launch: render the cached snapshot instantly while the fresh
        // register runs; the live store replaces it when it arrives.
        if global.installCachedStore(for: accountId) {
            phase = .ready(accountId)
        } else {
            phase = .loading
        }
        do {
            let store = try await global.perAccountStore(for: accountId)
            phase = .ready(accountId)
            await store.seedConversations()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() async {
        guard let account = global.accounts.first else {
            phase = .needsAccount
            return
        }
        await load(accountId: account.id)
    }

    func switchAccount(_ accountId: Account.ID) async {
        guard accountId != activeAccountId else { return }
        await load(accountId: accountId)
    }

    /// Called by LoginView with a validated API key; becomes active.
    func addAccount(realm: URL, email: String, apiKey: String, userId: Int, realmName: String?) async {
        do {
            let account = try global.addAccount(
                realmURL: realm, email: email, apiKey: apiKey,
                userId: userId, realmName: realmName)
            NotificationManager.shared.setup(appModel: self)
            await load(accountId: account.id)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Signs out one account; switches to another or back to login.
    func signOut(accountId: Account.ID) async {
        try? await global.removeAccount(accountId)
        if activeAccountId == accountId || global.accounts.isEmpty {
            if let next = global.accounts.first {
                await load(accountId: next.id)
            } else {
                phase = .needsAccount
            }
        }
    }

    func signOutCurrent() async {
        if let activeAccountId {
            await signOut(accountId: activeAccountId)
        } else {
            for account in global.accounts {
                try? await global.removeAccount(account.id)
            }
            phase = .needsAccount
        }
    }
}
