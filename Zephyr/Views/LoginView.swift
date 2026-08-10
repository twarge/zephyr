import AuthenticationServices
import SwiftUI
import ZulipAPI

/// Realm discovery + sign-in. External methods (Google, GitHub, SAML, …) use
/// the mobile web-auth flow via ASWebAuthenticationSession; password realms
/// use fetch_api_key; a manually copied API key remains as the escape hatch.
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
    @State private var webAuthSession = WebAuthSession()
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Zephyr for Zulip")
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
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { discoverRealm() }
            Button("Continue") { discoverRealm() }
                .keyboardShortcut(.defaultAction)
                .disabled(realmText.isEmpty || busy)
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private func credentialsForm(_ settings: ServerSettings, realm: URL) -> some View {
        let emailAuth = settings.emailAuthEnabled ?? false
        let external = settings.externalAuthenticationMethods ?? []
        // SSO-only realms show just their buttons; the manual API-key form
        // hides behind an "advanced" reveal instead of implying a password
        // login the server doesn't offer.
        let showsForm = emailAuth || showAdvanced

        return VStack(spacing: 12) {
            Text(settings.realmName ?? realm.host() ?? "")
                .font(.headline)
            if !external.isEmpty {
                VStack(spacing: 8) {
                    ForEach(external, id: \.name) { authMethod in
                        Button {
                            webSignIn(settings, realm: realm, loginPath: authMethod.loginUrl)
                        } label: {
                            HStack(spacing: 6) {
                                if let icon = authMethod.displayIcon,
                                   let iconURL = URL(string: icon, relativeTo: realm) {
                                    AsyncImage(url: iconURL) { image in
                                        image.resizable()
                                    } placeholder: {
                                        Color.clear
                                    }
                                    .frame(width: 18, height: 18)
                                }
                                Text("Sign in with \(authMethod.displayName)")
                            }
                            .frame(width: 260)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy)
                    }
                }
                if showsForm {
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if showsForm {
                if emailAuth {
                    Picker("Method", selection: $method) {
                        ForEach(availableMethods(settings)) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }

                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    // Keychain/Passwords AutoFill offers saved credentials.
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                switch method {
                case .password:
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .textContentType(.password)
                        .onSubmit { signIn(settings, realm: realm) }
                case .apiKey:
                    SecureField("API key (Personal settings → Account & privacy)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .onSubmit { signIn(settings, realm: realm) }
                }
            }

            HStack {
                Button("Back") {
                    step = .realm
                    showAdvanced = false
                    errorText = nil
                }
                if showsForm {
                    Button("Sign In") { signIn(settings, realm: realm) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || email.isEmpty
                            || (method == .password ? password.isEmpty : apiKey.isEmpty))
                }
            }
            if !showsForm {
                Button("Sign in with an API key instead…") {
                    showAdvanced = true
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            let settings: ServerSettings
            do {
                settings = try await ApiConnection.getServerSettings(realm: realm)
            } catch let error as ApiError
                where error.message.localizedCaseInsensitiveContains("subdomain") {
                // Zulip Cloud's root domain answers "Subdomain required"
                // when the address is missing its organization part —
                // say what to do instead of echoing server jargon.
                throw ApiError(
                    httpStatus: error.httpStatus, code: error.code,
                    message: "No organization found at \(realm.host() ?? "that address") — "
                        + "enter your organization's full address, "
                        + "like myorg.zulipchat.com.")
            } catch is DecodingError {
                // Reachable, but not a Zulip server (HTML or some other
                // non-server_settings answer).
                throw ApiError(
                    httpStatus: 0, code: "NOT_A_ZULIP_SERVER",
                    message: "No Zulip server found at \(realm.host() ?? "that address").")
            }
            let canonicalRealm = settings.realmURL ?? realm
            method = (settings.emailAuthEnabled ?? false) ? .password : .apiKey
            step = .credentials(settings, realm: canonicalRealm)
            // One option and it's SSO: straight into the browser flow (a
            // cancel lands on the credentials step to retry or go Back).
            let external = settings.externalAuthenticationMethods ?? []
            if !(settings.emailAuthEnabled ?? false), external.count == 1,
               let only = external.first {
                try await performWebSignIn(
                    settings, realm: canonicalRealm, loginPath: only.loginUrl)
            }
        }
    }

    private func signIn(_ settings: ServerSettings, realm: URL) {
        run {
            // Basic auth requires the user's *delivery* email (the server
            // rejects the per-user API alias like user123@realm as "Invalid
            // API key"). fetch_api_key returns the canonical one; for manual
            // keys, the typed email must be it.
            let key: String
            let authEmail: String
            switch method {
            case .password:
                let result = try await ApiConnection.fetchApiKey(
                    realm: realm, username: email, password: password)
                key = result.apiKey
                authEmail = result.email
            case .apiKey:
                key = apiKey.trimmingCharacters(in: .whitespaces)
                authEmail = email.trimmingCharacters(in: .whitespaces)
            }
            let probe = ApiConnection(realmURL: realm, email: authEmail, apiKey: key)
            let me = try await probe.getOwnUser()
            await model.addAccount(
                realm: realm, email: authEmail, apiKey: key,
                userId: me.userId, realmName: settings.realmName)
        }
    }

    /// Zulip's mobile web-auth flow (SSO and web password logins): browser
    /// sheet with a one-time pad; the zulip:// callback carries the API key
    /// XOR-encrypted with it. See docs/ARCHITECTURE.md §7.
    private func webSignIn(_ settings: ServerSettings, realm: URL, loginPath: String) {
        run {
            try await performWebSignIn(settings, realm: realm, loginPath: loginPath)
        }
    }

    private func performWebSignIn(
        _ settings: ServerSettings, realm: URL, loginPath: String
    ) async throws {
            let otp = WebAuth.generateOTP()
            guard let url = WebAuth.loginURL(realm: realm, loginPath: loginPath, otp: otp)
            else {
                throw ApiError(
                    httpStatus: 0, code: "BAD_REALM_URL", message: realm.absoluteString)
            }
            let callback: URL
            do {
                callback = try await webAuthSession.authenticate(at: url)
            } catch let error as ASWebAuthenticationSessionError
                where error.code == .canceledLogin {
                return  // User closed the sheet; not an error.
            }
            let payload = try WebAuth.parsePayload(callback)
            // The callback must come from the realm we asked to sign into.
            guard payload.realm.host()?.lowercased() == realm.host()?.lowercased() else {
                throw ApiError(
                    httpStatus: 0, code: "REALM_MISMATCH",
                    message: "The sign-in response came from a different server.")
            }
            let key = try WebAuth.decryptAPIKey(
                otpEncryptedAPIKey: payload.otpEncryptedAPIKey, otp: otp)
            await model.addAccount(
                realm: realm, email: payload.email, apiKey: key,
                userId: payload.userId, realmName: settings.realmName)
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
