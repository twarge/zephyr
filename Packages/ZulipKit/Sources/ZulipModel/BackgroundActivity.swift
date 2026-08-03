import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Keeps iOS from suspending the app while short critical work completes —
/// a send, or an offline-queue flush — so backgrounding right after tapping
/// Send doesn't strand the message. Without this, an in-flight send killed
/// by suspension persists as `.sending` and restores as `.failed` (the
/// ambiguity rule), forcing a manual retry for a message that never left.
///
/// A no-op on macOS, where apps keep running in the background.
@MainActor
public enum BackgroundActivity {
    /// Begins a background-task assertion; call the returned closure when
    /// the work finishes. The assertion also self-ends on expiry (~30s),
    /// as the system requires.
    public static func begin(_ name: String) -> @MainActor () -> Void {
        #if canImport(UIKit)
        @MainActor final class Assertion {
            var id: UIBackgroundTaskIdentifier = .invalid
            func end() {
                guard id != .invalid else { return }
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }
        let assertion = Assertion()
        assertion.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            assertion.end()
        }
        return { assertion.end() }
        #else
        return {}
        #endif
    }
}
