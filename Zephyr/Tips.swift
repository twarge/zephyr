import SwiftUI
import TipKit

/// One-time discovery tips (TipKit tracks display state; each shows once).

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
