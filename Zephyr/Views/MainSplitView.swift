import AppKit
import SwiftUI
import ZulipModel

/// What the detail column shows: a DM/topic transcript, a channel's
/// interleaved message feed, a channel's topic list, or a cross-channel view.
/// Codable so each server's selection persists across launches.
enum Destination: Hashable, Codable {
    case conversation(ConversationKey)
    case channel(streamId: Int)
    case channelTopics(streamId: Int)
    case combinedFeed
    case mentions
    case starred
    case search(SearchQuery)
    case allChannels
}

/// The Messages-style main window: unified conversation sidebar + transcript.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let store: PerAccountStore
    @State private var selection: Destination?
    @State private var search: SidebarSearchModel
    @State private var showNewConversation = false

    init(store: PerAccountStore) {
        self.store = store
        _search = State(initialValue: SidebarSearchModel(store: store))
        _selection = State(initialValue: AppStateStore.selection(for: store.accountId))
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
                Button {
                    showNewConversation = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New conversation (⌘N)")
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    ForEach(model.global.accounts) { account in
                        Button {
                            Task { await model.switchAccount(account.id) }
                        } label: {
                            if account.id == model.activeAccountId {
                                Label(accountLabel(account), systemImage: "checkmark")
                            } else {
                                Text(accountLabel(account))
                            }
                        }
                    }
                    Divider()
                    SettingsLink {
                        Text("Accounts & Settings…")
                    }
                    Button("Sign Out…") {
                        Task { await model.signOutCurrent() }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
        .sheet(isPresented: $showNewConversation) {
            NewConversationSheet(store: store, selection: $selection)
        }
        .onChange(of: selection) {
            if case .conversation(let key) = selection {
                model.activeConversation = key
            } else {
                model.activeConversation = nil
            }
            AppStateStore.setSelection(selection, for: store.accountId)
        }
        .onChange(of: model.pendingDestination) {
            if let destination = model.pendingDestination {
                selection = destination
                model.pendingDestination = nil
            }
        }
        .onChange(of: badgeCount, initial: true) {
            NSApp.dockTile.badgeLabel = badgeCount > 0 ? "\(badgeCount)" : ""
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

    @AppStorage("badgePolicy") private var badgePolicy = BadgePolicy.dmsAndMentions.rawValue

    /// Badge aggregates across every connected server, not just the front one.
    private var badgeCount: Int {
        let policy = BadgePolicy(rawValue: badgePolicy) ?? .dmsAndMentions
        return model.global.stores.values.reduce(0) { total, store in
            switch policy {
            case .dmsAndMentions:
                total + store.unreads.dmCount + store.unreads.mentionIds.count
            case .allUnreads:
                total + store.unreads.totalCount
            case .none:
                total
            }
        }
    }

    private func accountLabel(_ account: Account) -> String {
        "\(account.realmName ?? account.realmURL.host() ?? "?") — \(account.email)"
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
            case .allChannels:
                AllChannelsView(store: store, selection: $selection)
            case nil:
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the sidebar."))
            }
        }
    }
}
