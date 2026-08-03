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
        let accounts = global.accounts
        guard !accounts.isEmpty else {
            phase = .needsAccount
            return
        }
        NotificationManager.shared.setup(appModel: self)
        // Restore the server that was front last time.
        let active = accounts.first(where: { $0.id == AppStateStore.lastActiveAccount })
            ?? accounts[0]
        await load(accountId: active.id)
        // Connect the other servers in the background so their notifications
        // and badge counts stay live while not front.
        for account in accounts where account.id != active.id {
            Task {
                _ = try? await global.perAccountStore(for: account.id)
                await global.stores[account.id]?.seedConversations()
            }
        }
    }

    func load(accountId: Account.ID) async {
        if global.hasLiveStore(accountId) {
            phase = .ready(accountId)
            AppStateStore.lastActiveAccount = accountId
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
            AppStateStore.lastActiveAccount = accountId
            await store.seedConversations()
        } catch {
            // Offline launch: if the cached snapshot is rendering, keep it
            // (with its "Connecting…" banner) and retry in the background
            // instead of replacing a working UI with a failure screen.
            if global.stores[accountId] != nil {
                phase = .ready(accountId)
                AppStateStore.lastActiveAccount = accountId
                scheduleReconnect(accountId)
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private var reconnecting: Set<Account.ID> = []

    private func scheduleReconnect(_ accountId: Account.ID) {
        guard !reconnecting.contains(accountId) else { return }
        reconnecting.insert(accountId)
        Task { [weak self] in
            defer { self?.reconnecting.remove(accountId) }
            while let self, !self.global.hasLiveStore(accountId),
                  self.global.accounts.contains(where: { $0.id == accountId }) {
                try? await Task.sleep(for: .seconds(15))
                if (try? await self.global.perAccountStore(for: accountId)) != nil {
                    await self.global.stores[accountId]?.seedConversations()
                    return
                }
            }
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
