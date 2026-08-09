import SwiftUI
import ZulipModel

extension FocusedValues {
    /// The key window's account selection — ⌘1…⌘9 and the Servers menu
    /// route through it, so only that window switches.
    @Entry var windowAccount: Binding<Account.ID?>?
}

/// One window's account scope. Every window picks its own server (all
/// accounts stay connected concurrently), so switching here never changes
/// what another window shows.
struct AccountWindowView: View {
    @Environment(AppModel.self) private var model
    /// The account this window opens on when it has no restored state:
    /// detached windows pass their pinned account; main windows pass nil
    /// and fall back to the account last used anywhere.
    var defaultAccount: Account.ID?
    var initialSelection: Destination?
    var startsWithSidebarClosed = false

    /// Restored with the window, so every window comes back on its server.
    @SceneStorage("windowAccount") private var storedAccount = ""
    @State private var accountId: Account.ID?
    /// View-menu text sizing, applied window-wide.
    #if os(macOS)
    @State private var hostWindow: NSWindow?
    #endif

    var body: some View {
        Group {
            if let accountId, let store = model.global.stores[accountId] {
                MainSplitView(
                    store: store, selectedAccount: $accountId,
                    // The pinned destination belongs to the original
                    // account; it doesn't survive a server switch.
                    initialSelection: accountId == defaultAccount ? initialSelection : nil,
                    startsWithSidebarClosed: startsWithSidebarClosed)
                    .id(accountId)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .macWindowMinSize(width: 400, height: 300)
                    .task(id: accountId) {
                        guard let accountId else { return }
                        await model.ensureStore(accountId)
                    }
            }
        }
        .focusedSceneValue(\.windowAccount, $accountId)
        #if os(macOS)
        .background(WindowReader { window in hostWindow = window })
        #endif
        .onAppear {
            guard accountId == nil else { return }
            let accounts = model.global.enabledAccounts
            let valid = { (id: Account.ID?) in
                accounts.first { $0.id == id }?.id
            }
            accountId = valid(UUID(uuidString: storedAccount))
                ?? valid(defaultAccount)
                ?? valid(AppStateStore.lastActiveAccount)
                ?? accounts.first?.id
        }
        .onChange(of: accountId) {
            storedAccount = accountId?.uuidString ?? ""
            if let accountId {
                AppStateStore.lastActiveAccount = accountId
                if model.global.stores[accountId] == nil {
                    Task { await model.ensureStore(accountId) }
                }
            }
        }
        // A signed-out or disabled account falls back to whatever is left.
        .onChange(of: model.global.enabledAccounts.map(\.id)) {
            if let accountId,
               !model.global.enabledAccounts.contains(where: { $0.id == accountId }) {
                self.accountId = model.global.enabledAccounts.first?.id
            }
        }
        // A notification click for another server hops this window (the
        // key one) over; the new MainSplitView then consumes the
        // destination itself.
        .onChange(of: model.pendingDestination) {
            guard let pending = model.pendingDestination,
                  pending.account != accountId else { return }
            #if os(macOS)
            if hostWindow?.isKeyWindow == false && NSApp.keyWindow != nil { return }
            #endif
            accountId = pending.account
        }
        // A freshly added account is revealed by the first window to see
        // the request (adding happens in Settings, which is never a main
        // window, so there is no key-window preference to honor).
        .onChange(of: model.pendingAccountFocus) {
            guard let target = model.pendingAccountFocus else { return }
            model.pendingAccountFocus = nil
            accountId = target
        }
    }
}
