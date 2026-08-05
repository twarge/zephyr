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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(store: store, mode: .channel(streamId: streamId))
        }
        // Store-keyed: re-binds when the store instance is replaced
        // (warm-launch swap, queue rebuild).
        .task(id: ObjectIdentifier(store)) {
            let list = MessageListModel(store: store, narrow: .channel(streamId: streamId))
            model = list
            await list.fetchInitial(count: 100)
            store.markChannelRead(streamId)
        }
    }
}
