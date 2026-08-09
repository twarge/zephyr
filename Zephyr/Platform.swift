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
    /// The current text selection in the key window, read by sending
    /// copy(_:) through the responder chain into the pasteboard (SwiftUI
    /// exposes no selection API for selectable Text). The user's
    /// pasteboard contents are preserved.
    static func currentTextSelection() -> String? {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        let before = pasteboard.changeCount
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        guard pasteboard.changeCount != before else { return nil }
        let selection = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if let saved, !saved.isEmpty {
            pasteboard.writeObjects(saved)
        }
        guard let selection, !selection.isEmpty else { return nil }
        return selection
        #else
        return nil
        #endif
    }

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
}
