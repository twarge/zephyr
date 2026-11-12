import SwiftUI
import ZulipAPI
import ZulipModel

// Zephyr for tvOS: a read-only monitor. Sign in once (API key), pick a
// channel, and the TV shows it live — announcements in big type, polls as
// live tally boards. Nothing is ever marked read from here.

@main
struct ZephyrTVApp: App {
    @State private var session = TVSession()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(session)
        }
    }
}

/// One account, one live store, no offline layer — the TV is a monitor.
/// Realm/email persist in UserDefaults, the API key in the Keychain.
@MainActor
@Observable
final class TVSession: UpdateMachineDelegate {
    enum Phase {
        case setup(error: String?)
        case connecting
        /// Saved credentials, server unreachable: retrying with backoff.
        /// A TV left running must ride out Wi-Fi drops and server restarts
        /// without falling back to the sign-in form.
        case reconnecting(lastError: String)
        case ready(PerAccountStore)
    }

    private(set) var phase: Phase = .setup(error: nil)
    private var machine: UpdateMachine?
    private var reconnectTask: Task<Void, Never>?
    private let credentials = KeychainCredentialStore(service: "com.twarge.zephyr.tv.api-key")

    var savedRealm: String {
        UserDefaults.standard.string(forKey: "tvRealm") ?? ""
    }

    var savedEmail: String {
        UserDefaults.standard.string(forKey: "tvEmail") ?? ""
    }

    private var savedKey: String? {
        guard !savedRealm.isEmpty, !savedEmail.isEmpty, let url = URL(string: savedRealm)
        else { return nil }
        return try? credentials.apiKey(realmURL: url, email: savedEmail)
    }

    /// Whether the setup form may leave the key field empty and reuse the
    /// stored key (same server and email as last time).
    func hasSavedKey(realm: String, email: String) -> Bool {
        Self.normalizedRealm(realm) == savedRealm && email == savedEmail && savedKey != nil
    }

    /// Auto-connects at launch when credentials are already stored.
    func start() async {
        guard case .setup = phase, let key = savedKey else { return }
        reconnect(apiKey: key)
    }

    /// The setup form's Connect. An empty key field means "the saved one".
    /// A first sign-in reports any failure (likely a typo in the server or
    /// key); it doesn't retry.
    func signIn(realmText: String, email: String, apiKey: String) async {
        var key = apiKey
        if key.isEmpty, hasSavedKey(realm: realmText, email: email), let saved = savedKey {
            key = saved
        }
        guard !key.isEmpty else {
            phase = .setup(error: "Enter your API key.")
            return
        }
        reconnectTask?.cancel()
        phase = .connecting
        do {
            try await connect(realmText: realmText, email: email, apiKey: key)
        } catch {
            phase = .setup(error: Self.describe(error))
        }
    }

    /// Reconnects with saved credentials until it works or the server
    /// rejects them; only an auth failure goes back to sign-in.
    private func reconnect(apiKey: String) {
        reconnectTask?.cancel()
        let realm = savedRealm
        let email = savedEmail
        phase = .connecting
        reconnectTask = Task {
            var backoff = BackoffMachine(firstBound: .seconds(1), maxBound: .seconds(60))
            while !Task.isCancelled {
                do {
                    try await connect(realmText: realm, email: email, apiKey: apiKey)
                    return
                } catch where Task.isCancelled {
                    // Sign-out or a newer attempt owns `phase` now.
                    return
                } catch where Self.isAuthFailure(error) {
                    if isAuthenticationFailure(error) { forgetRejectedKey() }
                    phase = .setup(error: Self.describe(error))
                    return
                } catch {
                    phase = .reconnecting(lastError: Self.describe(error))
                    try? await Task.sleep(for: backoff.next())
                }
            }
        }
    }

    private func connect(realmText: String, email: String, apiKey: String) async throws {
        let text = Self.normalizedRealm(realmText)
        guard let realm = URL(string: text), realm.host() != nil else {
            throw TVSetupError(message: "That doesn't look like a server URL.")
        }
        let connection = ApiConnection(realmURL: realm, email: email, apiKey: apiKey)
        let me = try await connection.getOwnUser()
        let result = try await connection.registerQueue()
        try Task.checkCancellation()
        connection.featureLevel = result.snapshot.zulipFeatureLevel
        let account = Account(realmURL: realm, email: email, userId: me.userId)
        let store = PerAccountStore(
            account: account, connection: connection, snapshot: result.snapshot)
        let machine = UpdateMachine(store: store, delegate: self, enablePresence: false)
        machine.start()
        self.machine = machine
        UserDefaults.standard.set(text, forKey: "tvRealm")
        UserDefaults.standard.set(email, forKey: "tvEmail")
        try? credentials.setAPIKey(apiKey, realmURL: realm, email: email)
        phase = .ready(store)
    }

    func signOut() {
        reconnectTask?.cancel()
        reconnectTask = nil
        machine?.stop()
        machine = nil
        if let url = URL(string: savedRealm) {
            try? credentials.setAPIKey(nil, realmURL: url, email: savedEmail)
        }
        UserDefaults.standard.removeObject(forKey: "tvRealm")
        UserDefaults.standard.removeObject(forKey: "tvEmail")
        phase = .setup(error: nil)
    }

    /// The key was revoked (or the user/realm deactivated) while running:
    /// the machine has already stopped polling. Back to sign-in with the
    /// server and email still saved, so only a new key is needed.
    func updateMachineAuthenticationFailed(_ machine: UpdateMachine) {
        guard machine === self.machine else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        self.machine = nil
        forgetRejectedKey()
        phase = .setup(error: "The server no longer accepts this API key. Enter a new one.")
    }

    /// A rejected key must not be offered as "the saved key" again; realm
    /// and email stay so the form comes back prefilled.
    private func forgetRejectedKey() {
        if let url = URL(string: savedRealm) {
            try? credentials.setAPIKey(nil, realmURL: url, email: savedEmail)
        }
    }

    /// Queue death: rebuild by reconnecting with the saved credentials.
    func updateMachineNeedsRebuild(_ machine: UpdateMachine, reason: UpdateMachine.RebuildReason) {
        guard let key = savedKey else {
            phase = .setup(error: "Signed out by the server.")
            return
        }
        reconnect(apiKey: key)
    }

    /// Signed out for real: the server rejected the key or the account.
    /// Everything else — timeouts, DNS, 5xx, rate limits — is worth
    /// retrying. A saved server URL that no longer parses can't fix itself
    /// either.
    private static func isAuthFailure(_ error: Error) -> Bool {
        isAuthenticationFailure(error) || error is TVSetupError
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? ApiError {
            return error.message.isEmpty ? error.code : error.message
        }
        return error.localizedDescription
    }

    private static func normalizedRealm(_ realmText: String) -> String {
        let text = realmText.trimmingCharacters(in: .whitespaces)
        return text.contains("://") ? text : "https://\(text)"
    }
}

private struct TVSetupError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct TVRootView: View {
    @Environment(TVSession.self) private var session

    var body: some View {
        Group {
            switch session.phase {
            case .setup(let error):
                TVSetupView(error: error)
            case .connecting:
                ProgressView("Connecting…")
            case .reconnecting(let lastError):
                VStack(spacing: 16) {
                    ProgressView("Reconnecting…")
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Sign Out") { session.signOut() }
                }
            case .ready(let store):
                TVMonitorView(store: store)
            }
        }
        .task { await session.start() }
    }
}

/// Sign-in with the TV keyboard: server, email, API key (Personal
/// settings → Account & privacy in the web app).
/// With nothing saved here, the server and email come from the account
/// that's front in Zephyr on the user's other devices (it publishes them
/// to iCloud's key-value store; see SettingsSync there). The key is
/// always typed.
private struct TVSetupView: View {
    let error: String?

    @Environment(TVSession.self) private var session
    @State private var realm = ""
    @State private var email = ""
    @State private var apiKey = ""

    /// Fills only fields still empty: never over what was saved or typed.
    private func prefillFromCloud() {
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()
        if realm.isEmpty { realm = cloud.string(forKey: "activeAccountRealm") ?? "" }
        if email.isEmpty { email = cloud.string(forKey: "activeAccountEmail") ?? "" }
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Zephyr")
                .font(.largeTitle.weight(.semibold))
            Text("Monitor a channel or poll on the big screen.")
                .foregroundStyle(.secondary)
            TextField("Server (e.g. chat.zulip.org)", text: $realm)
                .textContentType(.URL)
            TextField("Email", text: $email)
                .textContentType(.username)
            SecureField(
                session.hasSavedKey(realm: realm, email: email)
                    ? "API key (leave empty to use the saved key)" : "API key",
                text: $apiKey)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
            Button("Connect") {
                Task {
                    await session.signIn(realmText: realm, email: email, apiKey: apiKey)
                }
            }
            .disabled(realm.isEmpty || email.isEmpty
                      || (apiKey.isEmpty && !session.hasSavedKey(realm: realm, email: email)))
        }
        .frame(maxWidth: 900)
        .onAppear {
            realm = session.savedRealm
            email = session.savedEmail
            prefillFromCloud()
        }
        // A first launch usually asks before iCloud has delivered.
        .onReceive(NotificationCenter.default.publisher(
            for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
        ).receive(on: RunLoop.main)) { _ in
            prefillFromCloud()
        }
    }
}
