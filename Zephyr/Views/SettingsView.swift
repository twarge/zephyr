import SwiftUI
import UserNotifications
import ZulipModel

/// System Settings states that silently defeat the preferences below:
/// a denied permission suppresses banners and the app icon badge alike,
/// and the badge has its own per-app toggle.
private enum SystemNotificationIssue {
    case denied
    case badgesOff

    var explanation: String {
        switch self {
        case .denied:
            "Notifications are turned off for Zephyr in System Settings, "
                + "so message banners and the app icon badge won't appear."
        case .badgesOff:
            "App icon badges are turned off for Zephyr in System Settings."
        }
    }
}

enum BadgePolicy: String, CaseIterable, Identifiable {
    case dmsAndMentions
    case allUnreads
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dmsAndMentions: "Direct messages and mentions"
        case .allUnreads: "All unread messages"
        case .none: "None"
        }
    }
}

enum DmSortOrder: String, CaseIterable, Identifiable {
    case lastMessage
    case activity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastMessage: "Most recent message"
        case .activity: "Recent activity"
        }
    }
}

struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: 460)
        .padding(.bottom, 8)
        #else
        // A plain dismissable sheet — no fixed frame (that broke the
        // sheet geometry); each tab gets its own navigation stack and a
        // native grouped form. Help lives here (iOS has no Help menu).
        TabView {
            NavigationStack {
                GeneralSettings()
                    .navigationTitle("General")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("General", systemImage: "gearshape") }
            NavigationStack {
                AccountsSettings()
                    .navigationTitle("Accounts")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            NavigationStack {
                HelpView()
                    .navigationTitle("Help")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        #endif
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("badgePolicy") private var badgePolicy = BadgePolicy.dmsAndMentions.rawValue
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("messageRetentionYears") private var messageRetentionYears = 5
    @AppStorage("dmSortOrder") private var dmSortOrder = DmSortOrder.lastMessage.rawValue
    @AppStorage("recentSearchLimit") private var recentSearchLimit = 5
    @AppStorage("channelsAboveDMs") private var channelsAboveDMs = true
    @AppStorage("serverNameInTitles") private var serverNameInTitles =
        serverNameInTitlesDefault
    @State private var notificationIssue: SystemNotificationIssue?

    var body: some View {
        Group {
            #if os(macOS)
            macForm
            #else
            iosForm
            #endif
        }
        .task { await refreshNotificationIssue() }
        .onChange(of: badgePolicy) {
            UnreadMirror.shared.refresh()
            Task { await refreshNotificationIssue() }
        }
        // Re-check on return from System Settings.
        .onReceive(
            NotificationCenter.default.publisher(
                for: Platform.didBecomeActiveNotification)
        ) { _ in
            Task { await refreshNotificationIssue() }
        }
    }

    private func refreshNotificationIssue() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationIssue =
            switch settings.authorizationStatus {
            case .denied: .denied
            case .authorized, .provisional:
                settings.badgeSetting == .disabled
                    && (BadgePolicy(rawValue: badgePolicy) ?? .dmsAndMentions) != .none
                    ? .badgesOff : nil
            default: nil
            }
    }

    @ViewBuilder
    private var notificationIssueRows: some View {
        if let issue = notificationIssue {
            Label(issue.explanation, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            #if os(macOS)
            Button("Open System Settings…") {
                Platform.openNotificationSettings()
            }
            .controlSize(.small)
            #else
            Button("Open Notification Settings") {
                Platform.openNotificationSettings()
            }
            #endif
        }
    }

    private func applyRetention() {
        model.global.messageRetentionDays =
            AppModel.retentionDays(forYears: messageRetentionYears)
    }

    @ViewBuilder
    private var retentionOptions: some View {
        Text("1 year").tag(1)
        Text("2 years").tag(2)
        Text("5 years").tag(5)
        Text("10 years").tag(10)
        Text("Forever").tag(0)
    }

    #if os(macOS)
    private var macForm: some View {
        Form {
            Picker("App icon badge counts:", selection: $badgePolicy) {
                ForEach(BadgePolicy.allCases) { policy in
                    Text(policy.label).tag(policy.rawValue)
                }
            }
            .pickerStyle(.inline)
            Toggle("Show notifications for messages", isOn: $notificationsEnabled)
            notificationIssueRows
            Toggle("Show in menu bar", isOn: $showMenuBarExtra)
            Text("Direct messages and mentions notify while Zephyr is running. (Zulip has no push service for desktop clients.)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 4)
            Toggle("Channels above direct messages", isOn: $channelsAboveDMs)
            Toggle("Server name in window titles", isOn: $serverNameInTitles)
            Picker("Sort direct messages by:", selection: $dmSortOrder) {
                ForEach(DmSortOrder.allCases) { order in
                    Text(order.label).tag(order.rawValue)
                }
            }
            // LabeledContent splits the row like the pickers: caption in
            // the label column, value + arrows inline with the controls.
            LabeledContent("Recent searches kept:") {
                Stepper("\(recentSearchLimit)", value: $recentSearchLimit, in: 0...20)
                    .monospacedDigit()
            }
            Text("0 hides the Recent Searches section.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 4)
            Picker("Keep message history for:", selection: $messageRetentionYears) {
                retentionOptions
            }
            Text("Older messages are pruned from the offline archive on this device; starred messages are always kept. History on the server is unaffected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onChange(of: messageRetentionYears) { applyRetention() }
    }
    #else
    // Native grouped form: captions are section footers (the loose
    // caption/divider rows each drew their own separators).
    private var iosForm: some View {
        Form {
            Section {
                Picker("App icon badge counts", selection: $badgePolicy) {
                    ForEach(BadgePolicy.allCases) { policy in
                        Text(policy.label).tag(policy.rawValue)
                    }
                }
                Toggle("Show notifications for messages", isOn: $notificationsEnabled)
                notificationIssueRows
            } footer: {
                Text("Direct messages and mentions notify while Zephyr is running. (Zulip has no push service for desktop clients.)")
            }
            Section {
                Toggle("Channels above direct messages", isOn: $channelsAboveDMs)
                Toggle("Server name in window titles", isOn: $serverNameInTitles)
                Picker("Sort direct messages by", selection: $dmSortOrder) {
                    ForEach(DmSortOrder.allCases) { order in
                        Text(order.label).tag(order.rawValue)
                    }
                }
                Stepper(
                    "Recent searches kept: \(recentSearchLimit)",
                    value: $recentSearchLimit, in: 0...20)
                    .monospacedDigit()
            } footer: {
                Text("0 hides the Recent Searches section.")
            }
            Section {
                Picker("Keep message history for", selection: $messageRetentionYears) {
                    retentionOptions
                }
            } footer: {
                Text("Older messages are pruned from the offline archive on this device; starred messages are always kept. History on the server is unaffected.")
            }
        }
        .onChange(of: messageRetentionYears) { applyRetention() }
    }
    #endif
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(
                    Array(model.global.accounts.enumerated()), id: \.element.id
                ) { _, account in
                    HStack(spacing: 10) {
                        // Unchecked = disconnected but signed in: no events,
                        // windows, menus, or notifications; the login stays.
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { account.isEnabled },
                                set: { model.global.setAccountEnabled(account.id, enabled: $0) }))
                            .labelsHidden()
                            #if os(macOS)
                            .toggleStyle(.checkbox)
                            #endif
                            .help(
                                account.isEnabled
                                    ? "Disconnect this server (keeps the login)"
                                    : "Reconnect this server")
                        // ⌘N follows the enabled list (the Go menu's order);
                        // disabled accounts have no shortcut.
                        let enabledIndex = model.global.enabledAccounts
                            .firstIndex { $0.id == account.id }
                        if let enabledIndex, enabledIndex < 9 {
                            Text("⌘\(enabledIndex + 1)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                        } else {
                            Color.clear.frame(width: 30, height: 1)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.realmName ?? account.realmURL.host() ?? "?")
                                .font(.body.weight(.medium))
                            Text(account.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .opacity(account.isEnabled ? 1 : 0.5)
                        Spacer()
                        Button("Sign Out") {
                            Task { await model.signOut(accountId: account.id) }
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
                .onMove { fromOffsets, toOffset in
                    model.global.moveAccounts(fromOffsets: fromOffsets, toOffset: toOffset)
                }
            }
            .frame(minHeight: 160)
            Text("Drag to reorder — ⌘1…⌘9 show a server in the front window. Every window can show a different server.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add Account…") {
                showAddAccount = true
            }
        }
        .padding(20)
        .sheet(isPresented: $showAddAccount) {
            VStack(alignment: .trailing, spacing: 0) {
                HStack {
                    Spacer()
                    Button("Cancel") { showAddAccount = false }
                        .padding([.top, .trailing], 12)
                }
                // Scrollable with a real height: the sign-in form (SSO
                // buttons + fields) outgrew a content-sized sheet, cutting
                // off the bottom buttons.
                ScrollView {
                    LoginView()
                }
            }
            .frame(width: 500, height: 560)
        }
        .onChange(of: model.global.accounts.count) {
            showAddAccount = false
        }
    }
}
