#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import TipKit
import ZulipAPI
import ZulipContent
import ZulipModel

/// The sidebar, modeled on the Zulip web app's: a Views section (smart
/// lists), compact Direct Messages, then channels grouped by folder with
/// unread count badges — topped by the dual-role filter/search field
/// (state shared with the suggestions panel via SidebarSearchModel).
struct SidebarView: View {
    let store: PerAccountStore
    @Bindable var search: SidebarSearchModel
    @Binding var selection: Destination?
    /// The enclosing window's account: the server switcher and ⌘1…⌘9
    /// change only this window.
    @Binding var selectedAccount: Account.ID?
    var startDirectMessage: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model
    @Environment(KeyboardRouter.self) private var keys
    @FocusState private var searchFocused: Bool

    @State private var collapsedSections: Set<String>
    @State private var expandedChannels: Set<Int>
    /// Settings → "Only the selected channel shows its topics": the
    /// selection's channel opens its topics and every other closes, as on
    /// Zulip's web app, so the sidebar never grows by a list per channel
    /// visited.
    @AppStorage("topicsFollowSelection") private var topicsFollowSelection = true
    /// The channels showing topics in that mode: the selected one, and any
    /// opened by hand since the selection last moved. Never saved — the
    /// user's own disclosures (`expandedChannels`) wait untouched for the
    /// mode to be switched off.
    @State private var followedChannels: Set<Int>
    /// The pending close of channels the selection has left.
    @State private var foldTask: Task<Void, Never>?
    /// When the list came up: selection changes right at a window's
    /// opening (its restored destination lands after the first layout)
    /// apply without animation.
    @State private var appearedAt = Date.distantFuture
    @AppStorage("dmSortOrder") private var dmSortOrder = DmSortOrder.lastMessage.rawValue
    @AppStorage("channelsAboveDMs") private var channelsAboveDMs = true
    @AppStorage("combinedShowsMuted") private var combinedShowsMuted = false
    @State private var showOfflineUsers = false
    @State private var expandedInactiveSections: Set<String> = []
    /// Channels whose topic list shows everything (past the inline cap).
    @State private var expandedAllTopics: Set<Int> = []
    /// The channel being renamed via its context menu, if any.
    @State private var renameChannelId: Int?
    @State private var renameChannelText = ""
    /// The channel whose color picker is open, if any.
    @State private var colorChannelId: Int?
    /// The channel pending archive confirmation, if any.
    @State private var archiveChannelId: Int?
    /// The channel whose description is being edited, if any.
    @State private var descriptionChannelId: Int?
    @State private var descriptionChannelText = ""
    /// The channel whose subscriber sheet is open, if any.
    @State private var subscribersChannelId: Int?

    init(
        store: PerAccountStore, search: SidebarSearchModel,
        selection: Binding<Destination?>,
        selectedAccount: Binding<Account.ID?>,
        startDirectMessage: (() -> Void)? = nil
    ) {
        self.store = store
        self.search = search
        _selection = selection
        _selectedAccount = selectedAccount
        self.startDirectMessage = startDirectMessage
        _collapsedSections = State(
            initialValue: AppStateStore.collapsedSections(for: store.accountId))
        _expandedChannels = State(
            initialValue: AppStateStore.expandedChannels(for: store.accountId))
        // The opening selection's channel is open in the first frame.
        _followedChannels = State(
            initialValue: Set([Self.channel(of: selection.wrappedValue)].compactMap { $0 }))
    }

    /// Row click handling: double-click opens the entry standalone in a
    /// new window; on macOS 26 a single click also selects it (see
    /// SidebarRowClicks).
    private func rowClicks(_ destination: Destination) -> SidebarRowClicks {
        SidebarRowClicks(destination: destination, selection: $selection) {
            DetachWindowTip().invalidate(reason: .actionPerformed)
            openWindow(
                value: DetachedWindow(accountId: store.accountId, destination: destination))
        }
    }

    private static let maxInlineTopics = 10

    private var isFiltering: Bool {
        search.isFiltering
    }

    private var filterText: String {
        search.filterText
    }

    private func matchesFilter(_ name: String) -> Bool {
        !isFiltering || name.localizedCaseInsensitiveContains(filterText)
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(id) },
            set: { expanded in
                if expanded {
                    collapsedSections.remove(id)
                } else {
                    collapsedSections.insert(id)
                }
            })
    }

    private var sortByActivity: Bool {
        dmSortOrder == DmSortOrder.activity.rawValue
    }

    /// The conversation's most recently seen participant, for activity sort.
    private func lastSeen(_ key: ConversationKey) -> Date {
        (key.dmParticipantIds ?? [])
            .filter { $0 != store.selfUserId }
            .compactMap { store.presence.lastSeen(of: $0) }
            .max() ?? .distantPast
    }

    private var dmRows: [ConversationList.Conversation] {
        let rows = store.conversations.conversations.filter { conversation in
            guard case .dm = conversation.key else { return false }
            return matchesFilter(conversation.key.displayTitle(in: store))
        }
        guard sortByActivity else { return rows }  // Already message-recency order.
        return rows.sorted {
            (lastSeen($0.key), $0.lastMessageId) > (lastSeen($1.key), $1.lastMessageId)
        }
    }

    /// Everyone else: active human users with no 1:1 conversation yet, below
    /// the recency-ordered conversations. Selecting one opens an empty
    /// transcript ready to compose.
    /// The DM people directory, in one pass. On a 60k-user realm the
    /// previous three-property version filtered the whole user list
    /// (building a string conversation key per user) and sorted it all
    /// with ICU collation up to four times per body evaluation — the
    /// seconds-long main-thread stalls that made the whole app feel slow.
    /// Membership now checks an Int set, only the visible slice is
    /// sorted, and ordering compares precomputed casefolded keys.
    private struct Directory {
        var visible: [User] = []
        var hiddenCount = 0
        var isEmpty: Bool { visible.isEmpty && hiddenCount == 0 }
    }

    /// The DM conversations section (recents, then the people directory).
    @ViewBuilder
    private var dmSection: some View {
        Section(isExpanded: expansion("dms")) {
            // Computed once per body pass — every row and the expander
            // share it.
            let directory = makeDirectory()
            ForEach(dmRows) { conversation in
                DirectMessageRow(store: store, conversation: conversation)
                    .tag(Destination.conversation(conversation.key))
                    .modifier(rowClicks(.conversation(conversation.key)))
            }
            // Namespaced ids: a bare userId that numerically matches a
            // channel row's streamId would alias the two rows in the
            // List's flat selection registry (see TopicRowEntry).
            ForEach(directory.visible, id: \.directoryRowId) { user in
                let key = Unreads.dmKey(
                    participantIds: [user.userId], selfUserId: store.selfUserId)
                UserDirectMessageRow(store: store, user: user)
                    .tag(Destination.conversation(key))
                    .modifier(rowClicks(.conversation(key)))
            }
            if directory.hiddenCount > 0 {
                SidebarExpanderRow(
                    title: "More conversations… (\(directory.hiddenCount))"
                ) {
                    showOfflineUsers = true
                }
            } else if showOfflineUsers && !isFiltering && !directory.isEmpty {
                SidebarExpanderRow(title: "Fewer conversations") {
                    showOfflineUsers = false
                }
            }
        } header: {
            if let startDirectMessage {
                SectionHeaderWithAdd(
                    title: "Direct messages", help: "New direct message",
                    action: startDirectMessage)
            } else {
                Text("Direct messages")
            }
        }
    }

    /// The channel sections, one per folder (or a single Channels section).
    @ViewBuilder
    private var channelsSections: some View {
        if store.channelFolders.isEmpty {
            channelSection(
                title: "Channels", id: "channels", channels: sortedSubscriptions,
                showsJoin: true)
        } else {
            let sorted = sortedSubscriptions
            ForEach(
                Array(store.channelFolders.enumerated()), id: \.element.id
            ) { index, folder in
                channelSection(
                    title: folder.name, id: "folder-\(folder.id)",
                    channels: channels(inFolder: folder.id, from: sorted),
                    showsJoin: index == 0)
            }
            channelSection(
                title: "Other channels", id: "folder-none",
                channels: channels(inFolder: nil, from: sorted))
        }
    }

    private func makeDirectory() -> Directory {
        // Existing 1:1 DM partners (and the self-DM), as plain ids.
        var dmPartnerIds = Set<Int>()
        var hasSelfDm = false
        for conversation in store.conversations.conversations {
            guard case .dm(let joined) = conversation.key else { continue }
            let ids = joined.split(separator: ",").compactMap { Int($0) }
            if ids.isEmpty {
                hasSelfDm = true
            } else if ids.count == 1 {
                dmPartnerIds.insert(ids[0])
            }
        }
        let selfUserId = store.selfUserId
        let candidates = store.users.values.filter { user in
            guard user.isActive != false, !user.isBot else { return false }
            if user.userId == selfUserId {
                guard !hasSelfDm else { return false }
            } else if dmPartnerIds.contains(user.userId) {
                return false
            }
            return matchesFilter(user.userId == selfUserId ? "Yourself" : user.fullName)
        }
        let shown = isFiltering || showOfflineUsers
            ? candidates
            : candidates.filter { store.presenceState(of: $0.userId) != .offline }
        return Directory(
            visible: sortedForDirectory(shown),
            hiddenCount: candidates.count - shown.count)
    }

    private func sortedForDirectory(_ users: [User]) -> [User] {
        let selfUserId = store.selfUserId
        // Yourself pins first (a self-DM is notes-to-self, like the web app).
        if sortByActivity {
            return users
                .map { user in
                    (user: user,
                     seen: store.presence.lastSeen(of: user.userId) ?? .distantPast,
                     key: user.fullName.lowercased())
                }
                .sorted { a, b in
                    if a.user.userId == selfUserId { return true }
                    if b.user.userId == selfUserId { return false }
                    if a.seen != b.seen { return a.seen > b.seen }
                    return a.key < b.key
                }
                .map(\.user)
        }
        return users
            .map { (user: $0, key: $0.fullName.lowercased()) }
            .sorted { a, b in
                if a.user.userId == selfUserId { return true }
                if b.user.userId == selfUserId { return false }
                return a.key < b.key
            }
            .map(\.user)
    }

    /// Unsent compose text, one row per conversation: typing and moving away
    /// lands here; selecting resumes composing (the transcript's compose bar
    /// restores its draft). Only drafts resolvable in this account show.
    private var draftRows: [(destination: SendDestination, key: ConversationKey, text: String)] {
        DraftStore.shared.entries(account: store.accountId)
            .compactMap { destination, entry -> (SendDestination, ConversationKey, String)? in
                let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let key: ConversationKey
                switch destination {
                case .topic(let streamId, let topic):
                    guard store.channels[streamId] != nil
                        || store.subscriptions[streamId] != nil else { return nil }
                    key = .topic(streamId: streamId, topic: topic)
                case .dm(let userIds):
                    guard userIds.contains(where: { store.users[$0] != nil }) else { return nil }
                    key = Unreads.dmKey(participantIds: userIds, selfUserId: store.selfUserId)
                }
                // The conversation being typed in isn't a "draft" yet —
                // its row appears once you navigate away.
                guard selection != .conversation(key) else { return nil }
                guard matchesFilter(key.displayTitle(in: store)) || matchesFilter(trimmed)
                else { return nil }
                return (destination, key, trimmed)
            }
            .sorted {
                $0.1.displayTitle(in: store)
                    .localizedCaseInsensitiveCompare($1.1.displayTitle(in: store))
                    == .orderedAscending
            }
    }

    /// The no-conversation directory splits at presence: offline users hide
    /// behind "More conversations…" (filtering searches everyone).

    private var sortedSubscriptions: [Subscription] {
        PerfLog.time("sortedSubscriptions", over: 4) {
            store.subscriptions.values
                .sorted { a, b in
                    let aPinned = a.pinToTop ?? false
                    let bPinned = b.pinToTop ?? false
                    if aPinned != bPinned { return aPinned }
                    if a.muted != b.muted { return b.muted }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
        }
    }

    private func channels(inFolder folderId: Int?, from sorted: [Subscription]) -> [Subscription] {
        sorted.filter { store.channels[$0.streamId]?.folderId == folderId }
    }

    /// The channels to show (with, while filtering, their matching topics):
    /// a channel is visible when its name matches or any of its topics do.
    private func visibleChannels(_ channels: [Subscription]) -> [(Subscription, [ChannelTopic])] {
        channels.compactMap { subscription in
            guard isFiltering else { return (subscription, []) }
            let topicMatches = (search.channelTopics[subscription.streamId] ?? []).filter { topic in
                TopicName.displayName(topic.name).localizedCaseInsensitiveContains(filterText)
            }
            if subscription.name.localizedCaseInsensitiveContains(filterText) || !topicMatches.isEmpty {
                return (subscription, topicMatches)
            }
            return nil
        }
    }

    @AppStorage("recentSearchLimit") private var recentSearchLimit = 5

    @FocusState private var listFocused: Bool
    /// Set by a pick made while filtering (or a search just committed):
    /// the unfiltered list that replaces the filtered one may have that
    /// row folded away, so it's brought back into view.
    @State private var revealOnFilterEnd = false
    /// The channel picked while filtering: it lists all its topics, not
    /// just the filter's matches, for as long as the selection stays in
    /// it (picking one of those topics keeps the list open).
    @State private var filterPickedChannel: Int?

    var body: some View {
        ScrollViewReader { proxy in
            sidebarList
                .onChange(of: selection) {
                    if isFiltering {
                        revealOnFilterEnd = true
                        updateFilterPickedChannel()
                    }
                    followSelection()
                }
                // Switched on in Settings: it takes hold at once.
                .onChange(of: topicsFollowSelection) { followSelection() }
                .onAppear { appearedAt = .now }
                .onChange(of: isFiltering) { _, filtering in
                    // Still the selection's channel as the filter ends: the
                    // unfiltered list keeps it expanded rather than folding
                    // away the topics just shown.
                    if !filtering, let streamId = filterPickedChannel,
                       streamId == selectedStreamId {
                        openChannels.insert(streamId)
                    }
                    filterPickedChannel = nil
                    // Selections made while filtering weren't followed.
                    if !filtering { followSelection() }
                    if filtering {
                        revealOnFilterEnd = false
                    } else if revealOnFilterEnd {
                        revealOnFilterEnd = false
                        revealSelection(with: proxy)
                    }
                }
        }
    }

    @ViewBuilder
    private var sidebarList: some View {
        let _ = PerfLog.render("Sidebar")
        let _ = PerfLog.mark("Sidebar body")
        List(selection: $selection) {
            #if os(macOS)
            // Suggestions ride in the list, not the field's native
            // suggestion menu: on macOS that menu swallows the click that
            // dismisses it, so a filtered row took two clicks to select.
            // (iOS keeps the native presentation, which replaces the
            // detail content while typing instead.)
            if isFiltering {
                Section("Search") {
                    SearchSuggestionRow(
                        title: "Search for “\(typedQuery.displayDescription)”",
                        icon: "magnifyingglass"
                    ) {
                        runSearch(recordInRecents: true)
                    }
                    ForEach(search.suggestions) { token in
                        SearchSuggestionRow(
                            title: token.suggestionTitle, icon: token.suggestionIcon
                        ) {
                            search.commit(token)
                            // The click moved focus to the list; the field
                            // is where the free text comes next.
                            searchFocused = true
                        }
                    }
                }
            }
            #endif
            if !isFiltering {
                Section("Views", isExpanded: expansion("views")) {
                    viewRow("Summary", icon: "newspaper", tag: .summary, badge: 0)
                    viewRow(
                        "Recent", icon: "clock", tag: .recentConversations,
                        badge: 0)
                        .popoverTip(DetachWindowTip())
                        .contextMenu {
                            Button("Mark All Messages as Read") {
                                store.markAllRead()
                            }
                        }
                    viewRow(
                        "Combined", icon: "line.3.horizontal", tag: .combinedFeed,
                        // The unreads the feed itself will show: a badge
                        // it hides the messages for could never clear.
                        badge: store.combinedUnreadCount(includesMuted: combinedShowsMuted))
                        .contextMenu {
                            Button("Mark All Messages as Read") {
                                store.markAllRead()
                            }
                        }
                    viewRow(
                        "Mentions", icon: "at", tag: .mentions,
                        badge: store.unreads.mentionIds.count)
                    viewRow(
                        "Starred", icon: "star", tag: .starred,
                        badge: store.starredMessageIds.count)
                    // Unsent messages: only surfaces while something waits.
                    if !store.outbox.isEmpty {
                        viewRow(
                            "Outbox", icon: "tray.and.arrow.up", tag: .outbox,
                            badge: store.outbox.count)
                    }
                    // Pending reminders: only surfaces while some exist.
                    if !store.reminders.isEmpty {
                        viewRow(
                            "Reminders", icon: "clock", tag: .reminders,
                            badge: store.reminders.count)
                    }
                    viewRow(
                        "All channels", icon: "rectangle.stack", tag: .allChannels, badge: 0)
                }
            }
            if !isFiltering, recentSearchLimit > 0, !search.recentSearches.isEmpty {
                Section("Recent Searches", isExpanded: expansion("recents")) {
                    ForEach(search.recentSearches.prefix(recentSearchLimit), id: \.self) { query in
                        RecentSearchRow(query: query) {
                            search.removeRecentSearch(query)
                        }
                        .tag(Destination.search(query))
                        .contextMenu {
                            Button("Remove") {
                                search.removeRecentSearch(query)
                            }
                            Button("Clear Recent Searches") {
                                search.clearRecentSearches()
                            }
                        }
                    }
                }
            }
            if !draftRows.isEmpty {
                Section("Drafts", isExpanded: expansion("drafts")) {
                    ForEach(draftRows, id: \.destination) { row in
                        DraftRow(store: store, conversationKey: row.key, text: row.text)
                            .tag(Destination.conversation(row.key))
                            .contextMenu {
                                Button("Discard Draft", role: .destructive) {
                                    DraftStore.shared.setDraft(
                                        "", for: row.destination,
                                        account: store.accountId)
                                }
                            }
                    }
                }
            }
            if channelsAboveDMs {
                channelsSections
                dmSection
            } else {
                dmSection
                channelsSections
            }
            if isFiltering && search.loadingAllTopics {
                Label {
                    Text("Searching topics…")
                } icon: {
                    Image(systemName: "ellipsis")
                        .sidebarIcon(.gray)
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        // Return capture lives inside the searchable subtree so it sees
        // `isSearching`.
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchReturnCapture(
                search: search, searchFocused: searchFocused,
                onSubmitSearch: { runSearch(recordInRecents: true) },
                // ↓ from the field: native list navigation takes over.
                onMoveDown: { listFocused = true })
        }
        // Mail-style activity footer: a bulk mark-as-read sweep shows its
        // running count here, then the outcome lingers briefly.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let sweep = store.markReadSweep {
                MarkReadStatusFooter(sweep: sweep)
            }
        }
        .listStyle(.sidebar)
        #if !os(macOS)
        // Mail-style bold section headers.
        .headerProminence(.increased)
        #endif
        // One field, two roles: typing filters the sidebar live (suggestions
        // pop over beside the field); committed tokens search immediately;
        // Return searches the free text and records it in Recent Searches.
        // macOS only — iOS attaches the same field to the detail column
        // (MainSplitView's DetailSearchField), so the minimized magnifier
        // renders in the main view's toolbar.
        #if os(macOS)
        .searchable(
            text: $search.filterText, tokens: $search.tokens,
            placement: Self.searchPlacement, prompt: "Filter or search"
        ) { token in
            Text(token.bubbleText)
        }
        // No `.searchSuggestions` here: on macOS they present as a menu
        // under the field, and the click that dismisses a menu never
        // reaches the row beneath. The list's Search section shows them.
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            runSearch(recordInRecents: true)
        }
        #endif
        .focused($listFocused)
        // → hands focus back to the messages pane (macOS routes this via
        // the key monitor; this covers the iPad hardware keyboard).
        .onKeyPress(.rightArrow) {
            keys.focusMessages?()
            return .handled
        }
        .onAppear {
            #if os(macOS)
            // The keyboard router's / shortcut focuses the search field;
            // media selection blurs it so Space can Quick Look. (iOS
            // registers these from DetailSearchField instead.)
            let focus = $searchFocused
            keys.focusSearch = { focus.wrappedValue = true }
            keys.blurSearch = { focus.wrappedValue = false }
            #endif
            // ← from messages lands here; native list navigation takes
            // over while focused.
            let list = $listFocused
            keys.focusSidebar = { list.wrappedValue = true }
            #if os(macOS)
            // Dropping list focus returns arrows to the message pane (the
            // monitor's default). iOS registers its own in MainSplitView.
            keys.focusMessages = { list.wrappedValue = false }
            #endif
        }
        .onChange(of: search.tokens) {
            if !search.tokens.isEmpty {
                runSearch(recordInRecents: false)
            }
        }
        .onChange(of: search.filterText) {
            search.loadAllTopicsIfNeeded()
        }
        .alert(
            "Rename Channel",
            isPresented: Binding(
                get: { renameChannelId != nil },
                set: { if !$0 { renameChannelId = nil } })
        ) {
            TextField("Channel name", text: $renameChannelText)
            Button("Rename") {
                if let streamId = renameChannelId {
                    store.renameChannel(streamId, to: renameChannelText)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The channel is renamed for everyone.")
        }
        .alert(
            "Edit Channel Description",
            isPresented: Binding(
                get: { descriptionChannelId != nil },
                set: { if !$0 { descriptionChannelId = nil } })
        ) {
            TextField("Description", text: $descriptionChannelText)
            Button("Save") {
                if let streamId = descriptionChannelId {
                    store.setChannelDescription(
                        streamId,
                        description: descriptionChannelText
                            .trimmingCharacters(in: .whitespaces))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The description changes for everyone.")
        }
        .sheet(
            isPresented: Binding(
                get: { colorChannelId != nil },
                set: { if !$0 { colorChannelId = nil } })
        ) {
            if let streamId = colorChannelId {
                ChannelColorSheet(store: store, streamId: streamId)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { subscribersChannelId != nil },
                set: { if !$0 { subscribersChannelId = nil } })
        ) {
            if let streamId = subscribersChannelId {
                ManageSubscribersSheet(store: store, streamId: streamId)
            }
        }
        .alert(
            "Archive Channel",
            isPresented: Binding(
                get: { archiveChannelId != nil },
                set: { if !$0 { archiveChannelId = nil } })
        ) {
            Button("Archive", role: .destructive) {
                if let streamId = archiveChannelId {
                    store.archiveChannel(streamId)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let name = archiveChannelId.flatMap { store.subscriptions[$0]?.name } ?? "this channel"
            Text(
                "#\(name) is archived for everyone: it stops accepting messages and "
                    + "disappears from sidebars, but its history is preserved. "
                    + "Requires administrator permission.")
        }
        .onChange(of: expandedChannels) {
            AppStateStore.setExpandedChannels(expandedChannels, for: store.accountId)
        }
        .onChange(of: collapsedSections) {
            AppStateStore.setCollapsedSections(collapsedSections, for: store.accountId)
        }
        .onChange(of: model.global.enabledAccounts.count, initial: true) {
            PerWindowServersTip.hasMultipleAccounts = model.global.enabledAccounts.count > 1
        }
    }


    private static var searchPlacement: SearchFieldPlacement {
        // .automatic: the window toolbar on macOS (Mail-style); the
        // sidebar's bar on iPad, where MinimizedSidebarSearch collapses
        // it into the standard toolbar magnifier. (An explicit .toolbar
        // placement is ignored for split-view sidebars on iPadOS.)
        .automatic
    }

    /// The query as typed: committed tokens plus the free text.
    private var typedQuery: SearchQuery {
        SearchQuery(tokens: search.tokens, text: search.filterText)
    }

    /// Runs the current query. Return finalizes it: the query is recorded in
    /// Recent Searches, the field clears back to filter duty and gives up
    /// focus (the results are what to read next, and the single-key
    /// shortcuts should reach them, as in the web app), and the recorded
    /// row (tagged with the same query) highlights as the selection.
    /// Intermediate token-commit searches show results but leave the
    /// field composing and don't touch recents.
    private func runSearch(recordInRecents: Bool) {
        let query = typedQuery
        guard !query.isEmpty else { return }
        if recordInRecents {
            search.recordSearch(query)
            revealOnFilterEnd = true
            search.filterText = ""
            search.tokens = []
            searchFocused = false
        }
        selection = .search(query)
    }

    /// Refreshes a channel's cached topic list shortly after a topic
    /// rename, once the server has applied the move.
    private func refreshTopicsSoon(_ streamId: Int) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            search.refreshTopics(streamId)
        }
    }

    /// A channel is "active" when pinned, carrying unreads, present in
    /// the recency list, or the one being viewed (a selection hidden
    /// behind the expander would highlight nothing); the rest hide behind
    /// "Inactive channels…".
    /// `recent` is `store.conversations.channelRecency`, read once per
    /// section: built per channel (it walks every conversation), it cost
    /// ~90 ms of main thread per sidebar pass at launch.
    private func isActiveChannel(_ subscription: Subscription, recent: [Int: Int]) -> Bool {
        if subscription.pinToTop ?? false { return true }
        if subscription.streamId == selectedStreamId { return true }
        if store.unreads.unreadCount(inChannel: subscription.streamId) > 0 { return true }
        return recent[subscription.streamId] != nil
    }

    /// The channel the selection lives in, if any.
    private var selectedStreamId: Int? { Self.channel(of: selection) }

    /// The channel a destination lives in: the channel itself, its topic
    /// list, or one of its topics.
    private static func channel(of destination: Destination?) -> Int? {
        switch destination {
        case .channel(let streamId), .channelTopics(let streamId):
            streamId
        case .conversation(.topic(let streamId, _)):
            streamId
        default:
            nil
        }
    }

    /// The channels showing their topics: the user's own disclosures, or —
    /// following the selection — the selected channel and any opened by
    /// hand since.
    private var openChannels: Set<Int> {
        get { topicsFollowSelection ? followedChannels : expandedChannels }
        nonmutating set {
            if topicsFollowSelection {
                followedChannels = newValue
            } else {
                expandedChannels = newValue
            }
        }
    }

    /// How long a channel the selection has left keeps its topics: past a
    /// double-click. Rows folding away above the pointer between the two
    /// clicks would put a different row under the second.
    private static var foldDelay: Duration {
        #if os(macOS)
        .seconds(min(NSEvent.doubleClickInterval, 0.5))
        #else
        .milliseconds(350)
        #endif
    }

    /// Following the selection: its channel opens its topics at once, and
    /// whatever else is open closes a beat later. The filtered list keeps
    /// its own rules (see `filterPickedChannel`).
    private func followSelection() {
        guard topicsFollowSelection, !isFiltering else { return }
        foldTask?.cancel()
        foldTask = nil
        let keep: Set<Int> = selectedStreamId.map { [$0] } ?? []
        let settled = Date.now.timeIntervalSince(appearedAt) > 0.5
        if !keep.isSubset(of: followedChannels) {
            withAnimation(settled ? .snappy : nil) { followedChannels.formUnion(keep) }
            // Topics move fast on active channels: fresh on every open.
            keep.forEach { search.refreshTopics($0) }
        }
        let stale = followedChannels.subtracting(keep)
        guard !stale.isEmpty else { return }
        guard settled else {
            followedChannels.subtract(stale)
            return
        }
        foldTask = Task {
            try? await Task.sleep(for: Self.foldDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) {
                followedChannels.subtract(stale)
                // Back to the short list the next time they open.
                expandedAllTopics.subtract(stale)
            }
        }
    }

    /// The section a channel is listed under (see channelsSections).
    private func sectionId(forChannel streamId: Int) -> String {
        guard !store.channelFolders.isEmpty else { return "channels" }
        return store.channels[streamId]?.folderId.map { "folder-\($0)" } ?? "folder-none"
    }

    /// Brings the selection back into view once the filter is cancelled:
    /// the unfiltered list may have it folded away (a topic under an
    /// unexpanded channel, past the inline cap, or in a collapsed
    /// section). Its section and channel expand, then the row scrolls
    /// into view — a no-op when it's already showing. A token search in
    /// progress is left alone; its results are the point.
    private func revealSelection(with proxy: ScrollViewProxy) {
        guard search.tokens.isEmpty, let selection else { return }
        switch selection {
        case .channel(let streamId), .channelTopics(let streamId):
            collapsedSections.remove(sectionId(forChannel: streamId))
            scrollSoon(proxy, to: streamId)
        case .conversation(.topic(let streamId, let topic)):
            collapsedSections.remove(sectionId(forChannel: streamId))
            openChannels.insert(streamId)
            guard let topics = search.channelTopics[streamId],
                  let index = topics.firstIndex(where: { TopicName.matches($0.name, topic) })
            else {
                // Topics not cached yet (the expansion fetches them): the
                // channel row stands in.
                scrollSoon(proxy, to: streamId)
                return
            }
            if index >= Self.maxInlineTopics {
                expandedAllTopics.insert(streamId)
            }
            scrollSoon(proxy, to: TopicRowEntry.id(streamId: streamId, topic: topics[index].name))
        case .conversation(let key):
            collapsedSections.remove("dms")
            scrollSoon(proxy, to: key)
        case .search(let query):
            collapsedSections.remove("recents")
            scrollSoon(proxy, to: query)
        default:
            break
        }
    }

    /// The expansions above land on the next render; the scroll waits a
    /// beat for the row to exist.
    private func scrollSoon<ID: Hashable>(_ proxy: ScrollViewProxy, to id: ID) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            proxy.scrollTo(id)
        }
    }

    @ViewBuilder
    private func channelSection(
        title: String, id: String, channels: [Subscription], showsJoin: Bool = false
    ) -> some View {
        let visible = visibleChannels(channels)
        let hideInactive = !isFiltering && !expandedInactiveSections.contains(id)
        let recent = store.conversations.channelRecency
        let shown = hideInactive ? visible.filter { isActiveChannel($0.0, recent: recent) } : visible
        let hiddenCount = visible.count - shown.count
        if !visible.isEmpty {
            Section(isExpanded: expansion(id)) {
                ForEach(shown, id: \.0.id) { subscription, topicMatches in
                    let streamId = subscription.streamId
                    ChannelRow(
                        store: store, subscription: subscription,
                        isExpanded: openChannels.contains(streamId),
                        onToggle: isFiltering ? nil : { toggleChannel(streamId) })
                        .tag(Destination.channel(streamId: streamId))
                        .modifier(rowClicks(.channel(streamId: streamId)))
                        .contextMenu {
                            Button(subscription.muted ? "Unmute Channel" : "Mute Channel") {
                                store.setChannelMuted(streamId, muted: !subscription.muted)
                            }
                            Toggle(
                                "Notify on All Messages",
                                isOn: Binding(
                                    get: { subscription.desktopNotifications == true },
                                    set: { store.setChannelNotifies(streamId, notifies: $0) }))
                            Button(
                                (subscription.pinToTop ?? false)
                                    ? "Unpin Channel" : "Pin Channel to Top"
                            ) {
                                store.setChannelPinned(
                                    streamId, pinned: !(subscription.pinToTop ?? false))
                            }
                            Divider()
                            Button("Copy Link to Channel") {
                                Platform.copyToPasteboard(
                                    ConversationKey.channelLink(streamId: streamId, in: store))
                            }
                            // #**channel**: pasted into a message, a link.
                            Button("Copy Channel Reference") {
                                Platform.copyToPasteboard(
                                    ConversationKey.channelReference(streamId: streamId, in: store))
                            }
                            Button("Mark All Messages as Read") {
                                store.markChannelAllRead(streamId)
                            }
                            Button("Mark All Messages as Unread") {
                                keys.readMarkingPaused = true
                                store.markChannelUnread(streamId)
                            }
                            Divider()
                            Button("Rename Channel…") {
                                renameChannelText = subscription.name
                                renameChannelId = streamId
                            }
                            Button("Edit Description…") {
                                descriptionChannelText = store.channels[streamId]?.description
                                    ?? subscription.description ?? ""
                                descriptionChannelId = streamId
                            }
                            Button("Manage Subscribers…") {
                                subscribersChannelId = streamId
                            }
                            Button("Change Color…") {
                                colorChannelId = streamId
                            }
                            Button("Unsubscribe") {
                                store.unsubscribe(fromChannel: subscription.name)
                            }
                            Divider()
                            Button("Archive Channel…", role: .destructive) {
                                archiveChannelId = streamId
                            }
                        }
                    if streamId == filterPickedChannel {
                        topicRows(for: streamId)
                    } else if isFiltering {
                        // Same rail as the unfiltered list; dotted when the
                        // 8-row cap hides further matches ("more below").
                        let matches = Array(topicMatches.prefix(8))
                        ForEach(topicRowEntries(matches, streamId: streamId)) { entry in
                            SidebarTopicRow(
                                store: store, streamId: streamId, topic: entry.topic,
                                rail: entry.index < matches.count - 1 ? .through
                                    : topicMatches.count > matches.count ? .dotted : .cap,
                                railJoinsAbove: entry.index > 0,
                                onRenamed: { refreshTopicsSoon(streamId) })
                                .tag(Destination.conversation(
                                    .topic(streamId: streamId, topic: entry.topic.name)))
                                .modifier(rowClicks(.conversation(
                                    .topic(streamId: streamId, topic: entry.topic.name))))
                        }
                    } else if openChannels.contains(streamId) {
                        topicRows(for: streamId)
                    }
                }
                if hiddenCount > 0 {
                    SidebarExpanderRow(title: "Inactive channels… (\(hiddenCount))") {
                        expandedInactiveSections.insert(id)
                    }
                } else if !isFiltering && expandedInactiveSections.contains(id)
                    && visible.contains(where: { !isActiveChannel($0.0, recent: recent) }) {
                    SidebarExpanderRow(title: "Hide inactive channels") {
                        expandedInactiveSections.remove(id)
                    }
                }
            } header: {
                if showsJoin {
                    SectionHeaderWithAdd(
                        title: title, help: "Browse and join channels",
                        action: { selection = .allChannels })
                } else {
                    Text(title)
                }
            }
        }
    }

    /// A topic row enumerated under a List-unique identity: topic names
    /// repeat across channels, and rows sharing an id anywhere in one
    /// List alias in its selection machinery — selecting one highlighted
    /// every namesake, with the last-registered row's tag winning the
    /// view.
    private struct TopicRowEntry: Identifiable {
        let id: String
        let index: Int
        let topic: ChannelTopic

        static func id(streamId: Int, topic: String) -> String {
            "\(streamId)/\(topic)"
        }
    }

    private func topicRowEntries(
        _ topics: [ChannelTopic], streamId: Int
    ) -> [TopicRowEntry] {
        topics.enumerated().map { index, topic in
            TopicRowEntry(
                id: TopicRowEntry.id(streamId: streamId, topic: topic.name),
                index: index, topic: topic)
        }
    }

    @ViewBuilder
    private func topicRows(for streamId: Int) -> some View {
        if let topics = search.channelTopics[streamId] {
            let showAll = expandedAllTopics.contains(streamId)
            let shown = showAll ? topics : Array(topics.prefix(Self.maxInlineTopics))
            let hasMore = topics.count > Self.maxInlineTopics
            ForEach(topicRowEntries(shown, streamId: streamId)) { entry in
                SidebarTopicRow(
                    store: store, streamId: streamId, topic: entry.topic,
                    rail: entry.index == shown.count - 1 && !hasMore ? .cap : .through,
                    railJoinsAbove: entry.index > 0,
                    onRenamed: { refreshTopicsSoon(streamId) })
                    .tag(Destination.conversation(
                        .topic(streamId: streamId, topic: entry.topic.name)))
                    .modifier(rowClicks(.conversation(
                        .topic(streamId: streamId, topic: entry.topic.name))))
            }
            if hasMore {
                // Expands in place; the rail's dotted end says "more
                // below", the rounded cap closes the fully shown list.
                Button {
                    withAnimation(.snappy) {
                        if showAll {
                            expandedAllTopics.remove(streamId)
                        } else {
                            expandedAllTopics.insert(streamId)
                        }
                    }
                } label: {
                    Label {
                        Text(showAll ? "Fewer topics…" : "All topics…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } icon: {
                        TopicRailTick(
                            color: channelColor(streamId),
                            kind: showAll ? .cap : .dotted,
                            joinsAbove: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } else {
            Label {
                ProgressView()
                    .controlSize(.small)
            } icon: {
                TopicRailTick(color: channelColor(streamId), kind: .cap)
            }
                // Channels restored as expanded from last session reach here
                // without a disclosure click — kick the fetch ourselves.
                .onAppear { search.refreshTopics(streamId) }
        }
    }

    private func channelColor(_ streamId: Int) -> Color {
        store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    /// Picking a channel while filtering opens its topic list; the
    /// selection leaving that channel closes it again.
    private func updateFilterPickedChannel() {
        switch selection {
        case .channel(let streamId), .channelTopics(let streamId):
            guard streamId != filterPickedChannel else { return }
            withAnimation(.snappy) { filterPickedChannel = streamId }
            search.refreshTopics(streamId)
        default:
            if selectedStreamId != filterPickedChannel {
                withAnimation(.snappy) { filterPickedChannel = nil }
            }
        }
    }

    private func toggleChannel(_ streamId: Int) {
        withAnimation(.snappy) {
            if openChannels.contains(streamId) {
                openChannels.remove(streamId)
            } else {
                openChannels.insert(streamId)
            }
        }
        // Refresh on every expand — topics move fast on active channels.
        if openChannels.contains(streamId) {
            search.refreshTopics(streamId)
        }
    }

    private func viewRow(
        _ title: String, icon: String, tag: Destination, badge: Int
    ) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .sidebarIcon()
            }
            Spacer(minLength: 4)
            if badge > 0 {
                CountBadge(count: badge)
            }
        }
        .tag(tag)
        .modifier(rowClicks(tag))
    }
}

private extension User {
    /// The directory row's List-unique id: bare user ids share the Int
    /// namespace with channel rows' stream ids.
    var directoryRowId: String { "user-\(userId)" }
}
