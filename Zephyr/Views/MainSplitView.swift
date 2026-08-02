import SwiftUI
import ZulipModel

/// What the detail column shows: a DM/topic transcript, a channel's
/// interleaved message feed, a channel's topic list, or a cross-channel view.
enum Destination: Hashable {
    case conversation(ConversationKey)
    case channel(streamId: Int)
    case channelTopics(streamId: Int)
    case combinedFeed
    case mentions
    case starred
    case search(SearchQuery)
}

/// The Messages-style main window: unified conversation sidebar + transcript.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let store: PerAccountStore
    @State private var selection: Destination?
    @State private var search: SidebarSearchModel

    init(store: PerAccountStore) {
        self.store = store
        _search = State(initialValue: SidebarSearchModel(store: store))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, search: search, selection: $selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            detailContent
        }
        .navigationTitle(store.realmName ?? "Zephyr")
        // Channel/topic/message links inside message content navigate in-app.
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let link = InternalLink(appURL: url) else { return .systemAction }
                switch link {
                case .channel(let streamId):
                    selection = .channel(streamId: streamId)
                case .topic(let streamId, let topic, _):
                    selection = .conversation(.topic(streamId: streamId, topic: topic))
                }
                return .handled
            })
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Text(model.global.accounts.first?.email ?? "")
                    Divider()
                    Button("Sign Out…") {
                        Task { await model.signOut() }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.isRecoveringEventStream {
                Label("Connecting…", systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.2), in: .rect)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
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
            case .combinedFeed:
                NarrowFeedView(
                    store: store, title: "Combined feed", narrow: .combinedFeed,
                    selection: $selection)
                    .id(Destination.combinedFeed)
            case .mentions:
                NarrowFeedView(
                    store: store, title: "Mentions", narrow: .mentions, selection: $selection)
                    .id(Destination.mentions)
            case .starred:
                NarrowFeedView(
                    store: store, title: "Starred messages", narrow: .starred,
                    selection: $selection)
                    .id(Destination.starred)
            case .search(let query):
                NarrowFeedView(
                    store: store, title: "Search: \(query.displayDescription)",
                    narrow: .custom(query.narrowElements),
                    useMatchHighlights: true, selection: $selection)
                    .id(query)
            case nil:
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the sidebar."))
            }
        }
    }
}
