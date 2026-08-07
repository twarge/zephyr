import SwiftUI
import TipKit
import ZulipModel

@main
struct ZephyrApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    #if os(macOS)
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    #endif

    init() {
        try? Tips.configure()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
        }
        .commands { accountCommands }
        #if os(macOS)
        // Double-clicked sidebar entries open a fresh main window with the
        // sidebar collapsed.
        WindowGroup(for: DetachedWindow.self) { $window in
            if let window {
                DetachedRootView(window: window)
                    .environment(model)
            }
        }
        .defaultSize(width: 720, height: 640)
        Settings {
            SettingsView()
                .environment(model)
        }
        Window("Zephyr Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 620, height: 700)
        MenuBarExtra(
            "Zephyr", systemImage: "bubble.left.and.bubble.right",
            isInserted: $showMenuBarExtra
        ) {
            MenuBarContent()
                .environment(model)
        }
        #endif
    }
}

#if os(macOS)
/// The menu-bar glance: the most unread conversations across every server;
/// clicking one focuses it in a main window.
private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private struct Line: Identifiable {
        let id = UUID()
        let account: Account.ID
        let key: ConversationKey
        let title: String
        let count: Int
    }

    private var lines: [Line] {
        var out: [Line] = []
        for account in model.global.accounts {
            guard let store = model.global.stores[account.id] else { continue }
            for (key, ids) in store.unreads.unreadIds where !ids.isEmpty {
                out.append(Line(
                    account: account.id, key: key,
                    title: key.displayTitle(in: store), count: ids.count))
            }
        }
        return Array(out.sorted { $0.count > $1.count }.prefix(8))
    }

    var body: some View {
        if lines.isEmpty {
            Text("No unread conversations")
        } else {
            ForEach(lines) { line in
                Button("\(line.title)  (\(line.count))") {
                    show(line)
                }
            }
        }
        Divider()
        Button("Open Zephyr") {
            Platform.activate()
            openMainWindowIfNeeded()
        }
    }

    private func show(_ line: Line) {
        Platform.activate()
        model.pendingDestination = PendingDestination(
            account: line.account, destination: .conversation(line.key))
        openMainWindowIfNeeded()
    }

    private func openMainWindowIfNeeded() {
        let hasMainWindow = NSApp.windows.contains {
            $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
        }
        if !hasMainWindow {
            openWindow(id: "main")
        }
    }
}
#endif

/// ⌘1…⌘9 switch the key window's server (ordered as in Settings →
/// Accounts) — other windows keep showing theirs. Disabled when no main
/// window is focused.
struct AccountSwitchCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowAccount) private var windowAccount

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(
                Array(model.global.accounts.prefix(9).enumerated()), id: \.element.id
            ) { index, account in
                Button(account.realmName ?? account.realmURL.host() ?? "Server \(index + 1)") {
                    windowAccount?.wrappedValue = account.id
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(windowAccount == nil)
            }
        }
    }
}

extension ZephyrApp {
    @CommandsBuilder
    var accountCommands: some Commands {
        AccountSwitchCommands(model: model)
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                model.pendingNewConversation = true
            }
            .keyboardShortcut("n", modifiers: .command)
            #if os(macOS)
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            #endif
            Divider()
            Button("Open Quickly…") {
                model.pendingOpenQuickly = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        #if os(macOS)
        // Replaces the system Help stub (which needs a registered help
        // book) with our own manual window.
        CommandGroup(replacing: .help) {
            Button("Zephyr Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
        }
        #endif
        CommandMenu("Format") {
            Button("Bold") { model.pendingFormat = .bold }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { model.pendingFormat = .italic }
                .keyboardShortcut("i", modifiers: .command)
            Button("Link") { model.pendingFormat = .link }
                .keyboardShortcut("k", modifiers: .command)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .launching, .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(minWidth: 400, minHeight: 300)
            case .needsAccount:
                LoginView()
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Couldn't connect")
                        .font(.headline)
                    ScrollView {
                        Text(message)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 520, maxHeight: 180)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Retry") {
                            Task { await model.retry() }
                        }
                        .keyboardShortcut(.defaultAction)
                        Button("Sign Out") {
                            Task { await model.signOutCurrent() }
                        }
                    }
                }
                .padding(40)
                .frame(minWidth: 480, minHeight: 340)
            case .ready:
                // Each window picks (and restores) its own server.
                AccountWindowView()
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, newPhase in
            model.scenePhaseChanged(to: newPhase)
        }
    }
}
