import SwiftUI
import ZulipModel

/// "Send shared items to…": the destination picker shown when the share
/// extension has left items in the App Group inbox. Reuses Open Quickly's
/// channel/view search; picking navigates there and the compose bar seeds
/// itself from the inbox.
struct SharePickerSheet: View {
    let store: PerAccountStore
    let itemCount: Int
    var open: (Destination) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    itemCount == 1
                        ? "Send 1 shared item to…"
                        : "Send \(itemCount) shared items to…",
                    systemImage: "tray.and.arrow.up")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            OpenQuicklyView(store: store, open: open)
        }
    }
}
