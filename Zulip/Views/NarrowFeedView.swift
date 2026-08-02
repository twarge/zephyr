import SwiftUI
import ZulipModel

/// A cross-channel feed for the sidebar Views (Combined feed, Mentions,
/// Starred): messages from any conversation, with "#channel › topic" headers
/// that jump to the focused conversation. Never auto-marks read.
struct NarrowFeedView: View {
    let store: PerAccountStore
    let title: String
    let narrow: Narrow
    @Binding var selection: Destination?

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                MessageFeedList(
                    store: store, model: model, cache: cache,
                    headerMode: .channelAndTopic,
                    onHeaderTap: { key in
                        selection = .conversation(key)
                    })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .task {
            guard model == nil else { return }
            let list = MessageListModel(store: store, narrow: narrow)
            model = list
            await list.fetchInitial(count: 100)
        }
    }
}
