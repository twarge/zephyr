import SwiftUI
import ZulipModel

/// A cross-channel feed for the sidebar Views (Combined feed, Mentions,
/// Starred): messages from any conversation, with "#channel › topic" headers
/// that jump to the focused conversation. Never auto-marks read.
struct NarrowFeedView: View {
    let store: PerAccountStore
    let title: String
    let narrow: Narrow
    var useMatchHighlights = false
    @Binding var selection: Destination?

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                if let error = model.fetchError, model.messages.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load Messages",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription))
                } else {
                    MessageFeedList(
                        store: store, model: model, cache: cache,
                        headerMode: .channelAndTopic,
                        useMatchHighlights: useMatchHighlights,
                        onHeaderTap: { key in
                            selection = .conversation(key)
                        },
                        marksReadOnView: narrow == .combinedFeed)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        // Store-keyed: re-binds when the store instance is replaced
        // (warm-launch swap, queue rebuild).
        .task(id: ObjectIdentifier(store)) {
            let list = MessageListModel(store: store, narrow: narrow)
            model = list
            await list.fetchInitial(count: 100)
        }
    }
}
