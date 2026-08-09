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
    @State private var showOfflineUsers = false
    @State private var expandedInactiveSections: Set<String> = []
    /// Channels whose topic list shows everything (past the inline cap).
    @State private var expandedAllTopics: Set<Int> = []
    /// The channel being renamed via its context menu, if any.
    @State private var renameChannelId: Int?
    @State private var renameChannelText = ""
    /// The channel whose color picker is open, if any.
    @State private var colorChannelId: Int?

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
    private var usersWithoutConversation: [User] {
        let existingKeys = Set(
            store.conversations.conversations.compactMap { conversation -> ConversationKey? in
                if case .dm = conversation.key { return conversation.key }
                return nil
            })
        let users = store.users.values
            .filter { $0.isActive != false && !$0.isBot }
            .filter {
                !existingKeys.contains(
                    Unreads.dmKey(participantIds: [$0.userId], selfUserId: store.selfUserId))
            }
            .filter { user in
                matchesFilter(
                    user.userId == store.selfUserId ? "Yourself" : user.fullName)
            }
        // Yourself pins first (a self-DM is notes-to-self, like the web app).
        func selfFirst(_ a: User, _ b: User) -> Bool? {
            if a.userId == store.selfUserId { return true }
            if b.userId == store.selfUserId { return false }
            return nil
        }
        if sortByActivity {
            return users.sorted {
                if let pinned = selfFirst($0, $1) { return pinned }
                let (a, b) = (
                    store.presence.lastSeen(of: $0.userId) ?? .distantPast,
                    store.presence.lastSeen(of: $1.userId) ?? .distantPast)
                if a != b { return a > b }
                return $0.fullName.localizedCaseInsensitiveCompare($1.fullName)
                    == .orderedAscending
            }
        }
        return users.sorted {
            if let pinned = selfFirst($0, $1) { return pinned }
            return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
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
    private var visibleDirectoryUsers: [User] {
        if isFiltering || showOfflineUsers { return usersWithoutConversation }
        return usersWithoutConversation.filter {
            store.presenceState(of: $0.userId) != .offline
        }
    }

    private var hiddenDirectoryCount: Int {
        usersWithoutConversation.count - visibleDirectoryUsers.count
    }

    private var sortedSubscriptions: [Subscription] {
        store.subscriptions.values
            .sorted { a, b in
                let aPinned = a.pinToTop ?? false
                let bPinned = b.pinToTop ?? false
                if aPinned != bPinned { return aPinned }
                if a.muted != b.muted { return b.muted }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
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

    var body: some View {
        List(selection: $selection) {
            if !isFiltering {
                Section("Views", isExpanded: expansion("views")) {
                    viewRow(
                        "Recent", icon: "clock", tag: .recentConversations,
                        badge: 0)
                        .popoverTip(DetachWindowTip())
                    viewRow(
                        "Combined", icon: "line.3.horizontal", tag: .combinedFeed,
                        badge: store.unreads.totalCount)
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
            Section(isExpanded: expansion("dms")) {
                ForEach(dmRows) { conversation in
                    DirectMessageRow(store: store, conversation: conversation)
                        .tag(Destination.conversation(conversation.key))
                        .simultaneousGesture(
                            detachGesture(.conversation(conversation.key)))
                }
                ForEach(visibleDirectoryUsers) { user in
                    let key = Unreads.dmKey(
                        participantIds: [user.userId], selfUserId: store.selfUserId)
                    UserDirectMessageRow(store: store, user: user)
                        .tag(Destination.conversation(key))
                        .simultaneousGesture(detachGesture(.conversation(key)))
                }
                if hiddenDirectoryCount > 0 {
                    SidebarExpanderRow(
                        title: "More conversations… (\(hiddenDirectoryCount))"
                    ) {
                        showOfflineUsers = true
                    }
                } else if showOfflineUsers && !isFiltering
                    && !usersWithoutConversation.isEmpty {
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
            if isFiltering && search.loadingAllTopics {
                Label("Searching topics…", systemImage: "ellipsis")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        // Return capture lives inside the searchable subtree so it sees
        // `isSearching`.
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchReturnCapture(search: search) {
                runSearch(recordInRecents: true)
            }
        }
        .listStyle(.sidebar)
        // One field, two roles: typing filters the sidebar live (suggestions
        // pop over beside the field); committed tokens search immediately;
        // Return searches the free text and records it in Recent Searches.
        .searchable(
            text: $search.filterText, tokens: $search.tokens,
            placement: Self.searchPlacement, prompt: "Filter or search"
        ) { token in
            Text(token.bubbleText)
        }
        // Native suggestions: the system anchors these to the search field
        // itself, wherever the field lives (window toolbar on macOS).
        // Picking one commits it into the tokens binding and clears the
        // typed text; the tokens onChange below runs the search.
        .searchSuggestions {
            ForEach(search.suggestions) { token in
                Label(token.suggestionTitle, systemImage: token.suggestionIcon)
                    .searchCompletion(token)
            }
        }
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            runSearch(recordInRecents: true)
        }
        .onAppear {
            // The keyboard router's / shortcut focuses the search field;
            // media selection blurs it so Space can Quick Look.
            let focus = $searchFocused
            keys.focusSearch = { focus.wrappedValue = true }
            keys.blurSearch = { focus.wrappedValue = false }
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
        .sheet(
            isPresented: Binding(
                get: { colorChannelId != nil },
                set: { if !$0 { colorChannelId = nil } })
        ) {
            if let streamId = colorChannelId {
                ChannelColorSheet(store: store, streamId: streamId)
            }
        }
        .onChange(of: expandedChannels) {
            AppStateStore.setExpandedChannels(expandedChannels, for: store.accountId)
        }
        .onChange(of: collapsedSections) {
            AppStateStore.setCollapsedSections(collapsedSections, for: store.accountId)
        }
        .onChange(of: model.global.accounts.count, initial: true) {
            PerWindowServersTip.hasMultipleAccounts = model.global.accounts.count > 1
        }
    }


    private static var searchPlacement: SearchFieldPlacement {
        // .automatic: the window toolbar on macOS (Mail-style), the
        // sidebar's navigation bar on iPad.
        .automatic
    }

    /// Runs the current query. Return finalizes it: the query is recorded in
    /// Recent Searches, the field clears back to filter duty, and the
    /// recorded row (tagged with the same query) highlights as the
    /// selection. Intermediate token-commit searches show results but leave
    /// the field composing and don't touch recents.
    private func runSearch(recordInRecents: Bool) {
        let query = SearchQuery(tokens: search.tokens, text: search.filterText)
        guard !query.isEmpty else { return }
        if recordInRecents {
            search.recordSearch(query)
            search.filterText = ""
            search.tokens = []
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

    /// A channel is "active" when pinned, carrying unreads, or present in
    /// the recency list; the rest hide behind "Inactive channels…".
    private func isActiveChannel(_ subscription: Subscription) -> Bool {
        if subscription.pinToTop ?? false { return true }
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
                            Button("Mark All Messages as Unread") {
                                keys.readMarkingPaused = true
                                store.markChannelUnread(streamId)
                            }
                            Divider()
                            Button("Rename Channel…") {
                                renameChannelText = subscription.name
                                renameChannelId = streamId
                            }
                            Button("Change Color…") {
                                colorChannelId = streamId
                            }
                            Button("Unsubscribe") {
                                store.unsubscribe(fromChannel: subscription.name)
                            }
                        }
                    if isFiltering {
                        // Same rail as the unfiltered list; dotted when the
                        // 8-row cap hides further matches ("more below").
                        let matches = Array(topicMatches.prefix(8))
                        ForEach(Array(matches.enumerated()), id: \.element.name) { index, topic in
                            SidebarTopicRow(
                                store: store, streamId: streamId, topic: topic,
                                rail: index < matches.count - 1 ? .through
                                    : topicMatches.count > matches.count ? .dotted : .cap,
                                onRenamed: { refreshTopicsSoon(streamId) })
                                .tag(Destination.conversation(
                                    .topic(streamId: streamId, topic: topic.name)))
                                .simultaneousGesture(
                                    detachGesture(.conversation(
                                        .topic(streamId: streamId, topic: topic.name))))
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

    @ViewBuilder
    private func topicRows(for streamId: Int) -> some View {
        if let topics = search.channelTopics[streamId] {
            let showAll = expandedAllTopics.contains(streamId)
            let shown = showAll ? topics : Array(topics.prefix(Self.maxInlineTopics))
            let hasMore = topics.count > Self.maxInlineTopics
            ForEach(Array(shown.enumerated()), id: \.element.name) { index, topic in
                SidebarTopicRow(
                    store: store, streamId: streamId, topic: topic,
                    rail: index == shown.count - 1 && !hasMore ? .cap : .through,
                    onRenamed: { refreshTopicsSoon(streamId) })
                    .tag(Destination.conversation(
                        .topic(streamId: streamId, topic: topic.name)))
                    .simultaneousGesture(
                        detachGesture(.conversation(
                            .topic(streamId: streamId, topic: topic.name))))
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
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
            .help(help)
            #if os(macOS)
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
        .padding(.vertical, 1)
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
        .padding(.vertical, 1)
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
        .padding(.vertical, 1)
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
        .padding(.vertical, 1)
    }
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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Muted channel")
            }
            if store.channels[subscription.streamId]?.inviteOnly == true {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Private channel")
            }
            if unreadCount > 0 && !subscription.muted {
                CountBadge(count: unreadCount)
            }
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // Same glyph, comfortable hit area — nudged in from
                        // the edge so the overlay scroller (which wins
                        // clicks while visible) doesn't cover the target.
                        .frame(width: 26, height: 26)
                        .padding(.trailing, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide topics" : "Show topics")
            }
        }
        .opacity(subscription.muted ? 0.6 : 1)
        .padding(.vertical, 1)
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
                    .font(.callout.weight(unreadCount > 0 ? .semibold : .regular))
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
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .help("Followed topic — new messages notify you")
                    .popoverTip(TopicStateIconsTip())
                    .dimsWhenWindowInactive()
            }
            if TopicName.isResolved(topic.name) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
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
        .padding(.vertical, 1)
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
        }
        .alert("Rename Topic", isPresented: $showRename) {
            TextField("Topic", text: $renameText)
            Button("Rename") { renameTopic() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message in the topic moves to the new name.")
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

/// The web app's gray rounded count badge.
/// Dims explicitly colored sidebar decorations when the window is
/// inactive, matching the system's automatic Label-icon behavior (which
/// covers only system-styled icons).
struct DimsWhenWindowInactive: ViewModifier {
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .grayscale(controlActiveState == .inactive ? 1 : 0)
            .opacity(controlActiveState == .inactive ? 0.55 : 1)
        #else
        content
        #endif
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
        Text("\(count)")
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Channel Color")
                .font(.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(28)), count: 6), spacing: 8
            ) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        store.setChannelColor(streamId, hex: hex)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(zulipHex: hex) ?? .gray)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if store.subscriptions[streamId]?.color?.lowercased() == hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                ColorPicker("Custom", selection: $custom, supportsOpacity: false)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set") {
                    store.setChannelColor(streamId, hex: custom.zulipHexString)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 244)
        .onAppear {
            if let hex = store.subscriptions[streamId]?.color,
               let color = Color(zulipHex: hex) {
                custom = color
            }
        }
    }
}
