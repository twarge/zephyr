import Foundation
import Observation
import SwiftUI
import ZulipAPI
import ZulipModel

/// Markdown formatting actions from the Format menu, routed to the
/// key window's compose bar.
enum ComposeFormat {
    case bold
    case italic
    case link
}

/// A navigation request (notification click), scoped to its account: the
/// key window hops servers first if it shows a different one.
struct PendingDestination: Equatable {
    var account: Account.ID
    var destination: Destination
}

/// The conversation being read in some window; banners for it are
/// suppressed while the app is active.
struct ActiveConversation: Equatable {
    var account: Account.ID
    var key: ConversationKey
}

/// App-level state: owns the GlobalStore (real backends: accounts file +
/// Keychain), the launch/login phase, and notification routing.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case launching
        case needsAccount
        case loading
        /// At least one account is up; the payload is only the launch
        /// account (each window picks its own server). Resolve stores via
        /// `global.stores[id]` at render time — the GlobalStore replaces
        /// them on event-queue rebuild.
        case ready(Account.ID)
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    let global: GlobalStore
    private var connectivity: ConnectivityMonitor?

    /// Set by MainSplitView; used to suppress banners for the conversation
    /// being read.
    var activeConversation: ActiveConversation?
    /// Set by notification clicks; the key window consumes it as navigation
    /// (switching servers first if needed).
    var pendingDestination: PendingDestination?
    /// Set after adding an account: the first window to see the request
    /// switches to it.
    var pendingAccountFocus: Account.ID?
    /// Set by File → New Conversation (⌘N); MainSplitView opens the sheet.
    var pendingNewConversation = false
    /// Set by the Format menu; the key window's compose applies it.
    var pendingFormat: ComposeFormat?

    private var defaultAccountId: Account.ID? {
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
        // Delegate + categories must exist before any notification response
        // arrives — including one that launches the app.
        NotificationManager.shared.attach(appModel: self)
        DraftStore.shared.onLocalChange = { [weak self] account, destination, text in
            self?.draftSyncers[account]?.localEdited(destination, text: text)
        }
        global.messageRetentionDays = Self.retentionDays(
            forYears: UserDefaults.standard.object(forKey: "messageRetentionYears") as? Int ?? 5)
    }

    /// Retention picker semantics: 0 means keep forever.
    static func retentionDays(forYears years: Int) -> Int? {
        years <= 0 ? nil : years * 365
    }

    func start() async {
        guard case .launching = phase else { return }
        connectivity = ConnectivityMonitor { [weak self] in
            self?.networkRestored()
        }
        let accounts = global.accounts
        guard !accounts.isEmpty else {
            phase = .needsAccount
            return
        }
        NotificationManager.shared.setup(appModel: self)
        // Restore the server that was front last time.
        let active = accounts.first(where: { $0.id == AppStateStore.lastActiveAccount })
            ?? accounts[0]
        DraftStore.shared.migrateLegacy(to: active.id)
        await load(accountId: active.id)
        // Connect the other servers in the background so their notifications
        // and badge counts stay live while not front.
        for account in accounts where account.id != active.id {
            Task {
                _ = try? await global.perAccountStore(for: account.id)
                await global.stores[account.id]?.seedConversations()
                self.ensureDraftSync(account.id)
            }
        }
    }

    // MARK: Server draft sync

    private var draftSyncers: [Account.ID: DraftSyncEngine] = [:]
    private var draftSyncStores: [Account.ID: ObjectIdentifier] = [:]

    /// (Re)creates the account's draft sync engine when its live store
    /// appears or is replaced; idempotent per store instance.
    func ensureDraftSync(_ accountId: Account.ID) {
        guard global.hasLiveStore(accountId),
              let store = global.stores[accountId] else { return }
        let identity = ObjectIdentifier(store)
        guard draftSyncStores[accountId] != identity else { return }
        draftSyncStores[accountId] = identity
        draftSyncers[accountId] = DraftSyncEngine(accountId: accountId, store: store)
    }

    func load(accountId: Account.ID) async {
        if global.hasLiveStore(accountId) {
            phase = .ready(accountId)
            AppStateStore.lastActiveAccount = accountId
            return
        }
        // Warm launch: render the cached snapshot instantly while the fresh
        // register runs; the live store replaces it when it arrives.
        if await global.installCachedStore(for: accountId) {
            phase = .ready(accountId)
        } else {
            phase = .loading
        }
        do {
            let store = try await global.perAccountStore(for: accountId)
            phase = .ready(accountId)
            AppStateStore.lastActiveAccount = accountId
            ensureDraftSync(accountId)
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
                    self.ensureDraftSync(accountId)
                    return
                }
            }
        }
    }

    /// Brings an account's store up for a window that wants to show it —
    /// cached snapshot first, live register after — without touching the
    /// launch phase, so other windows keep rendering.
    func ensureStore(_ accountId: Account.ID) async {
        guard !global.hasLiveStore(accountId) else { return }
        _ = await global.installCachedStore(for: accountId)
        if (try? await global.perAccountStore(for: accountId)) != nil {
            ensureDraftSync(accountId)
            await global.stores[accountId]?.seedConversations()
        } else {
            scheduleReconnect(accountId)
        }
    }

    func retry() async {
        guard let account = global.accounts.first else {
            phase = .needsAccount
            return
        }
        await load(accountId: account.id)
    }

    /// The network path came back: flush queued work on live stores, connect
    /// the rest right away (instead of waiting out the 15s reconnect loop),
    /// and leave any failure screen.
    private func networkRestored() {
        if case .failed = phase {
            Task { await self.retry() }
        }
        for account in global.accounts {
            if global.hasLiveStore(account.id) {
                global.stores[account.id]?.flushPending()
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    if (try? await self.global.perAccountStore(for: account.id)) != nil {
                        await self.global.stores[account.id]?.seedConversations()
                        self.ensureDraftSync(account.id)
                    }
                }
            }
        }
    }

    /// Belt-and-suspenders for the debounced message-cache writes: called on
    /// backgrounding and at quit.
    func persistCaches() {
        for store in global.stores.values {
            store.persistMessageCache(synchronously: true)
        }
    }

    private var backgroundLinger: (@MainActor () -> Void)?

    /// On iOS, backgrounding freezes the event stream immediately; a finite
    /// background-task assertion keeps it polling (~30s), so last-moment
    /// messages still produce notifications. No-op on macOS.
    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            backgroundLinger?()
            backgroundLinger = nil
        default:
            if backgroundLinger == nil {
                backgroundLinger = BackgroundActivity.begin("background-linger")
            }
            persistCaches()
        }
    }

    /// Called by LoginView with a validated API key. During launch/login it
    /// drives the phase; afterwards it only connects the account and asks a
    /// window to reveal it.
    func addAccount(realm: URL, email: String, apiKey: String, userId: Int, realmName: String?) async {
        do {
            let account = try global.addAccount(
                realmURL: realm, email: email, apiKey: apiKey,
                userId: userId, realmName: realmName)
            NotificationManager.shared.setup(appModel: self)
            if case .ready = phase {
                await ensureStore(account.id)
                pendingAccountFocus = account.id
            } else {
                await load(accountId: account.id)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Signs out one account; windows showing it fall back on their own.
    func signOut(accountId: Account.ID) async {
        try? await global.removeAccount(accountId)
        if global.accounts.isEmpty {
            phase = .needsAccount
        } else if defaultAccountId == accountId, let next = global.accounts.first {
            phase = .ready(next.id)
        }
    }

    /// The failure screen's escape hatch (no account is renderable there).
    func signOutCurrent() async {
        if let defaultAccountId {
            await signOut(accountId: defaultAccountId)
        } else {
            for account in global.accounts {
                try? await global.removeAccount(account.id)
            }
            phase = .needsAccount
        }
    }
}
