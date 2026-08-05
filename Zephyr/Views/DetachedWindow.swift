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
/// Resolves the account's live store, then shows an ordinary MainSplitView —
/// a full app window, just starting with the sidebar closed.
struct DetachedRootView: View {
    @Environment(AppModel.self) private var model
    let window: DetachedWindow

    var body: some View {
        if let store = model.global.stores[window.accountId] {
            MainSplitView(
                store: store, initialSelection: window.destination,
                startsWithSidebarClosed: true)
                .id(window.accountId)
        } else {
            ContentUnavailableView(
                "Not Connected", systemImage: "wifi.exclamationmark",
                description: Text("This account isn't loaded."))
                .frame(minWidth: 420, minHeight: 360)
        }
    }
}
#endif
