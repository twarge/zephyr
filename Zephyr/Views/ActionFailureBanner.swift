import SwiftUI
import ZulipModel

extension View {
    /// Failed mute, pin, edit, delete, move… actions surface as a
    /// transient banner at the top of the pane instead of failing silently.
    func actionFailureBanner(store: PerAccountStore) -> some View {
        overlay(alignment: .top) {
            ActionFailureBanner(store: store)
        }
    }
}

/// Its own view, so only it observes the store's failure slot. Fades
/// after a few seconds, or on a click.
private struct ActionFailureBanner: View {
    let store: PerAccountStore

    var body: some View {
        Group {
            if let failure = store.lastActionFailure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .contentShape(.capsule)
                    .onTapGesture { store.clearActionFailure() }
                    .help("Dismiss")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Dismisses the message")
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: failure.id) {
                        AccessibilityNotification.Announcement(failure.message).post()
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, store.lastActionFailure?.id == failure.id
                        else { return }
                        store.clearActionFailure()
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.snappy, value: store.lastActionFailure?.id)
    }
}

extension View {
    /// The window's account was signed out (its credentials rejected —
    /// polling has stopped): a banner offering to sign in again.
    func signedOutBanner(store: PerAccountStore) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            SignedOutBanner(accountId: store.accountId)
        }
    }
}

/// Its own view, so only it observes the signed-out set.
private struct SignedOutBanner: View {
    let accountId: Account.ID

    @Environment(AppModel.self) private var model
    @State private var signingIn: Account?

    private var account: Account? {
        guard model.global.accountsNeedingReauthentication.contains(accountId) else { return nil }
        return model.global.accounts.first { $0.id == accountId }
    }

    var body: some View {
        if let account {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Signed out of \(account.realmName ?? account.realmURL.host() ?? "this server"). "
                    + "New messages won’t arrive until you sign in again.")
                    .font(.callout)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Sign In Again…") { signingIn = account }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            .sheet(item: $signingIn) { account in
                LoginView(reauthenticating: account)
                    .environment(model)
            }
        }
    }
}
