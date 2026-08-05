import SwiftUI
import ZulipModel

@main
struct ZephyrApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
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
        #endif
    }
}

extension ZephyrApp {
    /// ⌘1…⌘9 switch servers, in the order set in Settings → Accounts.
    @CommandsBuilder
    var accountCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                model.pendingNewConversation = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(
                Array(model.global.accounts.prefix(9).enumerated()), id: \.element.id
            ) { index, account in
                Button(account.realmName ?? account.realmURL.host() ?? "Server \(index + 1)") {
                    Task { await model.switchAccount(account.id) }
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
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
            case .ready(let accountId):
                if let store = model.global.stores[accountId] {
                    // Per-account view state (selection, sidebar expansion)
                    // re-initializes from persistence on server switch.
                    MainSplitView(store: store)
                        .id(accountId)
                } else {
                    ProgressView()
                        .frame(minWidth: 400, minHeight: 300)
                }
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, newPhase in
            model.scenePhaseChanged(to: newPhase)
        }
    }
}
