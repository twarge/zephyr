import SwiftUI
import TipKit
import ZulipAPI
import ZulipModel

/// What the detail column shows: a DM/topic transcript, a channel's
/// interleaved message feed, a channel's topic list, or a cross-channel view.
/// Codable so each server's selection persists across launches.
nonisolated enum Destination: Hashable, Codable {
    case conversation(ConversationKey)
    case channel(streamId: Int)
    case channelTopics(streamId: Int)
    case recentConversations
    case drafts
    case outbox
    case reminders
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
    /// Live sidebar column width — gates the realm logo, which hides
    /// entirely when it wouldn't fit (never the overflow menu).
    @State private var sidebarWidth: CGFloat = 300
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingShareItems: [ShareInbox.PendingItem] = []
    @State private var showSharePicker = false
    /// Per-window navigation history for ⌘[ / ⌘].
    @State private var backStack: [Destination] = []
    @State private var forwardStack: [Destination] = []
    @State private var historyNavigation = false
    /// A downloaded attachment presented via Quick Look (iOS; macOS saves
    /// to Downloads instead).
    @State private var downloadPreviewURL: URL?
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
        let _ = PerfLog.render("MainSplit")
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store, search: search, selection: $selection,
                selectedAccount: $selectedAccount,
                startDirectMessage: { newConversation = .directMessage(initialUsers: []) })
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 156, ideal: 156, max: 400)
                #else
                // The iPad's system sidebars (Mail, Notes) run ~320pt;
                // the macOS-tuned 156 reads half-width there. The min stays
                // low — column minimums feed the scene's minimum size, and
                // iPadOS scales (squishes) windows resized below it.
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 420)
                // A real sidebar navigation bar (title + compose): the
                // iPadOS window controls dock into this row — without it
                // they float over a bare strip.
                .navigationTitle(store.realmName ?? "Zephyr")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Conversation", systemImage: "square.and.pencil") {
                            model.pendingNewConversation = true
                        }
                    }
                }
                #endif
                #if os(macOS)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    sidebarWidth = width
                }
                // The realm's logo sits flush against the window controls:
                // the system sidebar toggle (which would otherwise come
                // first) is removed and re-added after the logo. When the
                // sidebar is too narrow the logo hides outright rather
                // than dropping into the toolbar's overflow menu, and the
                // hidden shared background drops the glass lozenge.
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if columnVisibility != .detailOnly {
                        ToolbarItem(placement: .automatic) {
                            Button("Hide Sidebar", systemImage: "sidebar.leading") {
                                withAnimation { columnVisibility = .detailOnly }
                            }
                            .help("Hide Sidebar")
                        }
                        if sidebarWidth >= 210 {
                            ToolbarItem(placement: .automatic) {
                                RealmLogoView(store: store)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        }
                    }
                }
                #endif
        } detail: {
            detailContent
                // The toolbar belongs to the detail column: attached to the
                // split view it never reached the iPad's navigation bar.
                .toolbar { detailToolbar }
                #if !os(macOS)
                .toolbarTitleDisplayMode(.inline)
                #endif
                .popoverTip(QuickLookNavigationTip())
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
        // Reminders aren't in the register snapshot; seed them once per
        // store so message clock icons and the sidebar row can show.
        .task(id: store.accountId) { await store.refreshReminders() }
        .navigationTitle(store.realmName ?? "Zephyr")
        // Narrow links navigate in-app: rewritten links inside message
        // content, and pasted/clicked web-app URLs on ANY signed-in realm
        // (other realms hop the window like a notification click).
        .environment(
            \.openURL,
            OpenURLAction { url in
                if let link = InternalLink(appURL: url) {
                    openInternal(link, accountId: store.accountId)
                    return .handled
                }
                if let host = url.host()?.lowercased() {
                    for account in model.global.accounts
                    where account.realmURL.host()?.lowercased() == host {
                        if let link = InternalLink.parse(
                            href: url.absoluteString, realmURL: account.realmURL) {
                            openInternal(link, accountId: account.id)
                            return .handled
                        }
                        // Attachment links need our auth — the browser
                        // would hit the login wall. Download in-app.
                        if url.path().contains("/user_uploads/"),
                           let connection = model.global.stores[account.id]?.connection {
                            downloadAttachment(url: url, connection: connection)
                            return .handled
                        }
                        break  // The realm's, but nothing we handle → browser.
                    }
                }
                return .systemAction
            })
        .quickLookPreview($downloadPreviewURL)
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
            OpenQuicklyTip().invalidate(reason: .actionPerformed)
            showOpenQuickly = true
        }
        // ⌘[ / ⌘]: this window's navigation history.
        .onChange(of: selection) { old, _ in
            if historyNavigation {
                historyNavigation = false
            } else if let old {
                backStack.append(old)
                if backStack.count > 50 {
                    backStack.removeFirst()
                }
                forwardStack.removeAll()
            }
        }
        .onChange(of: model.pendingCommand) {
            consumeCommand()
        }
        .onChange(of: model.pendingHistoryStep) {
            guard let step = model.pendingHistoryStep else { return }
            #if os(macOS)
            guard keys.hostWindow?.isKeyWindow != false else { return }
            #endif
            model.pendingHistoryStep = nil
            navigateHistory(step)
        }
        .sheet(isPresented: $showOpenQuickly) {
            OpenQuicklyView(store: store) { destination in
                selection = destination
            }
        }
        // Share-extension inbox: offer the destination picker when items
        // arrive (app activation, or the extension's zephyr:// nudge).
        .onChange(of: scenePhase, initial: true) {
            checkShareInbox()
        }
        .onOpenURL { url in
            if url.scheme == "zephyr" {
                checkShareInbox()
            }
        }
        .sheet(isPresented: $showSharePicker, onDismiss: { model.sharePickerActive = false }) {
            SharePickerSheet(store: store, itemCount: pendingShareItemCount) { destination in
                model.pendingComposeSeed = pendingShareItems
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
            WidgetSummaryWriter.update(global: model.global)
        }
        // Handoff: the current conversation continues on another device.
        .userActivity("com.twarge.zephyr.conversation", isActive: selection != nil) { activity in
            activity.title = store.realmName ?? "Zephyr"
            activity.isEligibleForHandoff = true
            if let selection,
               let data = try? JSONEncoder().encode(
                StoredWindowState(account: store.accountId, destination: selection)) {
                activity.addUserInfoEntries(from: ["state": data])
            }
        }
        .onContinueUserActivity("com.twarge.zephyr.conversation") { activity in
            guard let data = activity.userInfo?["state"] as? Data,
                  let stored = try? JSONDecoder().decode(StoredWindowState.self, from: data)
            else { return }
            // Routed like a notification click: the key window hops
            // accounts if needed, then navigates.
            model.pendingDestination = PendingDestination(
                account: stored.account, destination: stored.destination)
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
            #if os(macOS)
            // With the system sidebar toggle removed (the realm logo owns
            // the sidebar section's leading slot), a collapsed sidebar
            // would strand the user — this stand-in appears only then.
            if columnVisibility == .detailOnly {
                ToolbarItem(placement: .navigation) {
                    Button("Show Sidebar", systemImage: "sidebar.leading") {
                        withAnimation { columnVisibility = .automatic }
                    }
                    .help("Show Sidebar")
                }
            }
            #endif
            // "Up" from a topic view to its channel: the channel's own
            // glyph in its color.
            if case .conversation(.topic(let streamId, _)) = selection {
                ToolbarItem(placement: .navigation) {
                    Button {
                        selection = .channel(streamId: streamId)
                    } label: {
                        Image(systemName: channelGlyph(streamId))
                            .foregroundStyle(channelColor(streamId))
                    }
                    .help("Go to #\(channelName(streamId))")
                }
            }
            // The server menu lives in the main toolbar. macOS hides it
            // with a single server (Settings lives in the app menu); iOS
            // keeps it — it's the only road to Settings there.
            #if os(macOS)
            if model.global.enabledAccounts.count > 1 {
                ToolbarItem(placement: .automatic) {
                    ServerMenu(store: store, selectedAccount: $selectedAccount)
                        .popoverTip(PerWindowServersTip())
                }
            }
            #else
            ToolbarItem(placement: .automatic) {
                ServerMenu(store: store, selectedAccount: $selectedAccount)
                    .popoverTip(PerWindowServersTip())
            }
            #endif
            if store.isRecoveringEventStream {
                ToolbarItem(placement: .automatic) {
                    // A broken chain link (SF Symbols has none): two
                    // separated link halves on the diagonal, in a standard
                    // round filled badge like the other circular controls.
                    ZStack {
                        Circle()
                            .fill(.yellow)
                        VStack(spacing: 2) {
                            Capsule()
                                .strokeBorder(.black.opacity(0.55), lineWidth: 1.6)
                                .frame(width: 7, height: 9)
                            Capsule()
                                .strokeBorder(.black.opacity(0.55), lineWidth: 1.6)
                                .frame(width: 7, height: 9)
                        }
                        .rotationEffect(.degrees(-45))
                    }
                    .frame(width: 21, height: 21)
                    .help("Connection lost — reconnecting…")
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

    private func navigateHistory(_ step: Int) {
        historyNavigation = true
        if step < 0 {
            guard let previous = backStack.popLast() else {
                historyNavigation = false
                return
            }
            if let selection {
                forwardStack.append(selection)
            }
            selection = previous
        } else {
            guard let next = forwardStack.popLast() else {
                historyNavigation = false
                return
            }
            if let selection {
                backStack.append(selection)
            }
            selection = next
        }
    }

    /// Downloads an attachment through the account's authenticated session:
    /// macOS saves into Downloads and reveals it; iOS presents Quick Look
    /// (whose share sheet covers "Save to Files").
    private func downloadAttachment(url: URL, connection: ApiConnection) {
        Task {
            guard let (data, response) = await fetchMedia(
                path: url.absoluteString, connection: connection) else { return }
            let filename = response.suggestedFilename
                ?? url.lastPathComponent.removingPercentEncoding
                ?? "attachment"
            #if os(macOS)
            guard let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask).first else { return }
            var destination = downloads.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                let base = (filename as NSString).deletingPathExtension
                let ext = (filename as NSString).pathExtension
                destination = downloads.appendingPathComponent(
                    "\(base)-\(Int(Date.now.timeIntervalSince1970))"
                        + (ext.isEmpty ? "" : ".\(ext)"))
            }
            do {
                try data.write(to: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                // Sandbox without the Downloads entitlement, disk full…
            }
            #else
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            try? data.write(to: temp)
            downloadPreviewURL = temp
            #endif
        }
    }

    /// Routes a parsed narrow link: directly when it's this window's
    /// account, via the pending-destination hop otherwise.
    private func openInternal(_ link: InternalLink, accountId: Account.ID) {
        let selfUserId = model.global.accounts
            .first { $0.id == accountId }?.userId ?? store.selfUserId
        let (destination, near) = link.destination(
            selfUserId: selfUserId, store: model.global.stores[accountId])
        if accountId == store.accountId {
            if let near, case .conversation(let key) = destination {
                keys.highlightMessageId = near
                if selection != .conversation(key) {
                    keys.pendingNear = (key, near)
                }
            }
            selection = destination
        } else {
            model.pendingDestination = PendingDestination(
                account: accountId, destination: destination, near: near)
        }
    }

    /// Menu-bar commands land in the key window; message actions route to
    /// the selected row through the keyboard router.
    private func consumeCommand() {
        guard let command = model.pendingCommand else { return }
        #if os(macOS)
        guard keys.hostWindow?.isKeyWindow != false else { return }
        #endif
        model.pendingCommand = nil
        switch command {
        case .navigate(let destination):
            selection = destination
        case .reply:
            _ = keys.handleCharacter("r")
        case .editMessage:
            _ = keys.handleCharacter("e")
        case .toggleStar:
            _ = keys.handleCharacter("*")
        case .find:
            _ = keys.handleCharacter("/")
        case .replyQuoting:
            requestMessageAction(.replyQuoting)
        case .copyReference:
            requestMessageAction(.copyReference)
        case .translate:
            requestMessageAction(.translate)
        case .moveToTopic:
            requestMessageAction(.moveToTopic)
        case .forward:
            requestMessageAction(.forward)
        case .markUnreadFromHere:
            requestMessageAction(.markUnreadFromHere)
        case .markConversationRead:
            if case .conversation(let key) = selection {
                store.markConversationRead(key)
            }
        case .reload:
            if let feed = keys.activeFeed {
                Task { await feed.fetchInitial() }
            }
        case .shortcutsHelp:
            keys.showHelp = true
        }
    }

    private func requestMessageAction(_ action: MessageActionRequest.Action) {
        guard let id = keys.selectedMessageId else { return }
        keys.messageActionRequest = MessageActionRequest(messageId: id, action: action)
    }

    private func channelName(_ streamId: Int) -> String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel"
    }

    private func channelGlyph(_ streamId: Int) -> String {
        let channel = store.channels[streamId]
        if channel?.inviteOnly == true { return "lock.fill" }
        if channel?.isWebPublic == true { return "globe" }
        return "number"
    }

    private func channelColor(_ streamId: Int) -> Color {
        store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    private var pendingShareItemCount: Int {
        pendingShareItems.reduce(0) {
            $0 + $1.files.count + ($1.text == nil ? 0 : 1)
        }
    }

    private func checkShareInbox() {
        guard scenePhase == .active, !model.sharePickerActive else { return }
        #if os(macOS)
        guard keys.hostWindow?.isKeyWindow != false else { return }
        #endif
        let items = ShareInbox.pendingItems()
        guard !items.isEmpty else { return }
        model.sharePickerActive = true
        pendingShareItems = items
        showSharePicker = true
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
        if let near = pending.near, case .conversation(let key) = pending.destination {
            keys.highlightMessageId = near
            if selection != .conversation(key) {
                keys.pendingNear = (key, near)
            }
        }
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
                RecentConversationsView(store: store, search: search, selection: $selection)
                    .id(Destination.recentConversations)
            case .drafts:
                DraftsView(store: store, selection: $selection)
                    .id(Destination.drafts)
            case .outbox:
                OutboxView(store: store, selection: $selection)
                    .id(Destination.outbox)
            case .reminders:
                RemindersView(store: store, selection: $selection)
                    .id(Destination.reminders)
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
                AllChannelsView(store: store, search: search, selection: $selection)
            case nil:
                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a conversation from the sidebar."))
                    .overlay(alignment: .top) {
                        TipView(OpenQuicklyTip())
                            .frame(maxWidth: 380)
                            .padding()
                    }
            }
        }
    }
}

/// The window's server menu: switching (⌘1–⌘9), account management, sign
/// out. One per window — it changes only this window's server.
struct ServerMenu: View {
    let store: PerAccountStore
    @Binding var selectedAccount: Account.ID?

    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        Menu {
            ForEach(
                Array(model.global.enabledAccounts.prefix(9).enumerated()), id: \.element.id
            ) { index, account in
                Button {
                    selectedAccount = account.id
                } label: {
                    if account.id == store.accountId {
                        Label(accountLabel(account), systemImage: "checkmark")
                    } else {
                        Text(accountLabel(account))
                    }
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            ForEach(model.global.enabledAccounts.dropFirst(9)) { account in
                Button {
                    selectedAccount = account.id
                } label: {
                    if account.id == store.accountId {
                        Label(accountLabel(account), systemImage: "checkmark")
                    } else {
                        Text(accountLabel(account))
                    }
                }
            }
            Divider()
            #if os(macOS)
            SettingsLink {
                Text("Accounts & Settings…")
            }
            #else
            Button("Accounts & Settings…") {
                showSettings = true
            }
            #endif
            Button("Sign Out of This Server…") {
                Task { await model.signOut(accountId: store.accountId) }
            }
        } label: {
            Text(store.realmName
                ?? store.connection.realmURL.host() ?? "Server")
                .font(.callout.weight(.medium))
        }
        .help("Servers and accounts (⌘1–⌘9 switch this window)")
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(model)
        }
    }

    private func accountLabel(_ account: Account) -> String {
        "\(account.realmName ?? account.realmURL.host() ?? "?") — \(account.email)"
    }
}
