import AuthenticationServices
import Foundation

/// The browser leg of Zulip's mobile web-auth flow: presents the system
/// auth sheet at the realm's login URL and returns the `zulip://login`
/// callback. No URL-scheme registration needed — the session intercepts its
/// own callback scheme, so an installed official Zulip app is untouched.
@MainActor
final class WebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    /// Captured on the main actor before the session starts —
    /// `presentationAnchor(for:)` arrives on the framework's own queue, so
    /// it must not touch NSApp/UIApplication (nor assumeIsolated: that
    /// traps with some SSO identity providers).
    private nonisolated(unsafe) var anchor: ASPresentationAnchor?

    func authenticate(at url: URL) async throws -> URL {
        // The fallback anchor is constructed HERE (main actor) —
        // ASPresentationAnchor.init is main-isolated and the delegate
        // callback below is not.
        #if canImport(AppKit)
        anchor = NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        #else
        // A bare UIWindow() is deprecated (iOS/tvOS/visionOS 26) and
        // belongs to no scene, so it could never present anyway.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let window = scenes.lazy.compactMap(\.keyWindow).first
            ?? scenes.first.map(UIWindow.init(windowScene:))
        else { throw ASWebAuthenticationSessionError(.presentationContextInvalid) }
        anchor = window
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            // @Sendable: without it the closure inherits this class's
            // MainActor isolation and traps when AuthenticationServices
            // invokes it on its XPC reply queue (the post-login crash).
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "zulip"
            ) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(
                        throwing: error ?? URLError(.userCancelledAuthentication))
                }
            }
            session.presentationContextProvider = self
            // Non-ephemeral: an existing IdP session (Google etc.) can be
            // reused instead of re-entering credentials.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        // Always set by authenticate() before the session starts.
        anchor!
    }
}
