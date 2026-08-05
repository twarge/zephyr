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
    /// The enclosing window's account — the sidebar's server switcher
    /// writes here, changing only this window.
    @Binding var selectedAccount: Account.ID?
    @State private var selection: Destination?
    @State private var search: SidebarSearchModel
    @State private var newConversation: NewConversationMode?
    @State private var showOpenQuickly = false
    @State private var dropTargeted = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    /// True while the narrow-window watcher hid the sidebar (so growing
    /// the window restores it; a user's manual collapse is left alone).
    @State private var autoCollapsedSidebar = false
    @State private var keys = KeyboardRouter()
    /// Per-window navigation state, restored with the window by the system
    /// (frames and window existence restore automatically; this brings the
    /// in-window destination along).
    @SceneStorage("windowDestination") private var storedDestination = ""

    private struct StoredWindowState: Codable {
        var account: UUID
        var destination: Destination
    }
    #if os(iOS)
    @FocusState private var detailFocused: Bool
    #endif

    /// `initialSelection`/`startsWithSidebarClosed` configure secondary
    /// windows (double-clicked sidebar entries): same window, sidebar
    /// collapsed until reopened.
    init(
        store: PerAccountStore, selectedAccount: Binding<Account.ID?>,
        initialSelection: Destination? = nil,
        startsWithSidebarClosed: Bool = false
    ) {
        self.store = store
        _selectedAccount = selectedAccount
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
                selectedAccount: $selectedAccount,
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
        #if os(macOS)
        // macOS never adapts the split view to narrow windows on its own:
        // squeeze the window and the sidebar auto-collapses to detail-only
        // (and re-expands on grow, but only if this auto-collapse hid it —
        // a manual collapse stays put). The two thresholds are hysteresis.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            if width < 500, columnVisibility != .detailOnly {
                autoCollapsedSidebar = true
                withAnimation { columnVisibility = .detailOnly }
            } else if width >= 560, autoCollapsedSidebar {
                autoCollapsedSidebar = false
                withAnimation { columnVisibility = .automatic }
            }
        }
        #endif
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
        .onChange(of: model.pendingOpenQuickly) {
            guard model.pendingOpenQuickly else { return }
            #if os(macOS)
            guard keys.hostWindow?.isKeyWindow != false else { return }
            #endif
            model.pendingOpenQuickly = false
            showOpenQuickly = true
        }
        .sheet(isPresented: $showOpenQuickly) {
            OpenQuicklyView(store: store) { destination in
                selection = destination
            }
        }
        #if os(macOS)
        .background(WindowReader { window in
            keys.hostWindow = window
        })
        #endif
        .onAppear {
            // A system-restored window resumes at its last destination
            // (fresh windows have no stored state and keep their initial
            // selection).
            if let data = storedDestination.data(using: .utf8),
               let stored = try? JSONDecoder().decode(StoredWindowState.self, from: data),
               stored.account == store.accountId {
                selection = stored.destination
            }
            keys.store = store
            keys.currentDestination = selection
            keys.navigate = { destination in selection = destination }
            keys.newConversation = { newConversation = .directMessage(initialUsers: []) }
            #if os(macOS)
            keys.installMonitor()
            #endif
            // A notification click that hopped this window to another
            // server lands here after the account switch.
            consumePendingDestination()
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
            model.ensureDraftSync(store.accountId)
        }
        .onChange(of: selection) {
            if case .conversation(let key) = selection {
                model.activeConversation =
                    ActiveConversation(account: store.accountId, key: key)
            } else if model.activeConversation?.account == store.accountId {
                model.activeConversation = nil
            }
            keys.currentDestination = selection
            keys.selectedMessageId = nil
            #if os(iOS)
            detailFocused = true
            #endif
            // Open Quickly's recency: any channel-scoped destination counts
            // as a visit.
            let visitedChannel: Int? = switch selection {
            case .channel(let id), .channelTopics(let id): id
            case .conversation(.topic(let id, _)): id
            default: nil
            }
            if let visitedChannel {
                AppStateStore.noteChannelVisit(visitedChannel, for: store.accountId)
            }
            AppStateStore.setSelection(selection, for: store.accountId)
            if let selection,
               let data = try? JSONEncoder().encode(
                StoredWindowState(account: store.accountId, destination: selection)),
               let string = String(data: data, encoding: .utf8) {
                storedDestination = string
            }
        }
        .onChange(of: model.pendingDestination) {
            consumePendingDestination()
        }
        .onChange(of: badgeCount, initial: true) {
            Platform.setAppBadge(badgeCount)
        }
        .toolbar {
            if store.isRecoveringEventStream {
                ToolbarItem(placement: .automatic) {
                    // "Broken link" — SF Symbols has no link.slash, so the
                    // slash is drawn over the link glyph.
                    Image(systemName: "link")
                        .foregroundStyle(.yellow)
                        .overlay {
                            Rectangle()
                                .fill(.yellow)
                                .frame(width: 1.5, height: 17)
                                .rotationEffect(.degrees(45))
                        }
                        .help("Connection lost — reconnecting…")
                }
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

    /// Notification-click navigation: only for this window's account, and
    /// only in the key window (unless no window is key — a click that
    /// arrives while the app is inactive — where the first taker wins).
    private func consumePendingDestination() {
        guard let pending = model.pendingDestination,
              pending.account == store.accountId else { return }
        #if os(macOS)
        if keys.hostWindow?.isKeyWindow == false && NSApp.keyWindow != nil { return }
        #endif
        model.pendingDestination = nil
        selection = pending.destination
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
