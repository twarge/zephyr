import SwiftUI
import ZulipModel

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
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            #if os(iOS)
            // iOS has no Help menu; Settings is the conventional home.
            HelpView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
            #endif
        }
        .frame(width: 460)
        .padding(.bottom, 8)
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

    var body: some View {
        Form {
            Picker("App icon badge counts:", selection: $badgePolicy) {
                ForEach(BadgePolicy.allCases) { policy in
                    Text(policy.label).tag(policy.rawValue)
                }
            }
            .pickerStyle(.inline)
            Toggle("Show notifications for messages", isOn: $notificationsEnabled)
            #if os(macOS)
            Toggle("Show in menu bar", isOn: $showMenuBarExtra)
            #endif
            Text("Direct messages and mentions notify while Zephyr is running. (Zulip has no push service for desktop clients.)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 4)
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
                Text("1 year").tag(1)
                Text("2 years").tag(2)
                Text("5 years").tag(5)
                Text("10 years").tag(10)
                Text("Forever").tag(0)
            }
            Text("Older messages are pruned from the offline archive on this device; starred messages are always kept. History on the server is unaffected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onChange(of: messageRetentionYears) {
            model.global.messageRetentionDays =
                AppModel.retentionDays(forYears: messageRetentionYears)
        }
    }
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showAddAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(
                    Array(model.global.accounts.enumerated()), id: \.element.id
                ) { index, account in
                    HStack(spacing: 10) {
                        if index < 9 {
                            Text("⌘\(index + 1)")
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
