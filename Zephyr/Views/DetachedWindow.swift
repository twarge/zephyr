import SwiftUI
import ZulipModel

/// Identifies one detached window: double-clicking a sidebar entry opens its
/// view standalone (no sidebar), scoped to an account.
struct DetachedWindow: Hashable, Codable {
    var accountId: Account.ID
    var destination: Destination
}

#if os(macOS)
/// The detached window's content: the same detail views as the split view,
/// navigating within its own window (breadcrumbs, topic links, etc.).
struct DetachedWindowView: View {
    @Environment(AppModel.self) private var model
    let window: DetachedWindow

    @State private var selection: Destination?
    @State private var keys = KeyboardRouter()

    init(window: DetachedWindow) {
        self.window = window
        _selection = State(initialValue: window.destination)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let store = model.global.stores[window.accountId] {
                    detail(store: store)
                        .environment(keys)
                        .onAppear {
                            keys.store = store
                            keys.navigate = { destination in selection = destination }
                        }
                } else {
                    ContentUnavailableView(
                        "Not Connected", systemImage: "wifi.exclamationmark",
                        description: Text("This account isn't loaded."))
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    @ViewBuilder
    private func detail(store: PerAccountStore) -> some View {
        switch selection {
        case .conversation(let key):
            TranscriptView(store: store, conversation: key, selection: $selection)
                .id(key)
        case .channel(let streamId):
            ChannelFeedView(store: store, streamId: streamId, selection: $selection)
                .id(streamId)
        case .channelTopics(let streamId):
            ChannelTopicsView(store: store, streamId: streamId, selection: $selection)
                .id(streamId)
        case .recentConversations:
            RecentConversationsView(store: store, selection: $selection)
        case .combinedFeed:
            NarrowFeedView(
                store: store, title: "Combined feed", narrow: .combinedFeed,
                selection: $selection)
        case .mentions:
            NarrowFeedView(store: store, title: "Mentions", narrow: .mentions, selection: $selection)
        case .starred:
            NarrowFeedView(
                store: store, title: "Starred messages", narrow: .starred, selection: $selection)
        case .search(let query):
            NarrowFeedView(
                store: store, title: "Search: \(query.displayDescription)",
                narrow: .custom(query.narrowElements),
                useMatchHighlights: true, selection: $selection)
        case .allChannels:
            AllChannelsView(store: store, selection: $selection)
        case nil:
            ContentUnavailableView("No View", systemImage: "bubble")
        }
    }
}
#endif
