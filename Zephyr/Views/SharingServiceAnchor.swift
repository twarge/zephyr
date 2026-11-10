#if os(macOS)
import AppKit
import SwiftUI

/// Presents the system sharing picker anchored to the view it backs
/// whenever `items` lands, then clears it. AppKit-side because SwiftUI has
/// no programmatic ShareLink presentation and the picker needs an anchor
/// view (it draws its popover off this rect).
struct SharingServiceAnchor: NSViewRepresentable {
    @Binding var items: [Any]?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let staged = items else { return }
        // Presenting (and clearing the binding) must wait out the current
        // view update.
        DispatchQueue.main.async {
            guard items != nil else { return }
            items = nil
            NSSharingServicePicker(items: staged)
                .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}
#endif
