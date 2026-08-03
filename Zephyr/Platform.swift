import SwiftUI
import UserNotifications

#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
#endif

extension Image {
    init(platform image: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

/// The small set of AppKit/UIKit divergences, in one place.
@MainActor
enum Platform {
    static func copyToPasteboard(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    static func setAppBadge(_ count: Int) {
        #if canImport(AppKit)
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : ""
        #else
        UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }

    /// Opens a downloaded file in the platform's default viewer. Returns
    /// false when the platform has no such concept (iOS) — callers fall back
    /// to Quick Look.
    static func openFile(_ url: URL) -> Bool {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        return true
        #else
        return false
        #endif
    }

    static func openExternalURL(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    static var isActive: Bool {
        #if canImport(AppKit)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    static func activate() {
        #if canImport(AppKit)
        NSApp.activate()
        #endif
    }

    static func playSendSound() {
        #if canImport(AppKit)
        NSSound(named: "Pop")?.play()
        #endif
    }
}
