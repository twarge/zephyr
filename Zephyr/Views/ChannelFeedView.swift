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
    @State private var scrollMemory = FeedScrollMemory()

    init(store: PerAccountStore, streamId: Int, selection: Binding<Destination?>) {
        self.store = store
        self.streamId = streamId
        _selection = selection
        // A recently viewed channel resumes its parked model — set before
        // the first layout pass so there is no spinner frame.
        if let warm = FeedWarmCache.shared.lookup(
            narrow: .channel(streamId: streamId), store: store)
        {
            _model = State(initialValue: warm.model)
            _cache = State(initialValue: warm.cache)
            _scrollMemory = State(initialValue: warm.scrollMemory)
        }
    }

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
                    // Only messages actually scrolled into view are marked
                    // read — opening the channel doesn't clear its backlog.
                    marksReadOnView: true,
                    scrollMemory: scrollMemory)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .serverTitled(channelName, store: store)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(store: store, mode: .channel(streamId: streamId))
        }
        // Store-keyed: re-binds when the store instance is replaced
        // (warm-launch swap, queue rebuild).
        .task(id: ObjectIdentifier(store)) {
            // A healthy model bound to this store (warm start, or a
            // reappearing live view) needs no refetch.
            if let model, model.isBound(to: store),
               model.didInitialFetch, model.fetchError == nil
            {
                return
            }
            let narrow = Narrow.channel(streamId: streamId)
            let list = MessageListModel(store: store, narrow: narrow)
            if model == nil {
                model = list
                await list.fetchInitial(count: 100)
            } else {
                // Store swap: keep rendering the old window until the
                // replacement has content.
                await list.fetchInitial(count: 100)
                model = list
            }
            if list.fetchError == nil {
                FeedWarmCache.shared.insert(
                    model: list, cache: cache, scrollMemory: scrollMemory,
                    narrow: narrow, store: store)
            }
        }
    }
}
