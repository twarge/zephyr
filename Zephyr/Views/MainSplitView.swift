import SwiftUI
import ZulipModel

/// What the detail column shows: a DM/topic transcript, a channel's
/// interleaved message feed, a channel's topic list, or a cross-channel view.
/// Codable so each server's selection persists across launches.
enum Destination: Hashable, Codable {
    case conversation(ConversationKey)
    case channel(streamId: Int)
    case channelTopics(streamId: Int)
    case recentConversations
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
    @State private var newConversation: NewConversationMode?
    @State private var dropTargeted = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var keys = KeyboardRouter()
    #if os(iOS)
    @FocusState private var detailFocused: Bool
    #endif

    /// `initialSelection`/`startsWithSidebarClosed` configure secondary
    /// windows (double-clicked sidebar entries): same window, sidebar
    /// collapsed until reopened.
    init(
        store: PerAccountStore, initialSelection: Destination? = nil,
        startsWithSidebarClosed: Bool = false
    ) {
        self.store = store
        _search = State(initialValue: SidebarSearchModel(store: store))
        _selection = State(
            initialValue: initialSelection ?? AppStateStore.selection(for: store.accountId))
        _columnVisibility = State(
            initialValue: startsWithSidebarClosed ? .detailOnly : .automatic)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store, search: search, selection: $selection,
                startDirectMessage: { newConversation = .directMessage(initialUsers: []) },
                showsToolbarControls: columnVisibility != .detailOnly)
                .navigationSplitViewColumnWidth(min: 156, ideal: 156, max: 400)
        } detail: {
            detailContent
                // Files dropped anywhere in the conversation area upload via
                // the visible compose bar (nil when this view has none —
                // the drop is refused).
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty, let upload = keys.uploadFiles else { return false }
                    upload(files)
                    return true
                } isTargeted: { targeted in
                    dropTargeted = targeted
                }
                .overlay {
                    if dropTargeted && keys.uploadFiles != nil {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.tint, lineWidth: 2)
                            .background(
                                .tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                Label("Drop files to upload", systemImage: "arrow.down.doc")
                                    .font(.headline)
                                    .padding(10)
                                    .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                #if os(iOS)
                // Hardware-keyboard route: keep the detail pane focusable so
                // plain-letter shortcuts have somewhere to land; a focused
                // text field consumes its own keys first.
                .focusable()
                .focusEffectDisabled()
                .focused($detailFocused)
                .onKeyPress(phases: .down) { press in
                    handleKeyPress(press) ? .handled : .ignored
                }
                .onAppear { detailFocused = true }
                #endif
        }
        .environment(keys)
        .navigationTitle(store.realmName ?? "Zephyr")
        // Channel/topic/message links inside message content navigate in-app.
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let link = InternalLink(appURL: url) else { return .systemAction }
                switch link {
                case .channel(let streamId):
                    selection = .channel(streamId: streamId)
                case .topic(let streamId, let topic, let near):
                    let key = ConversationKey.topic(streamId: streamId, topic: topic)
                    if let near {
                        keys.highlightMessageId = near
                        if selection != .conversation(key) {
                            keys.pendingNear = (key, near)
                        }
                    }
                    selection = .conversation(key)
                }
                return .handled
            })
        .sheet(item: $newConversation) { mode in
            NewConversationSheet(store: store, selection: $selection, mode: mode)
        }
        .sheet(isPresented: Bindable(keys).showHelp) {
            ShortcutsHelpView()
        }
        .onChange(of: model.pendingFormat) {
            guard let format = model.pendingFormat else { return }
            #if os(macOS)
            guard keys.hostWindow?.isKeyWindow != false else { return }
            #endif
            model.pendingFormat = nil
            keys.applyFormat?(format)
        }
        // File → New Conversation (⌘N) arrives via the app commands; with
        // several main windows open, only the key window's copy takes it.
        .onChange(of: model.pendingNewConversation) {
            guard model.pendingNewConversation else { return }
            #if os(macOS)
            guard keys.hostWindow?.isKeyWindow != false else { return }
            #endif
            model.pendingNewConversation = false
            newConversation = .general
        }
        #if os(macOS)
        .background(WindowReader { window in
            keys.hostWindow = window
        })
        #endif
        .onAppear {
            keys.store = store
            keys.currentDestination = selection
            keys.navigate = { destination in selection = destination }
            keys.newConversation = { newConversation = .directMessage(initialUsers: []) }
            #if os(macOS)
            keys.installMonitor()
            #endif
        }
        .onDisappear {
            #if os(macOS)
            keys.removeMonitor()
            #endif
        }
        // The store is replaced on event-queue rebuild while this view (keyed
        // by account id) survives; keep the router pointed at the live one.
        .onChange(of: ObjectIdentifier(store)) {
            keys.store = store
        }
        .onChange(of: selection) {
            if case .conversation(let key) = selection {
                model.activeConversation = key
            } else {
                model.activeConversation = nil
            }
            keys.currentDestination = selection
            keys.selectedMessageId = nil
            #if os(iOS)
            detailFocused = true
            #endif
            AppStateStore.setSelection(selection, for: store.accountId)
        }
        .onChange(of: model.pendingDestination) {
            if let destination = model.pendingDestination {
                selection = destination
                model.pendingDestination = nil
            }
        }
        .onChange(of: badgeCount, initial: true) {
            Platform.setAppBadge(badgeCount)
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

    #if os(iOS)
    private func handleKeyPress(_ press: KeyPress) -> Bool {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option])
        else { return false }
        switch press.key {
        case .upArrow: return keys.handleUpArrow()
        case .downArrow: return keys.handleDownArrow()
        case .return: return keys.handleReturn()
        case .escape: return keys.handleEscape()
        default:
            guard let character = press.characters.first else { return false }
            return keys.handleCharacter(character)
        }
    }
    #endif

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
            case .recentConversations:
                RecentConversationsView(store: store, selection: $selection)
                    .id(Destination.recentConversations)
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
