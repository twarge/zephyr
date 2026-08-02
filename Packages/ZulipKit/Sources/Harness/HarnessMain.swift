import Darwin
import Dispatch
import Foundation
import ZulipAPI
import ZulipModel

/// M0 debug harness: sign in, sync, and stream live events to stdout.
///
///     zulip-harness login                      # fetch an API key (password realms)
///     ZULIP_REALM=… ZULIP_EMAIL=… ZULIP_API_KEY=… zulip-harness
@main
struct Harness {
    static func main() async {
        if CommandLine.arguments.contains("login") {
            await runLogin()
            return
        }
        let env = ProcessInfo.processInfo.environment
        guard
            let realmString = env["ZULIP_REALM"], let realm = URL(string: realmString),
            let email = env["ZULIP_EMAIL"],
            let apiKey = env["ZULIP_API_KEY"]
        else {
            print(
                """
                zulip-harness — M0 debug harness

                Usage:
                  zulip-harness login    interactively fetch an API key (password realms)
                  ZULIP_REALM=https://chat.example.com ZULIP_EMAIL=you@example.com \\
                    ZULIP_API_KEY=… zulip-harness
                """)
            exit(64)
        }
        await run(realm: realm, email: email, apiKey: apiKey)
    }

    // MARK: Live sync

    @MainActor
    static var sigintSource: (any DispatchSourceSignal)?

    @MainActor
    static func run(realm: URL, email: String, apiKey: String) async {
        do {
            let settings = try await ApiConnection.getServerSettings(realm: realm)
            print("→ \(settings.realmName ?? realm.host() ?? "?"): Zulip \(settings.zulipVersion) (feature level \(settings.zulipFeatureLevel ?? 0))")

            let probe = ApiConnection(realmURL: realm, email: email, apiKey: apiKey)
            let me = try await probe.getOwnUser()
            print("→ signed in as \(me.fullName) <\(me.email)> (user \(me.userId))")

            let global = try GlobalStore(
                accountsStore: InMemoryAccountsStore(),
                credentials: InMemoryCredentialStore())
            let account = try global.addAccount(
                realmURL: realm, email: email, apiKey: apiKey,
                userId: me.userId, realmName: settings.realmName)
            global.eventObserver = { _, event in
                printEvent(event)
            }

            let store = try await global.perAccountStore(for: account.id)
            print("→ synced: \(store.users.count) users, \(store.subscriptions.count) subscriptions, \(store.channels.count) channels, \(store.unreads.totalCount) unread")

            let recent = try await store.connection.getMessages(
                anchor: .newest, numBefore: 10, numAfter: 0)
            store.reconcileFetchedMessages(recent.messages)
            print("→ last \(recent.messages.count) messages:")
            for message in recent.messages {
                print("   \(format(message))")
            }

            print("→ polling for events (^C to quit)…")
            installSigint {
                Task { @MainActor in
                    await global.shutdown()
                    print("\n→ event queue deleted, bye")
                    exit(0)
                }
            }
            while true {
                try await Task.sleep(for: .seconds(3600))
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func installSigint(_ handler: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        sigintSource = source
    }

    static func printEvent(_ event: Event) {
        switch event.kind {
        case .heartbeat:
            break
        case .message(let e):
            print("● \(format(e.message))")
        case .updateMessage(let e):
            print("● edit: message \(e.messageId)")
        case .deleteMessage(let e):
            print("● delete: \(e.allIds)")
        case .updateMessageFlags(let e):
            print("● flags: \(e.op) \(e.flag) on \(e.all ? "all" : String(e.messages.count)) messages")
        case .unexpected(let type, let op):
            print("○ \(type)\(op.map { "/\($0)" } ?? "")")
        default:
            print("● \(event.kind)")
        }
    }

    static func format(_ message: Message) -> String {
        let text = plainText(message.content).prefix(120)
        switch message.displayRecipient {
        case .channelName(let channel):
            return "[#\(channel) › \(message.topic)] \(message.senderFullName): \(text)"
        case .users:
            return "[DM] \(message.senderFullName): \(text)"
        }
    }

    /// Crude HTML flattening for log output only (the real renderer is
    /// ZulipContent, M1).
    static func plainText(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "</p>", with: " ")
            .replacingOccurrences(of: "<br>", with: " ")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
        ]
        for (entity, char) in entities {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Login

    static func runLogin() async {
        print("Realm URL: ", terminator: "")
        guard let realmString = readLine(), let realm = URL(string: realmString) else {
            fputs("invalid realm URL\n", stderr)
            exit(64)
        }
        do {
            let settings = try await ApiConnection.getServerSettings(realm: realm)
            print("→ \(settings.realmName ?? "?"): Zulip \(settings.zulipVersion)")
            if let methods = settings.externalAuthenticationMethods, !methods.isEmpty {
                print("→ SSO methods available: \(methods.map(\.displayName).joined(separator: ", "))")
            }
            guard settings.emailAuthEnabled ?? false else {
                print("This realm has no password auth; copy your API key from the web app (Personal settings → Account & privacy) and set ZULIP_API_KEY.")
                exit(1)
            }
            print("Email: ", terminator: "")
            guard let email = readLine(), !email.isEmpty else { exit(64) }
            let password = String(validatingCString: getpass("Password: ")) ?? ""
            let result = try await ApiConnection.fetchApiKey(
                realm: realm, username: email, password: password)
            print(
                """

                export ZULIP_REALM=\(realm.absoluteString)
                export ZULIP_EMAIL=\(result.email)
                export ZULIP_API_KEY=\(result.apiKey)
                """)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }
}
