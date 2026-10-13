#if os(macOS)
import AppKit
#endif
import SwiftUI
import ZulipModel

/// Identifies a secondary window: double-clicking a sidebar entry opens the
/// destination in a fresh main window (sidebar collapsed until reopened),
/// scoped to an account. A message's "Go to Message" jump opened this way
/// (⌘-click, or the menu's In New Window) carries the message as `near`,
/// to land on and flash.
struct DetachedWindow: Hashable, Codable {
    var accountId: Account.ID
    var destination: Destination
    var near: Int? = nil
}

#if os(macOS)
/// ⌘-clicked jumps open as a tab of the clicked window (Settings → General
/// → "⌘-click opens: New tab"). SwiftUI has no tabbing API, so the request
/// is staged here and the new window joins its host's tab group as it
/// appears.
enum DetachedWindowTabs {
    private struct Request {
        let window: DetachedWindow
        weak var host: NSWindow?
    }
    private static var pending: Request?

    /// Defaults key; tabs unless the user picked windows. Nonisolated for
    /// the tip's text (UserDefaults reads are thread-safe).
    nonisolated static var commandClickOpensTab: Bool {
        UserDefaults.standard.object(forKey: "commandClickOpensTab") as? Bool ?? true
    }

    static func request(_ window: DetachedWindow, joining host: NSWindow?) {
        pending = host.map { Request(window: window, host: $0) }
    }

    /// Called once by a freshly opened detached window. Matching on the
    /// value means a window that merely came forward (openWindow(value:)
    /// reuses an open window with an equal value) never answers.
    static func adopt(_ nsWindow: NSWindow, as window: DetachedWindow) {
        guard let request = pending, request.window == window else { return }
        pending = nil
        guard let host = request.host, host !== nsWindow,
              host.tabGroup?.windows.contains(nsWindow) != true
        else { return }
        host.addTabbedWindow(nsWindow, ordered: .above)
        nsWindow.makeKeyAndOrderFront(nil)
    }
}
#endif

/// An ordinary account window pinned to the double-clicked destination —
/// full app window, just starting with the sidebar closed. Its server can
/// be switched like any other window's.
struct DetachedRootView: View {
    let window: DetachedWindow
    #if os(macOS)
    /// Only the window's first sighting of itself answers a tab request.
    @State private var checkedTabRequest = false
    #endif

    var body: some View {
        AccountWindowView(
            defaultAccount: window.accountId,
            initialSelection: window.destination,
            initialNear: window.near,
            startsWithSidebarClosed: true)
            #if os(macOS)
            .background(WindowReader { nsWindow in
                guard let nsWindow, !checkedTabRequest else { return }
                checkedTabRequest = true
                DetachedWindowTabs.adopt(nsWindow, as: window)
            })
            #endif
    }
}
