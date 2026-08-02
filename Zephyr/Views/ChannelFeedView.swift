import SwiftUI
import ZulipModel

/// A channel's interleaved message feed — every topic in recency order, with
/// clickable topic headers that drill into the focused topic transcript.
struct ChannelFeedView: View {
    let store: PerAccountStore
    let streamId: Int
    @Binding var selection: Destination?

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()

    private var channelName: String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel"
    }

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                MessageFeedList(
                    store: store, model: model, cache: cache,
                    headerMode: .topicOnly,
                    onHeaderTap: { key in
                        selection = .conversation(key)
                    },
                    onNewMessages: { store.markChannelRead(streamId) })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("#\(channelName)")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    selection = .channelTopics(streamId: streamId)
                } label: {
                    Label("Topics", systemImage: "list.bullet")
                }
                .help("List this channel's topics")
            }
        }
        .task {
            guard model == nil else { return }
            let list = MessageListModel(store: store, narrow: .channel(streamId: streamId))
            model = list
            await list.fetchInitial(count: 100)
            store.markChannelRead(streamId)
        }
    }
}
