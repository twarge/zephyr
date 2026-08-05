import SwiftUI
import ZulipModel

/// Identifies a secondary window: double-clicking a sidebar entry opens the
/// destination in a fresh main window (sidebar collapsed until reopened),
/// scoped to an account.
struct DetachedWindow: Hashable, Codable {
    var accountId: Account.ID
    var destination: Destination
}

#if os(macOS)
/// An ordinary account window pinned to the double-clicked destination —
/// full app window, just starting with the sidebar closed. Its server can
/// be switched like any other window's.
struct DetachedRootView: View {
    let window: DetachedWindow

    var body: some View {
        AccountWindowView(
            defaultAccount: window.accountId,
            initialSelection: window.destination,
            startsWithSidebarClosed: true)
    }
}
#endif
