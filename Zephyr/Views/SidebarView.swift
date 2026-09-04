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
    @AppStorage("dmSortOrder") private var dmSortOrder = DmSortOrder.lastMessage.rawValue
    @AppStorage("channelsAboveDMs") private var channelsAboveDMs = true
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
    }

    /// Double-clicking a sidebar entry opens it standalone in a new window.
    private func detachGesture(_ destination: Destination) -> some Gesture {
        TapGesture(count: 2).onEnded {
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
                    .simultaneousGesture(
                        detachGesture(.conversation(conversation.key)))
            }
            // Namespaced ids: a bare userId that numerically matches a
            // channel row's streamId would alias the two rows in the
            // List's flat selection registry (see TopicRowEntry).
            ForEach(directory.visible, id: \.directoryRowId) { user in
                let key = Unreads.dmKey(
                    participantIds: [user.userId], selfUserId: store.selfUserId)
                UserDirectMessageRow(store: store, user: user)
                    .tag(Destination.conversation(key))
                    .simultaneousGesture(detachGesture(.conversation(key)))
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
            ForEach(
                Array(store.channelFolders.enumerated()), id: \.element.id
            ) { index, folder in
                channelSection(
                    title: folder.name, id: "folder-\(folder.id)",
                    channels: channels(inFolder: folder.id),
                    showsJoin: index == 0)
            }
            channelSection(
                title: "Other channels", id: "folder-none",
                channels: channels(inFolder: nil))
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

    private func channels(inFolder folderId: Int?) -> [Subscription] {
        sortedSubscriptions.filter { store.channels[$0.streamId]?.folderId == folderId }
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

    var body: some View {
        ScrollViewReader { proxy in
            sidebarList
                .onChange(of: selection) {
                    if isFiltering {
                        revealOnFilterEnd = true
                    }
                }
                .onChange(of: isFiltering) { _, filtering in
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
                        badge: store.visibleUnreadCount)
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
                Label("Searching topics…", systemImage: "ellipsis")
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
    private func isActiveChannel(_ subscription: Subscription) -> Bool {
        if subscription.pinToTop ?? false { return true }
        if subscription.streamId == selectedStreamId { return true }
        if store.unreads.unreadCount(inChannel: subscription.streamId) > 0 { return true }
        return recentStreamIds.contains(subscription.streamId)
    }

    private var recentStreamIds: Set<Int> {
        var ids = Set<Int>()
        for conversation in store.conversations.conversations {
            if case .topic(let streamId, _) = conversation.key {
                ids.insert(streamId)
            }
        }
        return ids
    }

    /// The channel the selection lives in, if any.
    private var selectedStreamId: Int? {
        switch selection {
        case .channel(let streamId), .channelTopics(let streamId):
            streamId
        case .conversation(.topic(let streamId, _)):
            streamId
        default:
            nil
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
            expandedChannels.insert(streamId)
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
        let shown = hideInactive ? visible.filter { isActiveChannel($0.0) } : visible
        let hiddenCount = visible.count - shown.count
        if !visible.isEmpty {
            Section(isExpanded: expansion(id)) {
                ForEach(shown, id: \.0.id) { subscription, topicMatches in
                    let streamId = subscription.streamId
                    ChannelRow(
                        store: store, subscription: subscription,
                        isExpanded: expandedChannels.contains(streamId),
                        onToggle: isFiltering ? nil : { toggleChannel(streamId) })
                        .tag(Destination.channel(streamId: streamId))
                        .simultaneousGesture(
                            detachGesture(.channel(streamId: streamId)))
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
                    if isFiltering {
                        // Same rail as the unfiltered list; dotted when the
                        // 8-row cap hides further matches ("more below").
                        let matches = Array(topicMatches.prefix(8))
                        ForEach(topicRowEntries(matches, streamId: streamId)) { entry in
                            SidebarTopicRow(
                                store: store, streamId: streamId, topic: entry.topic,
                                rail: entry.index < matches.count - 1 ? .through
                                    : topicMatches.count > matches.count ? .dotted : .cap,
                                onRenamed: { refreshTopicsSoon(streamId) })
                                .tag(Destination.conversation(
                                    .topic(streamId: streamId, topic: entry.topic.name)))
                                .simultaneousGesture(
                                    detachGesture(.conversation(
                                        .topic(streamId: streamId, topic: entry.topic.name))))
                        }
                    } else if expandedChannels.contains(streamId) {
                        topicRows(for: streamId)
                    }
                }
                if hiddenCount > 0 {
                    SidebarExpanderRow(title: "Inactive channels… (\(hiddenCount))") {
                        expandedInactiveSections.insert(id)
                    }
                } else if !isFiltering && expandedInactiveSections.contains(id)
                    && visible.contains(where: { !isActiveChannel($0.0) }) {
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
                    onRenamed: { refreshTopicsSoon(streamId) })
                    .tag(Destination.conversation(
                        .topic(streamId: streamId, topic: entry.topic.name)))
                    .simultaneousGesture(
                        detachGesture(.conversation(
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
                            kind: showAll ? .cap : .dotted)
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

    private func toggleChannel(_ streamId: Int) {
        withAnimation(.snappy) {
            if expandedChannels.contains(streamId) {
                expandedChannels.remove(streamId)
            } else {
                expandedChannels.insert(streamId)
            }
        }
        // Refresh on every expand — topics move fast on active channels.
        if expandedChannels.contains(streamId) {
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
                // Unstyled: the sidebar tints Label icons with the accent
                // color itself, and dims them when the window is inactive
                // (an explicit .tint would stay lit).
                Image(systemName: icon)
            }
            Spacer(minLength: 4)
            if badge > 0 {
                CountBadge(count: badge)
            }
        }
        .tag(tag)
        .simultaneousGesture(detachGesture(tag))
    }
}

/// A section header whose + button stays invisible until the pointer
/// approaches — matching the hover-revealed disclosure triangle beside it.
/// (Touch platforms keep it visible; there's nothing to hover.)
private struct SectionHeaderWithAdd: View {
    let title: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
                // Filled variant: solid disc with a knocked-out plus.
                Image(systemName: "plus.circle.fill")
                    #if !os(macOS)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
                    #endif
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
            #if os(macOS)
            // Nudged in from the overlay scroller; invisible until hover.
            .padding(.trailing, 8)
            .opacity(hovering ? 1 : 0)
            #endif
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// A Recent Searches row with a hover-revealed remove button.
private struct RecentSearchRow: View {
    let query: SearchQuery
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label(query.displayDescription, systemImage: "magnifyingglass")
                .lineLimit(1)
            Spacer(minLength: 4)
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from Recent Searches")
            }
        }
        .onHover { isHovering = $0 }
    }
}

/// Compact one-line DM row: presence dot (placeholder until M2), name(s),
/// bot marker, unread badge.
/// An unsent draft: conversation title over a one-line text snippet.
private struct DraftRow: View {
    let store: PerAccountStore
    let conversationKey: ConversationKey
    let text: String

    private var title: String {
        if case .topic(let streamId, let topic) = conversationKey {
            let channel = store.channels[streamId]?.name
                ?? store.subscriptions[streamId]?.name ?? "?"
            let display = TopicName.displayName(topic)
            return "#\(channel) › \(display.isEmpty ? "general chat" : display)"
        }
        return conversationKey.displayTitle(in: store)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "pencil.line")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .sidebarRowPadding()
    }
}

/// The sidebar's activity footer while a "mark all messages as read"
/// sweep runs (Mail-style): spinner and running count batch by batch,
/// then the total — or a failure — lingering briefly.
private struct MarkReadStatusFooter: View {
    let sweep: PerAccountStore.MarkReadSweep

    var body: some View {
        HStack(spacing: 6) {
            switch sweep {
            case .running:
                ProgressView()
                    .controlSize(.mini)
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .dimsWhenWindowInactive()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .dimsWhenWindowInactive()
            }
            Text(label)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var label: String {
        switch sweep {
        case .running(let count):
            count > 0
                ? "Marking messages as read… \(count.formatted())"
                : "Marking messages as read…"
        case .finished(let count):
            count == 1
                ? "Marked 1 message as read"
                : "Marked \(count.formatted()) messages as read"
        case .failed:
            "Couldn't mark messages as read"
        }
    }
}

/// A quiet disclosure row ("More conversations…", "Inactive channels…").
private struct SidebarExpanderRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(title, systemImage: "ellipsis.circle")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sidebarRowPadding()
    }
}

/// A search suggestion as a list row (macOS): a token to commit, or the
/// free-text search itself. Rows rather than the field's suggestion menu,
/// so the sidebar stays clickable while suggestions show.
private struct SearchSuggestionRow: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sidebarRowPadding()
    }
}

/// A user with no conversation yet: same shape as `DirectMessageRow`, name
/// dimmed until there's history.
private struct UserDirectMessageRow: View {
    let store: PerAccountStore
    let user: User

    private var title: String {
        user.userId == store.selfUserId ? "Yourself" : user.fullName
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } icon: {
                PresenceDot(state: store.presenceState(of: user.userId))
            }
            Spacer(minLength: 4)
        }
        .sidebarRowPadding()
    }
}

private struct DirectMessageRow: View {
    let store: PerAccountStore
    let conversation: ConversationList.Conversation

    private var participantIds: [Int] {
        conversation.key.dmParticipantIds ?? []
    }

    private var isBot: Bool {
        participantIds.count == 1 && store.users[participantIds[0]]?.isBot == true
    }

    private var unreadCount: Int {
        store.unreads.unreadIds[conversation.key]?.count ?? 0
    }

    private var hasMention: Bool {
        guard let ids = store.unreads.unreadIds[conversation.key] else { return false }
        return !ids.isDisjoint(with: store.unreads.mentionIds)
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(conversation.key.displayTitle(in: store))
                    .fontWeight(unreadCount > 0 ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                PresenceDot(state: store.presenceState(of: participantIds.first ?? 0))
            }
            Spacer(minLength: 4)
            // Bot marker joins the trailing icon stack, like channel locks.
            if isBot {
                Image(systemName: "cpu")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .help("Bot")
            }
            if hasMention {
                Text("@")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.tint, in: .circle)
                    .dimsWhenWindowInactive()
            } else if unreadCount > 0 {
                CountBadge(count: unreadCount)
            }
        }
        .sidebarRowPadding()
    }
}

/// Sidebar state icons (muted bell, lock, followed, resolved): ~50%
/// larger than the caption2 they debuted at.
private var stateIconFont: Font {
    #if os(macOS)
    .system(size: 15)
    #else
    .callout
    #endif
}

/// Web-style channel row: disclosure triangle for inline topics, colored
/// type glyph (globe/lock/#), name, badge.
private struct ChannelRow: View {
    let store: PerAccountStore
    let subscription: Subscription
    var isExpanded = false
    var onToggle: (() -> Void)?

    private var unreadCount: Int {
        store.unreads.unreadCount(inChannel: subscription.streamId)
    }

    private var channelColor: Color {
        subscription.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: subscription.streamId)
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(subscription.name)
                    .fontWeight(unreadCount > 0 && !subscription.muted ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "number")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(channelColor)
                    .dimsWhenWindowInactive()
            }
            Spacer(minLength: 4)
            // Trailing stack: state icons, badge, then the disclosure at
            // the far right.
            if subscription.muted {
                Image(systemName: "bell.slash.fill")
                    .font(stateIconFont)
                    .foregroundStyle(.tertiary)
                    .help("Muted channel")
            }
            if store.channels[subscription.streamId]?.inviteOnly == true {
                Image(systemName: "lock.fill")
                    .font(stateIconFont)
                    .foregroundStyle(.secondary)
                    .help("Private channel")
            }
            if unreadCount > 0 && !subscription.muted {
                CountBadge(count: unreadCount)
            }
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // macOS: compact, nudged in from the overlay
                        // scroller (which wins clicks while visible).
                        // iOS: the system sidebar chevron's size and shade,
                        // in a wide tap target kept row-height-neutral —
                        // a 44pt-tall frame inflated every channel row.
                        #if os(macOS)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 26, height: 26)
                        .padding(.trailing, 8)
                        #else
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 28)
                        #endif
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide topics" : "Show topics")
            }
        }
        .opacity(subscription.muted ? 0.6 : 1)
        .sidebarRowPadding()
    }
}

/// The topic thread rail, one segment per row in the Label icon column —
/// the same column as the channel's # icon, so alignment is the system's.
/// `.through` rows get a full tick, `.cap` ends the list with an L-shaped
/// foot pointing at the final topic, `.dotted` fades out at "All topics…".
enum TopicRailKind: Equatable {
    case through
    case cap
    case dotted
}

struct TopicRailTick: View {
    let color: Color
    let kind: TopicRailKind

    var body: some View {
        Group {
            switch kind {
            case .through:
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 24)
            case .cap:
                // └ — the foot overflows the 2pt frame to the right so the
                // vertical bar stays exactly on the rail line above it.
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: 14)
                    Capsule()
                        .fill(color)
                        .frame(width: 8, height: 2)
                        .offset(y: 12)
                }
                .frame(width: 2, height: 24, alignment: .topLeading)
            case .dotted:
                VStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        Capsule()
                            .fill(color)
                            .frame(width: 2, height: 3)
                    }
                }
            }
        }
        .dimsWhenWindowInactive()
    }
}

/// An indented topic row under an expanded channel.
private struct SidebarTopicRow: View {
    let store: PerAccountStore
    let streamId: Int
    let topic: ChannelTopic
    /// The thread-rail tick beside this row.
    var rail: TopicRailKind?
    /// Called after a rename is submitted, so the sidebar can refresh its
    /// topic cache once the server has applied the move.
    var onRenamed: (() -> Void)?

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showMove = false

    /// macOS's sidebar runs smaller than body; iOS keeps every row
    /// body-sized like Mail's.
    #if os(macOS)
    private static let topicFont = Font.callout
    #else
    private static let topicFont = Font.body
    #endif

    private var channelColor: Color {
        store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    private var key: ConversationKey {
        .topic(streamId: streamId, topic: topic.name)
    }

    private var unreadCount: Int {
        store.unreads.unreadIds[key]?.count ?? 0
    }

    private var hasMention: Bool {
        guard let ids = store.unreads.unreadIds[key] else { return false }
        return !ids.isDisjoint(with: store.unreads.mentionIds)
    }

    private var visibility: TopicVisibilityPolicy {
        store.topicVisibility(streamId: streamId, topic: topic.name)
    }

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(TopicName.displayName(topic.name).isEmpty
                    ? "general chat" : TopicName.displayName(topic.name))
                    .font(Self.topicFont.weight(unreadCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
            } icon: {
                if let rail {
                    TopicRailTick(color: channelColor, kind: rail)
                } else {
                    Color.clear.frame(width: 2)
                }
            }
            Spacer(minLength: 4)
            // State icons trail, like the channel lock.
            if visibility == .followed {
                Image(systemName: "plus.message.fill")
                    .font(stateIconFont)
                    .foregroundStyle(.tint)
                    .help("Followed topic — new messages notify you")
                    .popoverTip(TopicStateIconsTip())
                    .dimsWhenWindowInactive()
            }
            if TopicName.isResolved(topic.name) {
                Image(systemName: "checkmark.circle.fill")
                    .font(stateIconFont)
                    .foregroundStyle(.green)
                    .help("Resolved topic")
                    .dimsWhenWindowInactive()
            }
            if hasMention {
                Text("@")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(.tint, in: .circle)
                    .dimsWhenWindowInactive()
            } else if unreadCount > 0 {
                CountBadge(count: unreadCount)
            }
        }
        .sidebarRowPadding()
        .opacity(visibility == .muted ? 0.5 : 1)
        .contextMenu {
            Button(visibility == .muted ? "Unmute Topic" : "Mute Topic") {
                store.setTopicVisibility(
                    streamId: streamId, topic: topic.name,
                    policy: visibility == .muted ? .none : .muted)
            }
            Button(visibility == .followed ? "Unfollow Topic" : "Follow Topic") {
                store.setTopicVisibility(
                    streamId: streamId, topic: topic.name,
                    policy: visibility == .followed ? .none : .followed)
            }
            Button("Rename Topic…") {
                renameText = TopicName.displayName(topic.name)
                showRename = true
            }
            Button("Move Topic…") {
                showMove = true
            }
        }
        .alert("Rename Topic", isPresented: $showRename) {
            TextField("Topic", text: $renameText)
            Button("Rename") { renameTopic() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message in the topic moves to the new name.")
        }
        .sheet(isPresented: $showMove) {
            MoveTopicSheet(
                store: store,
                subject: .topic(streamId: streamId, name: topic.name, maxId: topic.maxId),
                onMoved: { onRenamed?() })
        }
    }

    /// Rename = move the whole topic, anchored at its newest message. A
    /// resolved topic stays resolved under its new name.
    private func renameTopic() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != TopicName.displayName(topic.name) else { return }
        let newName = TopicName.isResolved(topic.name)
            ? TopicName.resolvedPrefix + trimmed : trimmed
        store.moveMessage(topic.maxId, toTopic: newName, propagateMode: "change_all")
        onRenamed?()
    }
}

private extension User {
    /// The directory row's List-unique id: bare user ids share the Int
    /// namespace with channel rows' stream ids.
    var directoryRowId: String { "user-\(userId)" }
}

private extension View {
    /// A hair of macOS row breathing room; iOS keeps the system's
    /// native row metrics untouched.
    @ViewBuilder
    func sidebarRowPadding() -> some View {
        #if os(macOS)
        padding(.vertical, 1)
        #else
        self
        #endif
    }
}

/// Dims explicitly colored sidebar decorations when the window is
/// inactive, matching the system's automatic Label-icon behavior (which
/// covers only system-styled icons).
struct DimsWhenWindowInactive: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .grayscale(appearsActive ? 0 : 1)
            .opacity(appearsActive ? 1 : 0.55)
    }
}

extension View {
    func dimsWhenWindowInactive() -> some View {
        modifier(DimsWhenWindowInactive())
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        // Native sidebar counts (Mail's on both platforms): plain
        // secondary numbers, no capsule.
        Text("\(count)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// Channel-colored `#` (or lock) badge, used by feed/topic-list contexts.
struct ChannelBadge: View {
    let store: PerAccountStore
    let streamId: Int
    var size: CGFloat = 34

    var body: some View {
        let color = store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
        Image(systemName: store.channels[streamId]?.inviteOnly == true ? "lock.fill" : "number")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
    }
}

extension Color {
    /// Parses Zulip's subscription color strings ("#e79ab5").
    init?(zulipHex: String) {
        var hex = zulipHex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }

    /// A stable per-id hue for avatars/badges without server colors.
    static func stableColor(for id: Int) -> Color {
        Color(hue: Double((id &* 2654435761) % 360) / 360, saturation: 0.55, brightness: 0.75)
    }

    /// The inverse of `init(zulipHex:)`, for writing colors back.
    var zulipHexString: String {
        #if os(macOS)
        let platform = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let red = platform.redComponent
        let green = platform.greenComponent
        let blue = platform.blueComponent
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return String(
            format: "#%02x%02x%02x",
            Int((red * 255).rounded()), Int((green * 255).rounded()),
            Int((blue * 255).rounded()))
    }
}

/// "Change Color…": Zulip web's default stream palette plus a custom
/// picker. Picking a swatch applies immediately.
private struct ChannelColorSheet: View {
    let store: PerAccountStore
    let streamId: Int

    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color = .accentColor

    private static let palette = [
        "#76ce90", "#fae589", "#a6c7e5", "#e79ab5", "#bfd56f", "#f4ae55",
        "#b0a5fd", "#addfe5", "#f5ce6e", "#c2726a", "#94c849", "#bd86e5",
        "#ee7e4a", "#a6dcbf", "#95a5fd", "#53a063", "#9987e1", "#e4523d",
        "#c2c2c2", "#4f8de4", "#c6a8ad", "#e7cc4d", "#c8bebf", "#a47462",
    ]

    // Touch-sized swatches on iOS; compact pointer-sized wells on macOS.
    #if os(macOS)
    private nonisolated static let swatchSize: CGFloat = 24
    private nonisolated static let gridSpacing: CGFloat = 8
    #else
    private nonisolated static let swatchSize: CGFloat = 40
    private nonisolated static let gridSpacing: CGFloat = 10
    #endif

    private var title: String {
        guard let name = store.subscriptions[streamId]?.name else {
            return "Channel Color"
        }
        return "Channel Color: \(name)"
    }

    var body: some View {
        #if os(macOS)
        sheetContent
            .padding(16)
            .frame(width: 244)
            .onAppear(perform: seedCustomColor)
        #else
        // Half-height sheet: the content is compact, so the sheet
        // shouldn't climb to full screen (scrolls only if it must).
        ScrollView {
            sheetContent
                .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear(perform: seedCustomColor)
        #endif
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: Self.swatchSize)),
                    count: 6),
                spacing: Self.gridSpacing
            ) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        store.setChannelColor(streamId, hex: hex)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(zulipHex: hex) ?? .gray)
                            .frame(width: Self.swatchSize, height: Self.swatchSize)
                            .overlay {
                                if store.subscriptions[streamId]?.color?.lowercased() == hex {
                                    Image(systemName: "checkmark")
                                        .font(checkmarkFont)
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .touchTarget()
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorPicker("Custom", selection: $custom, supportsOpacity: false)
            #if os(macOS)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set") { applyCustomColor() }
                    .keyboardShortcut(.defaultAction)
            }
            #else
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                Button {
                    applyCustomColor()
                } label: {
                    Text("Set")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            #endif
        }
    }

    private var checkmarkFont: Font {
        #if os(macOS)
        .caption.bold()
        #else
        .body.bold()
        #endif
    }

    private func applyCustomColor() {
        store.setChannelColor(streamId, hex: custom.zulipHexString)
        dismiss()
    }

    private func seedCustomColor() {
        if let hex = store.subscriptions[streamId]?.color,
           let color = Color(zulipHex: hex) {
            custom = color
        }
    }
}
