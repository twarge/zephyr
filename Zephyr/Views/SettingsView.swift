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
        }
        .frame(width: 460)
        .padding(.bottom, 8)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("badgePolicy") private var badgePolicy = BadgePolicy.dmsAndMentions.rawValue
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("playSendSound") private var playSendSound = true
    @AppStorage("messageRetentionYears") private var messageRetentionYears = 5
    @AppStorage("dmSortOrder") private var dmSortOrder = DmSortOrder.lastMessage.rawValue

    var body: some View {
        Form {
            Picker("App icon badge counts:", selection: $badgePolicy) {
                ForEach(BadgePolicy.allCases) { policy in
                    Text(policy.label).tag(policy.rawValue)
                }
            }
            .pickerStyle(.inline)
            Toggle("Show notifications for messages", isOn: $notificationsEnabled)
            Text("Direct messages and mentions notify while Zephyr is running. (Zulip has no push service for desktop clients.)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Play sound when sending", isOn: $playSendSound)
            Divider()
                .padding(.vertical, 4)
            Picker("Sort direct messages by:", selection: $dmSortOrder) {
                ForEach(DmSortOrder.allCases) { order in
                    Text(order.label).tag(order.rawValue)
                }
            }
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
                        Image(systemName: account.id == model.activeAccountId
                            ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(account.id == model.activeAccountId
                                ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.realmName ?? account.realmURL.host() ?? "?")
                                .font(.body.weight(.medium))
                            Text(account.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if account.id != model.activeAccountId {
                            Button("Switch") {
                                Task { await model.switchAccount(account.id) }
                            }
                            .controlSize(.small)
                        }
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
            Text("Drag to reorder — the order sets the ⌘1…⌘9 switching shortcuts.")
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
                LoginView()
            }
            .frame(width: 480)
        }
        .onChange(of: model.global.accounts.count) {
            showAddAccount = false
        }
    }
}
