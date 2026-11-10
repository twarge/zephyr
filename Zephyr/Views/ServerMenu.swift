import SwiftUI
import ZulipModel

/// The window's server menu: switching (⌘1–⌘9), account management, sign
/// out. One per window — it changes only this window's server.
struct ServerMenu: View {
    let store: PerAccountStore
    @Binding var selectedAccount: Account.ID?

    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        Menu {
            ForEach(
                Array(model.global.enabledAccounts.prefix(9).enumerated()), id: \.element.id
            ) { index, account in
                Button {
                    selectedAccount = account.id
                } label: {
                    if account.id == store.accountId {
                        Label(accountLabel(account), systemImage: "checkmark")
                    } else {
                        Text(accountLabel(account))
                    }
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            ForEach(model.global.enabledAccounts.dropFirst(9)) { account in
                Button {
                    selectedAccount = account.id
                } label: {
                    if account.id == store.accountId {
                        Label(accountLabel(account), systemImage: "checkmark")
                    } else {
                        Text(accountLabel(account))
                    }
                }
            }
            Divider()
            #if os(macOS)
            SettingsLink {
                Text("Accounts & Settings…")
            }
            #else
            Button("Accounts & Settings…") {
                showSettings = true
            }
            #endif
            Button("Sign Out of This Server…") {
                Task { await model.signOut(accountId: store.accountId) }
            }
        } label: {
            Text(store.realmName
                ?? store.connection.realmURL.host() ?? "Server")
                .font(.callout.weight(.medium))
        }
        .help("Servers and accounts (⌘1–⌘9 switch this window)")
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(model)
        }
    }

    private func accountLabel(_ account: Account) -> String {
        "\(account.realmName ?? account.realmURL.host() ?? "?") — \(account.email)"
    }
}
