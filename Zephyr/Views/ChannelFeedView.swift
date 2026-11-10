import SwiftUI
import ZulipModel

/// A channel's interleaved message feed — every topic in recency order, with
/// clickable topic headers that drill into the focused topic transcript.
struct ChannelFeedView: View {
    let store: PerAccountStore
    let streamId: Int
    @Binding var selection: Destination?
    /// The window, for per-window scroll memory (FeedWarmCache).
    let scene: FeedWarmCache.Scene

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()
    @State private var scrollMemory = FeedScrollMemory()

    init(
        store: PerAccountStore, streamId: Int, selection: Binding<Destination?>,
        scene: FeedWarmCache.Scene
    ) {
        self.store = store
        self.streamId = streamId
        self.scene = scene
        _selection = selection
        // A recently viewed channel resumes its parked model, and a cold
        // one opens on its cached messages — set before the first layout
        // pass so there is no spinner frame.
        let narrow = Narrow.channel(streamId: streamId)
        if let warm = FeedWarmCache.shared.lookupOrPreview(
            narrow: narrow, store: store, scene: scene,
            makeModel: { MessageListModel(store: store, narrow: narrow) })
        {
            _model = State(initialValue: warm.model)
            _cache = State(initialValue: warm.cache)
            _scrollMemory = State(initialValue: warm.scrollMemory)
        }
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
        .serverTitled(store.channelName(streamId), store: store)
        .subtitled { unreadSubtitle(store.unreads.unreadCount(inChannel: streamId)) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(store: store, mode: .channel(streamId: streamId))
        }
        // Store-keyed: re-binds when the store instance is replaced
        // (warm-launch swap, queue rebuild).
        .task(id: ObjectIdentifier(store)) {
            let narrow = Narrow.channel(streamId: streamId)
            await FeedWarmCache.shared.bind(
                current: model, store: store, narrow: narrow, count: 100,
                warm: (cache, scrollMemory), scene: scene,
                makeModel: { MessageListModel(store: store, narrow: narrow) },
                install: { model = $0 })
        }
    }
}
