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
        case ready(PerAccountStore)
    }

    private(set) var phase: Phase = .setup(error: nil)
    private var machine: UpdateMachine?
    private let credentials = KeychainCredentialStore(service: "com.twarge.zephyr.tv.api-key")

    var savedRealm: String {
        UserDefaults.standard.string(forKey: "tvRealm") ?? ""
    }

    var savedEmail: String {
        UserDefaults.standard.string(forKey: "tvEmail") ?? ""
    }

    /// Auto-connects at launch when credentials are already stored.
    func start() async {
        guard case .setup = phase, !savedRealm.isEmpty, !savedEmail.isEmpty,
              let url = URL(string: savedRealm),
              let key = try? credentials.apiKey(realmURL: url, email: savedEmail)
        else { return }
        await connect(realmText: savedRealm, email: savedEmail, apiKey: key)
    }

    func connect(realmText: String, email: String, apiKey: String) async {
        var text = realmText.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") {
            text = "https://\(text)"
        }
        guard let realm = URL(string: text), realm.host() != nil else {
            phase = .setup(error: "That doesn't look like a server URL.")
            return
        }
        phase = .connecting
        let connection = ApiConnection(realmURL: realm, email: email, apiKey: apiKey)
        do {
            let me = try await connection.getOwnUser()
            let result = try await connection.registerQueue()
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
        } catch let error as ApiError {
            phase = .setup(error: error.message.isEmpty ? error.code : error.message)
        } catch {
            phase = .setup(error: error.localizedDescription)
        }
    }

    func signOut() {
        machine?.stop()
        machine = nil
        if let url = URL(string: savedRealm) {
            try? credentials.setAPIKey(nil, realmURL: url, email: savedEmail)
        }
        UserDefaults.standard.removeObject(forKey: "tvRealm")
        UserDefaults.standard.removeObject(forKey: "tvEmail")
        phase = .setup(error: nil)
    }

    /// Queue death: rebuild by reconnecting with the saved credentials.
    func updateMachineNeedsRebuild(_ machine: UpdateMachine, reason: UpdateMachine.RebuildReason) {
        guard let url = URL(string: savedRealm),
              let key = try? credentials.apiKey(realmURL: url, email: savedEmail)
        else {
            phase = .setup(error: "Signed out by the server.")
            return
        }
        let realm = savedRealm
        let email = savedEmail
        Task { await connect(realmText: realm, email: email, apiKey: key) }
    }
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
            case .ready(let store):
                TVMonitorView(store: store)
            }
        }
        .task { await session.start() }
    }
}

/// Sign-in with the TV keyboard: server, email, API key (Personal
/// settings → Account & privacy in the web app).
private struct TVSetupView: View {
    let error: String?

    @Environment(TVSession.self) private var session
    @State private var realm = ""
    @State private var email = ""
    @State private var apiKey = ""

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
            SecureField("API key", text: $apiKey)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
            Button("Connect") {
                Task {
                    await session.connect(realmText: realm, email: email, apiKey: apiKey)
                }
            }
            .disabled(realm.isEmpty || email.isEmpty || apiKey.isEmpty)
        }
        .frame(maxWidth: 900)
        .onAppear {
            realm = session.savedRealm
            email = session.savedEmail
        }
    }
}
