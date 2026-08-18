#if os(macOS)
import AppKit
#endif
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
        // One tip per week at most, app-wide: discovery without fatigue.
        try? Tips.configure([.displayFrequency(.weekly)])
        PerfLog.startWatchdogIfEnabled()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                // UIKit's keyboard-focus halo crashes (stale AttributeGraph
                // read in SwiftUI's focusEffect getter) when the focused
                // view is rebuilt in the same transaction the halo moves —
                // our compose field does exactly that. No halo, no crash.
                #if !os(macOS)
                .focusEffectDisabled()
                #endif
        }
        .commands { accountCommands }
        // Double-clicked sidebar entries open a fresh main window with the
        // sidebar collapsed (macOS and iPadOS both support multiple scenes).
        WindowGroup(for: DetachedWindow.self) { $window in
            if let window {
                DetachedRootView(window: window)
                    .environment(model)
                    #if !os(macOS)
                    .focusEffectDisabled()
                    #endif
            }
        }
        .defaultSize(width: 720, height: 640)
        // Double-clicked messages open standalone — sized for keeping a
        // poll or todo list in the corner of an eye.
        WindowGroup(for: MessageWindow.self) { $window in
            if let window {
                MessageWindowRootView(window: window)
                    .environment(model)
                    #if !os(macOS)
                    .focusEffectDisabled()
                    #endif
            }
        }
        .defaultSize(width: 460, height: 420)
        #if os(macOS)
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

/// The Go menu: history, the app views (⌥⌘1…6), Open Quickly, and the
/// key window's server (⌘1…⌘9, ordered as in Settings → Accounts) —
/// other windows keep showing theirs.
struct GoCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowAccount) private var windowAccount

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { model.pendingHistoryStep = -1 }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { model.pendingHistoryStep = 1 }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Recent") { model.pendingCommand = .navigate(.recentConversations) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Combined") { model.pendingCommand = .navigate(.combinedFeed) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Mentions") { model.pendingCommand = .navigate(.mentions) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Starred") { model.pendingCommand = .navigate(.starred) }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Button("Drafts") { model.pendingCommand = .navigate(.drafts) }
                .keyboardShortcut("5", modifiers: [.command, .option])
            Button("Outbox") { model.pendingCommand = .navigate(.outbox) }
                .keyboardShortcut("6", modifiers: [.command, .option])
            Divider()
            Button("Open Quickly…") { model.pendingOpenQuickly = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            ForEach(
                Array(model.global.enabledAccounts.prefix(9).enumerated()), id: \.element.id
            ) { index, account in
                Button(account.realmName ?? account.realmURL.host() ?? "Server \(index + 1)") {
                    windowAccount?.wrappedValue = account.id
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(windowAccount == nil)
            }
            ForEach(model.global.enabledAccounts.dropFirst(9)) { account in
                Button(account.realmName ?? account.realmURL.host() ?? "Server") {
                    windowAccount?.wrappedValue = account.id
                }
                .disabled(windowAccount == nil)
            }
        }
    }
}

extension ZephyrApp {
    #if os(macOS)
    private func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(
            string: "A native Zulip client.\n\n", attributes: base)
        var link = base
        link[.link] = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
        credits.append(NSAttributedString(string: "Apache License 2.0", attributes: link))
        credits.append(NSAttributedString(
            string: "\n© 2026 Twarge LLC"
                + "\nIncludes GRDB.swift, SwiftSoup, and SwiftMath (MIT).",
            attributes: base))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    #endif

    @CommandsBuilder
    var accountCommands: some Commands {
        GoCommands(model: model)
        #if os(macOS)
        // The standard About panel, with license credits (kept in code —
        // no Credits.rtf resource — so the text lives next to the
        // dependencies it names).
        CommandGroup(replacing: .appInfo) {
            Button("About Zephyr") { showAboutPanel() }
        }
        #endif
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                model.pendingNewConversation = true
            }
            .keyboardShortcut("n", modifiers: .command)
            // iPadOS supports multiple scenes too (Stage Manager etc.).
            Button("New Window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        #if os(macOS)
        // File → Export Selected…: the selected attachment (or message as
        // text) through a save panel. Like the Message menu, it targets
        // the key window's selection and no-ops without one.
        CommandGroup(after: .saveItem) {
            Button("Export Selected…") { model.pendingCommand = .exportSelected }
        }
        #endif
        // Edit → Find focuses the search field, like the / key. macOS
        // only: iPadOS's system menu already owns ⌘F, and duplicate
        // UIKeyCommands are undefined behavior (the / key and toolbar
        // search cover iPad).
        #if os(macOS)
        CommandGroup(after: .textEditing) {
            Button("Find") { model.pendingCommand = .find }
                .keyboardShortcut("f", modifiers: .command)
        }
        #endif
        // View additions: reload. (Text size follows the system's Dynamic
        // Type setting — no in-app override.)
        CommandGroup(before: .toolbar) {
            Button("Reload") { model.pendingCommand = .reload }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Message") {
            Button("Reply") { model.pendingCommand = .reply }
                .keyboardShortcut("r", modifiers: .command)
            Button("Reply Quoting Message") { model.pendingCommand = .replyQuoting }
            Button("Edit Message") { model.pendingCommand = .editMessage }
                // ⌘E is the system's Use Selection for Find on iPadOS.
                #if os(macOS)
                .keyboardShortcut("e", modifiers: .command)
                #else
                .keyboardShortcut("e", modifiers: [.command, .shift])
                #endif
            Button("Star / Unstar") { model.pendingCommand = .toggleStar }
            Divider()
            Button("Copy Message Reference") { model.pendingCommand = .copyReference }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Translate") { model.pendingCommand = .translate }
            Button("Move to Topic…") { model.pendingCommand = .moveToTopic }
            Button("Forward Message…") { model.pendingCommand = .forward }
            Divider()
            Button("Mark Conversation as Read") { model.pendingCommand = .markConversationRead }
            Button("Mark as Unread from Here") { model.pendingCommand = .markUnreadFromHere }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandMenu("Format") {
            Button("Bold") { model.pendingFormat = .bold }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { model.pendingFormat = .italic }
                .keyboardShortcut("i", modifiers: .command)
            Button("Strikethrough") { model.pendingFormat = .strikethrough }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Divider()
            Button("Link") { model.pendingFormat = .link }
                .keyboardShortcut("k", modifiers: .command)
            Button("Code") { model.pendingFormat = .code }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Quote") { model.pendingFormat = .quote }
                .keyboardShortcut("9", modifiers: [.command, .shift])
            Button("Spoiler") { model.pendingFormat = .spoiler }
        }
        CommandGroup(replacing: .help) {
            #if os(macOS)
            // Replaces the system Help stub (which needs a registered
            // help book) with our own manual window.
            Button("Zephyr Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)
            #endif
            Button("Keyboard Shortcuts") { model.pendingCommand = .shortcutsHelp }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}

/// View-menu text sizing: steps map onto Dynamic Type sizes (0 is the
/// system default).
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
                #if os(macOS)
                LoginView()
                #else
                // Scrollable so the keyboard can't hide the lower fields
                // or the error text under it on iPhone.
                ScrollView {
                    LoginView()
                }
                .scrollBounceBehavior(.basedOnSize)
                // visionOS has no scrollDismissesKeyboard.
                #if !os(visionOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                #endif
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
