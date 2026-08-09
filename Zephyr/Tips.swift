import SwiftUI
import TipKit

// One-time discovery tips. All share the app-wide weekly display
// frequency (set in Tips.configure) so at most one surfaces per week,
// and each invalidates itself the first time its feature is used.

struct OpenQuicklyTip: Tip {
    var title: Text { Text("Jump Anywhere") }
    var message: Text? {
        Text("Open Quickly (⌘⇧O) finds any channel or view by name.")
    }
    var image: Image? { Image(systemName: "magnifyingglass") }
}

struct LongFormComposeTip: Tip {
    var title: Text { Text("Long-form Writing") }
    var message: Text? {
        Text("Expand for a resizable editor with live preview. Return adds a line; ⇧Return sends.")
    }
    var image: Image? { Image(systemName: "text.alignleft") }
}

/// Surfaces once a second account exists: windows are per-server.
struct PerWindowServersTip: Tip {
    @Parameter
    static var hasMultipleAccounts: Bool = false

    var rules: [Rule] {
        #Rule(Self.$hasMultipleAccounts) { $0 == true }
    }

    var title: Text { Text("One Server per Window") }
    var message: Text? {
        Text("⌘1–⌘9 switch this window's server. Open another window (⌘⇧N) to watch two servers at once.")
    }
    var image: Image? { Image(systemName: "macwindow.on.rectangle") }
}

/// Anchored to the followed-topic icon the first time one appears.
struct TopicStateIconsTip: Tip {
    var title: Text { Text("Topic States") }
    var message: Text? {
        Text("The bubble marks a followed topic (its messages notify you); the check marks a resolved one. Right-click any topic to follow, mute, or unfollow.")
    }
    var image: Image? { Image(systemName: "plus.message.fill") }
}

/// After a few launches: sidebar entries detach into their own windows.
struct DetachWindowTip: Tip {
    static let appOpened = Tips.Event(id: "appOpened")

    var rules: [Rule] {
        #Rule(Self.appOpened) { $0.donations.count >= 3 }
    }

    var title: Text { Text("Conversations in Their Own Windows") }
    var message: Text? {
        Text("Double-click any sidebar conversation to open it in a separate window.")
    }
    var image: Image? { Image(systemName: "rectangle.split.2x1") }
}

/// After the first image selection: Space + arrows drive Quick Look.
struct QuickLookNavigationTip: Tip {
    static let imageSelected = Tips.Event(id: "imageSelected")

    var rules: [Rule] {
        #Rule(Self.imageSelected) { $0.donations.count >= 1 }
    }

    var title: Text { Text("Preview Images") }
    var message: Text? {
        Text("Press Space to Quick Look a selected image — the arrow keys step through every image in the view.")
    }
    var image: Image? { Image(systemName: "eye") }
}
