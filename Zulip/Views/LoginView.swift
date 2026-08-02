import SwiftUI
import ZulipAPI

/// Realm discovery + sign-in. Password realms use fetch_api_key; any realm
/// works with a manually copied API key. (SSO via ASWebAuthenticationSession
/// is planned; see docs/ARCHITECTURE.md §7.)
struct LoginView: View {
    @Environment(AppModel.self) private var model

    private enum Step {
        case realm
        case credentials(ServerSettings, realm: URL)
    }

    private enum Method: String, CaseIterable, Identifiable {
        case password = "Password"
        case apiKey = "API Key"
        var id: String { rawValue }
    }

    @State private var step = Step.realm
    @State private var realmText = ""
    @State private var email = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var method = Method.password
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Zulip for macOS")
                .font(.title2.weight(.semibold))

            switch step {
            case .realm:
                realmForm
            case .credentials(let settings, let realm):
                credentialsForm(settings, realm: realm)
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 340)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(minWidth: 460, minHeight: 380)
    }

    private var realmForm: some View {
        VStack(spacing: 12) {
            TextField("Organization URL (e.g. chat.zulip.org)", text: $realmText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit { discoverRealm() }
            Button("Continue") { discoverRealm() }
                .keyboardShortcut(.defaultAction)
                .disabled(realmText.isEmpty || busy)
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private func credentialsForm(_ settings: ServerSettings, realm: URL) -> some View {
        VStack(spacing: 12) {
            Text(settings.realmName ?? realm.host() ?? "")
                .font(.headline)
            if let external = settings.externalAuthenticationMethods, !external.isEmpty {
                Text("This organization also offers \(external.map(\.displayName).joined(separator: ", ")) sign-in; use an API key for those accounts for now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 340)
                    .multilineTextAlignment(.center)
            }
            Picker("Method", selection: $method) {
                ForEach(availableMethods(settings)) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            switch method {
            case .password:
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit { signIn(settings, realm: realm) }
            case .apiKey:
                SecureField("API key (Personal settings → Account & privacy)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .onSubmit { signIn(settings, realm: realm) }
            }

            HStack {
                Button("Back") {
                    step = .realm
                    errorText = nil
                }
                Button("Sign In") { signIn(settings, realm: realm) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || email.isEmpty || (method == .password ? password.isEmpty : apiKey.isEmpty))
            }
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private func availableMethods(_ settings: ServerSettings) -> [Method] {
        (settings.emailAuthEnabled ?? false) ? [.password, .apiKey] : [.apiKey]
    }

    private func discoverRealm() {
        var text = realmText.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") {
            text = "https://\(text)"
        }
        guard let realm = URL(string: text), realm.host() != nil else {
            errorText = "That doesn't look like a URL."
            return
        }
        run {
            let settings = try await ApiConnection.getServerSettings(realm: realm)
            let canonicalRealm = settings.realmURL ?? realm
            method = (settings.emailAuthEnabled ?? false) ? .password : .apiKey
            step = .credentials(settings, realm: canonicalRealm)
        }
    }

    private func signIn(_ settings: ServerSettings, realm: URL) {
        run {
            let key: String
            switch method {
            case .password:
                key = try await ApiConnection.fetchApiKey(
                    realm: realm, username: email, password: password
                ).apiKey
            case .apiKey:
                key = apiKey.trimmingCharacters(in: .whitespaces)
            }
            let probe = ApiConnection(realmURL: realm, email: email, apiKey: key)
            let me = try await probe.getOwnUser()
            await model.addAccount(
                realm: realm, email: me.email, apiKey: key,
                userId: me.userId, realmName: settings.realmName)
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                try await body()
            } catch let error as ApiError {
                errorText = error.message.isEmpty ? error.code : error.message
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
