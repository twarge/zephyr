import SwiftUI
import TipKit
import ZulipAPI
import ZulipModel

/// The Messages-style main window: unified conversation sidebar + transcript.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    let store: PerAccountStore
    /// The enclosing window's account — the sidebar's server switcher
    /// writes here, changing only this window.
    @Binding var selectedAccount: Account.ID?
    @State private var selection: Destination?
    /// One-shot: the message a freshly opened window lands on.
    @State private var initialNear: Int?
    @State private var search: SidebarSearchModel
    @State private var newConversation: NewConversationMode?
    @State private var showOpenQuickly = false
    @State private var dropTargeted = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    /// The column a collapsed split shows (iPhone, a folded Duo, a narrow
    /// iPad window): the root list at launch, then whatever is open — so
    /// folding a Duo mid-conversation keeps the conversation on screen.
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    /// Live sidebar column width — gates the realm logo, which hides
    /// entirely when it wouldn't fit (never the overflow menu). The first
    /// frame's toolbar is laid out before the column is measured, so a
    /// fixed default showed the wide logo for a frame before the real
    /// width swapped it for the icon, rebuilding the toolbar. A restored
    /// window has its own width; a new one opens at the width the last
    /// one had, as its column does.
    @SceneStorage("sidebarWidth") private var storedSidebarWidth: Double = 0
    private static let lastSidebarWidthKey = "lastSidebarWidth"

    private var sidebarWidth: CGFloat {
        if storedSidebarWidth > 0 { return storedSidebarWidth }
        let last = UserDefaults.standard.double(forKey: Self.lastSidebarWidthKey)
        return last > 0 ? last : 300
    }

    /// The column's latest measured width. A box, applied only once the
    /// window is up: a window's opening layout measures the column at its
    /// minimum (144) before the restored width (223.5) lands, and taking
    /// that pass hid the logo, then put it back.
    private final class SidebarMeasure {
        var width: CGFloat?
        var windowShown = false
    }
    @State private var sidebarMeasure = SidebarMeasure()

    private func storeSidebarWidth(_ width: CGFloat) {
        // Edges only: a SceneStorage write re-renders.
        guard abs(storedSidebarWidth - Double(width)) >= 0.5 else { return }
        storedSidebarWidth = Double(width)
        UserDefaults.standard.set(Double(width), forKey: Self.lastSidebarWidthKey)
    }
    /// The iOS toolbar gear's Settings sheet.
    @State private var showSettingsSheet = false
    #if os(macOS)
    /// Staged sharing-picker content (the selected attachment's file, or
    /// the selected message as text); the toolbar anchor presents and
    /// clears it.
    @State var macShareItems: [Any]?
    /// A failed File → Export Selected… write, shown as an alert.
    @State var exportError: String?
    #else
    /// Staged share-sheet content (the selected attachment's file, or the
    /// selected message as text); presented while non-nil.
    @State var sharePayload: SharePayload?
    #endif

    /// Whether RealmLogoView will render an actual image (uploaded logo
    /// or realm icon) rather than the initial-letter stand-in.
    private var hasRealmImage: Bool {
        store.realmLogoPath(dark: false) != nil || store.realmIconUrl != nil
    }

    /// Destinations whose view carries the message composer (compact
    /// width hides search on those — the compose field owns the bottom).
    private var selectionHasComposer: Bool {
        switch selection {
        case .conversation, .channel: true
        default: false
        }
    }
    #if !os(macOS)
    /// Mailbox-like views wear Mail's large title, which collapses into
    /// the bar as the list scrolls; a transcript (Mail's message view)
    /// and search results stay inline.
    private var detailTitleDisplayMode: ToolbarTitleDisplayMode {
        switch selection {
        case .conversation, .search, nil: .inline
        default: .large
        }
    }
    #endif
    /// The toolbar's connection-lost badge. The store is "recovering" for
    /// the second or so every launch spends registering (the cached store
    /// renders meanwhile) and through each queue rebuild — no reason to
    /// flash a warning, and adding then removing the item re-laid out the
    /// whole toolbar. It shows once recovery has lasted a while.
    @State private var connectionLost = false

    private struct ConnectionWatch: Hashable {
        var store: ObjectIdentifier
        var recovering: Bool
    }

    /// True while the narrow-window watcher hid the sidebar (so growing
    /// the window restores it; a user's manual collapse is left alone).
    @State private var autoCollapsedSidebar = false
    @State var keys = KeyboardRouter()
    /// Per-window navigation state, restored with the window by the system
    /// (frames and window existence restore automatically; this brings the
    /// in-window destination along).
    @SceneStorage("windowDestination") private var storedDestination = ""

    private struct StoredWindowState: Codable {
        var account: UUID
        var destination: Destination
    }
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("combinedShowsMuted") private var combinedShowsMuted = false
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var pendingShareItems: [ShareInbox.PendingItem] = []
    @State private var showSharePicker = false
    /// Per-window navigation history for ⌘[ / ⌘].
    @State private var backStack: [Destination] = []
    @State private var forwardStack: [Destination] = []
    @State private var historyNavigation = false
    /// A downloaded attachment presented via Quick Look (iOS; macOS saves
    /// to Downloads instead).
    @State var downloadPreviewURL: URL?
    /// In-flight attachment downloads: drives the toolbar progress ring,
    /// and repeat clicks on a URL already downloading are ignored.
    @State var downloads: [AttachmentDownload] = []
    #if os(iOS)
    @FocusState private var detailFocused: Bool
    #endif

    /// `initialSelection`/`startsWithSidebarClosed` configure secondary
    /// windows (double-clicked sidebar entries): same window, sidebar
    /// collapsed until reopened. `initialNear` lands a conversation
    /// selection on a message (a jump opened in a new window).
    init(
        store: PerAccountStore, selectedAccount: Binding<Account.ID?>,
        initialSelection: Destination? = nil,
        initialNear: Int? = nil,
        startsWithSidebarClosed: Bool = false
    ) {
        self.store = store
        _selectedAccount = selectedAccount
        _search = State(initialValue: SidebarSearchModel(store: store))
        _selection = State(
            initialValue: initialSelection ?? AppStateStore.selection(for: store.accountId) ?? .summary)
        _initialNear = State(initialValue: initialNear)
        _columnVisibility = State(
            initialValue: startsWithSidebarClosed ? .detailOnly : .automatic)
    }

    var body: some View {
        stageThree
    }

    private var stageOne: some View {
        let _ = PerfLog.render("MainSplit")
        let _ = PerfLog.mark("MainSplit body")
        return NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            SidebarView(
                store: store, search: search, selection: $selection,
                selectedAccount: $selectedAccount,
                startDirectMessage: { newConversation = .directMessage(initialUsers: []) })
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 156, ideal: 234, max: 400)
                #else
                // The iPad's system sidebars (Mail, Notes) run ~320pt;
                // the macOS-tuned 234 reads narrow there. No maximum:
                // a bent Duo's split view widens the sidebar to the crease
                // (~475pt), and a cap would hold it short.
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
                // A real sidebar navigation bar: the iPadOS window controls
                // dock into this row — without it they float over a bare
                // strip. The realm's logo fills the bar (no glass lozenge,
                // no redundant name when an image will render).
                .navigationTitle(
                    hasRealmImage ? "" : (store.realmName ?? "Zephyr"))
                // Compact (iPhone / narrow iPad): the root list IS the app,
                // so search, Settings, and compose ride its bar; regular
                // width leaves them to the detail bar (Settings only
                // there loses its home — the gear lives here on compact).
                .modifier(CompactSidebarSearch(
                    search: search, selection: $selection,
                    isCompact: horizontalSizeClass == .compact))
                .toolbar {
                    #if os(visionOS)
                    // No shared toolbar background to hide on visionOS.
                    ToolbarItem(placement: .topBarLeading) {
                        RealmLogoView(store: store, height: 30)
                    }
                    #else
                    ToolbarItem(placement: .topBarLeading) {
                        RealmLogoView(store: store, height: 30)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    #endif
                    if horizontalSizeClass == .compact {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Settings", systemImage: "gear") {
                                showSettingsSheet = true
                            }
                        }
                        // Messages-style bottom bar: the expanded search
                        // field with the write button beside it.
                        #if os(visionOS)
                        // ToolbarSpacer doesn't exist on visionOS.
                        DefaultToolbarItem(kind: .search, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            Button("New Conversation", systemImage: "square.and.pencil") {
                                model.pendingNewConversation = true
                            }
                        }
                        #else
                        DefaultToolbarItem(kind: .search, placement: .bottomBar)
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            Button("New Conversation", systemImage: "square.and.pencil") {
                                model.pendingNewConversation = true
                            }
                        }
                        #endif
                    }
                }
                .sheet(isPresented: $showSettingsSheet) {
                    SettingsView()
                        .environment(model)
                        .presentationDragIndicator(.visible)
                }
                #endif
                #if os(macOS)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    sidebarMeasure.width = width
                    if sidebarMeasure.windowShown { storeSidebarWidth(width) }
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
                        // ~150pt reserves the window controls + toggle; the
                        // view fits-or-falls-back (wide mark → square icon)
                        // within what's left, and below icon size the item
                        // drops outright — never the ">>" overflow submenu.
                        if sidebarWidth - 150 >= 20 {
                            ToolbarItem(placement: .automatic) {
                                RealmLogoView(store: store, maxWidth: sidebarWidth - 150)
                                    // The logo is inert decoration, but a toolbar
                                    // item still swallows mouse-downs — this hands
                                    // them back to window dragging.
                                    .gesture(WindowDragGesture())
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
                .toolbarTitleDisplayMode(detailTitleDisplayMode)
                // The sidebar-filtering search field renders here — the
                // main view's toolbar, not the sidebar's (see
                // detailToolbar's placement per size class).
                .modifier(DetailSearchField(
                    search: search, selection: $selection,
                    suppressWhenCompactComposer: selectionHasComposer))
                #endif
                .popoverTip(QuickLookNavigationTip())
                .actionFailureBanner(store: store)
                .signedOutBanner(store: store)
                #if !os(macOS)
                .sheet(item: $sharePayload) { payload in
                    ShareActivityView(items: payload.items) { sharePayload = nil }
                        .presentationDetents([.medium, .large])
                }
                #endif
                // Media dropped anywhere in the conversation area uploads via
                // the visible compose bar, and dragged links insert into its
                // draft (both nil when this view has neither — the drop is
                // refused).
                .mediaDropTarget(
                    isTargeted: $dropTargeted,
                    canAccept: { keys.uploadFiles != nil },
                    onText: { keys.insertIntoCompose?($0) }
                ) { files in
                    keys.uploadFiles?(files)
                }
                .overlay {
                    if dropTargeted && keys.uploadFiles != nil {
                        dropHighlightBorder
                            .concentricBackground(.tint.opacity(0.06), minimumRadius: 10)
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
                .onAppear {
                    detailFocused = true
                    // → in the sidebar returns here (macOS registers its
                    // own in SidebarView).
                    keys.focusMessages = { detailFocused = true }
                }
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
        .task(id: ConnectionWatch(
            store: ObjectIdentifier(store), recovering: store.isRecoveringEventStream)
        ) {
            guard store.isRecoveringEventStream else {
                connectionLost = false
                return
            }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { connectionLost = true }
        }
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
                // A link straight to a file (archive, doc, data…): the
                // browser would only save it — download in-app instead.
                // Unknown extensions ask the server which it is; pages and
                // browser-rendered media still open in the browser.
                switch FileLink.classify(url) {
                case .download:
                    downloadAttachment(url: url, connection: store.connection)
                    return .handled
                case .ambiguous:
                    let connection = store.connection
                    Task {
                        if await Self.sniffIsFile(url) {
                            downloadAttachment(url: url, connection: connection)
                        } else {
                            Platform.openExternalURL(url)
                        }
                    }
                    return .handled
                case .page:
                    return .systemAction
                }
            })
        .quickLookPreview($downloadPreviewURL)
    }

    // The body chain is split into stages (body → stageTwo → stageThree):
    // as one expression it exceeded the type checker's budget on the iOS
    // build, with the timeout landing on whichever closure the checker
    // happened to be inside.
    private var stageTwo: some View {
        stageOne
        .sheet(item: $newConversation) { mode in
            NewConversationSheet(store: store, selection: $selection, mode: mode)
                // Its editor registers for ⌘] / ⌘[ list indenting.
                .environment(keys)
                #if !os(macOS)
                .presentationDragIndicator(.visible)
                .presentationDetents([.medium, .large])
                #endif
        }
        .sheet(isPresented: Bindable(keys).showHelp) {
            ShortcutsHelpView()
        }
        .onChange(of: model.pendingFormat) {
            consumeFormat()
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
            consumeHistoryStep()
        }
        .sheet(isPresented: $showOpenQuickly) {
            OpenQuicklyView(store: store) { destination in
                selection = destination
            }
        }
    }

    private var stageThree: some View {
        stageTwo
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
        // The share extension's Darwin ping: on iPad, a share made in Slide
        // Over or Split View lands while this app is already active.
        .onReceive(NotificationCenter.default.publisher(for: ShareInboxSignal.changed)) { _ in
            checkShareInbox()
        }
        .sheet(isPresented: $showSharePicker, onDismiss: { model.sharePickerActive = false }) {
            SharePickerSheet(store: store, itemCount: pendingShareItemCount) { destination in
                model.pendingComposeSeed = pendingShareItems
                selection = destination
            }
        }
        #if os(macOS)
        .alert(
            "Export Failed",
            isPresented: Binding(
                get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .background(WindowReader { window in
            keys.hostWindow = window
            if window != nil, !sidebarMeasure.windowShown {
                sidebarMeasure.windowShown = true
                if let width = sidebarMeasure.width { storeSidebarWidth(width) }
            }
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
            } else if let near = initialNear, case .conversation(let key) = selection {
                keys.highlightMessageId = near
                keys.pendingNear = (key, near)
            }
            initialNear = nil
            // The opening selection never passes through onChange.
            noteActiveReading()
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
        .task {
            await navigateForPerfHarnessIfRequested()
        }
        // The store is replaced on event-queue rebuild while this view (keyed
        // by account id) survives; keep the router pointed at the live one.
        .onChange(of: ObjectIdentifier(store)) {
            keys.store = store
            search.store = store
            model.ensureDraftSync(store.accountId)
        }
        // Single-call closures: inline bodies here pushed the whole body
        // chain past the type checker's budget on the iOS build.
        .onChange(of: selection) {
            selectionChanged()
        }
        .onChange(of: model.pendingDestination) {
            consumePendingDestination()
        }
        // Handoff: the current conversation continues on another device.
        .userActivity("com.twarge.zephyr.conversation", isActive: selection != nil) { activity in
            configureHandoff(activity)
        }
        .onContinueUserActivity("com.twarge.zephyr.conversation") { activity in
            continueHandoff(activity)
        }
    }

    /// Perf harness navigation (`make perf` plus `-perfAutoScroll YES`):
    /// the restored selection may not be a channel feed, so open the
    /// busiest cached channel for the feed's auto-scroll pass — then put
    /// the persisted selection and recents back, so the run leaves the
    /// user's restored state untouched. No-op unless both flags are set.
    private func navigateForPerfHarnessIfRequested() async {
        guard PerfLog.enabled,
              UserDefaults.standard.bool(forKey: "perfAutoScroll") else { return }
        if case .channel? = selection { return }  // Already a channel feed.
        let savedSelection = AppStateStore.selection(for: store.accountId)
        let savedRecents = AppStateStore.recentChannels(for: store.accountId)
        let savedWindowState = storedDestination
        // Wait out the launch restore so the cache can nominate a channel.
        for _ in 0..<40 {
            if store.messages.count >= 100 { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let counts = store.messages.values.reduce(into: [Int: Int]()) { acc, message in
            if let streamId = message.streamId, store.subscriptions[streamId] != nil {
                acc[streamId, default: 0] += 1
            }
        }
        guard let busiest = counts.max(by: { $0.value < $1.value })?.key else {
            print("perf autoscroll: no cached channel to open")
            return
        }
        print("perf autoscroll: opening streamId=\(busiest) (\(counts[busiest] ?? 0) cached)")
        selection = .channel(streamId: busiest)
        // selectionChanged persists the perf selection on the next update
        // tick; put the user's stored state back once that has happened.
        try? await Task.sleep(for: .seconds(1))
        AppStateStore.setSelection(savedSelection, for: store.accountId)
        UserDefaults.standard.set(
            savedRecents, forKey: "recentChannels-\(store.accountId.uuidString)")
        // The window's scene snapshot must not resurrect the perf channel
        // on the user's next launch either.
        storedDestination = savedWindowState
    }

    /// What this window is reading, for banner suppression and sounds.
    private func noteActiveReading() {
        if case .conversation(let key) = selection {
            model.activeConversation =
                ActiveConversation(account: store.accountId, key: key)
        } else if model.activeConversation?.account == store.accountId {
            model.activeConversation = nil
        }
        if case .channel(let streamId) = selection {
            model.activeChannel = ActiveChannel(account: store.accountId, streamId: streamId)
        } else if model.activeChannel?.account == store.accountId {
            model.activeChannel = nil
        }
    }

    private func selectionChanged() {
        noteActiveReading()
        keys.currentDestination = selection
        keys.selectedMessageId = nil
        #if os(iOS)
        detailFocused = true
        #endif
        // Collapsed, the split tracks this itself; expanded it doesn't, so
        // a selection made at full width must say where a collapse lands.
        preferredCompactColumn = selection == nil ? .sidebar : .detail
        // Open Quickly's recency: any channel-scoped destination counts
        // as a visit.
        if let visitedChannel = visitedChannelId(for: selection) {
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

    private func configureHandoff(_ activity: NSUserActivity) {
        activity.title = store.realmName ?? "Zephyr"
        activity.isEligibleForHandoff = true
        if let selection,
           let data = try? JSONEncoder().encode(
            StoredWindowState(account: store.accountId, destination: selection)) {
            activity.addUserInfoEntries(from: ["state": data])
        }
    }

    /// Routed like a notification click: the key window hops accounts if
    /// needed, then navigates.
    private func continueHandoff(_ activity: NSUserActivity) {
        guard let data = activity.userInfo?["state"] as? Data,
              let stored = try? JSONDecoder().decode(StoredWindowState.self, from: data)
        else { return }
        model.pendingDestination = PendingDestination(
            account: stored.account, destination: stored.destination)
    }

    // Split into leading/trailing halves: one builder with every item
    // exceeded the type checker's budget.
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // iOS has no leading items — the channel up-button rides the
        // trailing group there, and the leading slot holds the
        // minimized search control (standard upper-left placement).
        #if os(macOS)
        detailLeadingToolbar
        #else
        #if os(visionOS)
        // Same layout as iOS, minus ToolbarSpacer (not on visionOS).
        if horizontalSizeClass == .compact {
            if !selectionHasComposer {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("New Conversation", systemImage: "square.and.pencil") {
                        model.pendingNewConversation = true
                    }
                }
            }
        } else {
            DefaultToolbarItem(kind: .search, placement: .topBarLeading)
        }
        #else
        if horizontalSizeClass == .compact {
            // Messages-style bottom bar on views without a composer:
            // expanded search field + write button. Composer views
            // (transcript, channel) drop search entirely — the
            // message field owns the bottom edge.
            if !selectionHasComposer {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("New Conversation", systemImage: "square.and.pencil") {
                        model.pendingNewConversation = true
                    }
                }
            }
        } else {
            // iPad: the minimized magnifier, upper-left of the main bar.
            DefaultToolbarItem(kind: .search, placement: .topBarLeading)
        }
        #endif
        #endif
        detailTrailingToolbar
    }

    @ToolbarContentBuilder
    private var detailLeadingToolbar: some ToolbarContent {
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
            // "Up" from a topic view to its channel. macOS paints the
            // glyph in the channel's color; iOS keeps the standard
            // monochrome toolbar glyph.
            if case .conversation(.topic(let streamId, _)) = selection {
                ToolbarItem(placement: .navigation) {
                    Button {
                        selection = .channel(streamId: streamId)
                    } label: {
                        Image(systemName: channelGlyph(streamId))
                            #if os(macOS)
                            .foregroundStyle(channelColor(streamId))
                            #endif
                    }
                    .help("Go to #\(store.channelName(streamId))")
                }
            }
    }

    @ToolbarContentBuilder
    private var detailTrailingToolbar: some ToolbarContent {
            // The server menu shows only with multiple servers — Settings
            // lives in the app menu on macOS and the toolbar gear on iOS.
            if model.global.enabledAccounts.count > 1 {
                ToolbarItem(placement: .automatic) {
                    ServerMenu(store: store, selectedAccount: $selectedAccount)
                        .popoverTip(PerWindowServersTip())
                }
            }
            #if os(macOS)
            // Contextual share, like iOS: appears while a message or
            // attachment is selected. The picker anchors to the button;
            // File → Export Selected… saves to disk instead.
            if keys.hasSelection {
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        shareSelection()
                    }
                    .background(SharingServiceAnchor(items: $macShareItems))
                    .help("Share selected message or attachment")
                }
            }
            #endif
            #if !os(macOS)
            // Fixed spacers split the trailing group's shared glass
            // capsule so each button gets its own standard circular
            // container — the left-side buttons' (and Mail's) size.
            if case .conversation(.topic(let streamId, _)) = selection {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        selection = .channel(streamId: streamId)
                    } label: {
                        Image(systemName: channelGlyph(streamId))
                    }
                    .help("Go to #\(store.channelName(streamId))")
                }
                #if !os(visionOS)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                #endif
            }
            // Contextual share: appears while a message or attachment is
            // selected — the system sheet covers save, send, and print.
            if keys.hasSelection {
                ToolbarItem(placement: .primaryAction) {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        shareSelection()
                    }
                }
                #if !os(visionOS)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                #endif
            }
            // Compact width keeps the detail's top bar minimal: the gear
            // lives on the root list, and compose rides the bottom bar.
            if horizontalSizeClass != .compact {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings", systemImage: "gear") {
                        showSettingsSheet = true
                    }
                }
                #if !os(visionOS)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                #endif
                ToolbarItem(placement: .primaryAction) {
                    Button("New Conversation", systemImage: "square.and.pencil") {
                        model.pendingNewConversation = true
                    }
                }
            }
            #endif
            // Slow attachment downloads earn a progress ring (quick ones
            // finish before `revealed` flips and never appear).
            if downloads.contains(where: \.revealed) {
                ToolbarItem(placement: .automatic) {
                    DownloadProgressButton(downloads: downloads)
                }
            }
            if connectionLost {
                #if os(visionOS)
                ToolbarItem(placement: .automatic) {
                    connectionLostBadge
                }
                #else
                ToolbarItem(placement: .automatic) {
                    connectionLostBadge
                }
                .sharedBackgroundVisibility(.hidden)
                #endif
            }
    }

    /// Go → Back / Forward in the key window — except that the keys, in a
    /// compose editor whose caret is in a list item, indent it instead.
    private func consumeHistoryStep() {
        guard let step = model.pendingHistoryStep else { return }
        #if os(macOS)
        // A sheet over this window may take the keys for its editor (the
        // new-conversation sheet's); nothing navigates behind it.
        let inSheet = hostSheetIsKey
        guard keys.hostWindow?.isKeyWindow != false || inSheet else { return }
        #endif
        model.pendingHistoryStep = nil
        if step.byKey, keys.indentList(step.delta > 0) { return }
        #if os(macOS)
        if inSheet { return }
        #endif
        navigateHistory(step.delta)
    }

    /// Format-menu actions apply in the key window's compose bar; list
    /// indenting goes to whichever editor is up front, as its keys do.
    private func consumeFormat() {
        guard let format = model.pendingFormat else { return }
        #if os(macOS)
        let inSheet = hostSheetIsKey
        guard keys.hostWindow?.isKeyWindow != false || inSheet else { return }
        #endif
        model.pendingFormat = nil
        switch format {
        case .indentList, .outdentList:
            _ = keys.indentList(format == .indentList)
        default:
            #if os(macOS)
            // The sheet's editor takes no other formats.
            if inSheet { return }
            #endif
            keys.applyFormat?(format)
        }
    }

    #if os(macOS)
    /// A sheet over this window is key: menu commands aimed at "the key
    /// window" land here, not in another window.
    private var hostSheetIsKey: Bool {
        guard let hostWindow = keys.hostWindow else { return false }
        return NSApp.keyWindow?.sheetParent == hostWindow
    }
    #endif

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

    /// Routes a parsed narrow link: directly when it's this window's
    /// account, via the pending-destination hop otherwise.
    private func openInternal(_ link: InternalLink, accountId: Account.ID) {
        let selfUserId = model.global.accounts
            .first { $0.id == accountId }?.userId ?? store.selfUserId
        let (destination, near) = link.destination(
            selfUserId: selfUserId, store: model.global.stores[accountId])
        if accountId == store.accountId {
            if let near, case .conversation(let key) = destination {
                keys.aimMessageLink(
                    key, messageId: near, alreadyOpen: selection == .conversation(key))
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
        case .toggleLinkPreviews:
            _ = keys.handleCharacter("L")
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
        case .exportSelected:
            #if os(macOS)
            exportSelected()
            #endif
        }
    }

    private func requestMessageAction(_ action: MessageActionRequest.Action) {
        keys.requestMessageAction(action)
    }

    /// Connection-lost indicator: the system warning triangle, sitting
    /// directly on the toolbar (no glass lozenge — it's a status light,
    /// not a button).
    private var connectionLostBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .foregroundStyle(.yellow)
            .font(.title3)
            .help("No connection to server")
    }

    /// The drop highlight's border. It frames the whole pane, so its
    /// corners are concentric with the window's (the display's on
    /// iPhone) — stroked half its width in, like a strokeBorder.
    private var dropHighlightBorder: some View {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(9)))
            .stroke(.tint, lineWidth: 2)
            .padding(1)
    }

    /// A plain function, not an inline switch expression: the latter blew
    /// the type checker's budget inside the onChange closure.
    private func visitedChannelId(for selection: Destination?) -> Int? {
        switch selection {
        case .channel(let id), .channelTopics(let id):
            return id
        case .conversation(.topic(let id, _)):
            return id
        default:
            return nil
        }
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
        // Items whose uploads are still running stay in the inbox until
        // they finish; they must not be offered again.
        let items = ShareInbox.pendingItems().filter {
            !model.shareItemsUploading.contains($0.directory)
        }
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
            keys.aimMessageLink(
                key, messageId: near, alreadyOpen: selection == .conversation(key))
        }
        selection = pending.destination
    }

    #if os(iOS)
    private func handleKeyPress(_ press: KeyPress) -> Bool {
        // Typing wins: no single-key navigation while a text input in this
        // window is active (macOS does this via its first-responder check).
        guard !keys.textInputActive else { return false }
        guard press.modifiers.isDisjoint(with: [.command, .control, .option])
        else { return false }
        switch press.key {
        case .upArrow: return keys.handleUpArrow()
        case .downArrow: return keys.handleDownArrow()
        case .return: return keys.handleReturn()
        case .escape: return keys.handleEscape()
        case .leftArrow:
            // ← steps back through attachments; from message level it
            // hands focus to the sidebar, whose native navigation takes
            // over until → (or a message tap) returns.
            return keys.handleLeftArrow()
        case .rightArrow: return keys.handleRightArrow()
        case .space: return keys.handleSpace()
        default:
            guard let character = press.characters.first else { return false }
            return keys.handleCharacter(character)
        }
    }
    #endif

    /// This window, for the feeds' per-window scroll memory.
    private var scene: FeedWarmCache.Scene { ObjectIdentifier(keys) }

    @ViewBuilder
    private var detailContent: some View {
        Group {
            switch selection {
            case .summary:
                SummaryView(store: store, search: search, selection: $selection)
                    .id(Destination.summary)
            case .conversation(let key):
                TranscriptView(
                    store: store, conversation: key, selection: $selection, scene: scene)
                    .id(key)
            case .channel(let streamId):
                ChannelFeedView(
                    store: store, streamId: streamId, selection: $selection, scene: scene)
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
                // Keyed on the muted preference too: flipping it is a
                // different narrow, with its own model and warm cache.
                NarrowFeedView(
                    store: store, title: "Combined feed",
                    narrow: .combinedFeed(includesMuted: combinedShowsMuted),
                    showsConversationJump: true, selection: $selection, scene: scene)
                    .id(Narrow.combinedFeed(includesMuted: combinedShowsMuted))
            case .mentions:
                NarrowFeedView(
                    store: store, title: "Mentions", narrow: .mentions,
                    showsConversationJump: true, selection: $selection, scene: scene)
                    .id(Destination.mentions)
            case .starred:
                NarrowFeedView(
                    store: store, title: "Starred messages", narrow: .starred,
                    showsConversationJump: true, selection: $selection, scene: scene)
                    .id(Destination.starred)
            case .search(let query):
                NarrowFeedView(
                    store: store, title: "Search: \(query.displayDescription)",
                    narrow: .custom(query.narrowElements),
                    useMatchHighlights: true,
                    ignoredSearchWords: query.exclusivelyIgnoredSearchWords,
                    anchorDate: query.anchorDay?.start(),
                    showsConversationJump: true,
                    selection: $selection, scene: scene)
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
