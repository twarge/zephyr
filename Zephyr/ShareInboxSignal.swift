import Foundation

/// Relays the share extension's Darwin notification (posted after it
/// writes an inbox item) as an in-process notification on the main
/// queue. Darwin notifications carry no payload; observers re-read the
/// inbox.
enum ShareInboxSignal {
    /// Must match the name the share extension posts.
    nonisolated static let darwinName = "com.twarge.zephyr.share-inbox-changed"

    /// Observing this name starts the Darwin observation (once).
    static var changed: Notification.Name {
        _ = registration
        return Notification.Name(darwinName)
    }

    private static let registration: Void = {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                // Delivered on an arbitrary thread.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name(ShareInboxSignal.darwinName), object: nil)
                }
            },
            darwinName as CFString, nil, .deliverImmediately)
    }()
}
