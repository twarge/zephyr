import SwiftUI
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
    @Environment(AppModel.self) private var model

    @State private var collapsedSections: Set<String>
    @State private var expandedChannels: Set<Int>

    init(store: PerAccountStore, search: SidebarSearchModel, selection: Binding<Destination?>) {
        self.store = store
        self.search = search
        _selection = selection
        _collapsedSections = State(
            initialValue: AppStateStore.collapsedSections(for: store.accountId))
        _expandedChannels = State(
            initialValue: AppStateStore.expandedChannels(for: store.accountId))
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

    private var dmRows: [ConversationList.Conversation] {
        store.conversations.conversations.filter { conversation in
            guard case .dm = conversation.key else { return false }
            return matchesFilter(conversation.key.displayTitle(in: store))
        }
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

    var body: some View {
        List(selection: $selection) {
            if !isFiltering, !search.recentSearches.isEmpty {
                Section("Recent Searches", isExpanded: expansion("recents")) {
                    ForEach(search.recentSearches, id: \.self) { query in
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
            if !isFiltering {
                Section("Views", isExpanded: expansion("views")) {
                    viewRow("Combined feed", icon: "line.3.horizontal", tag: .combinedFeed, badge: 0)
                    viewRow(
                        "Mentions", icon: "at", tag: .mentions,
                        badge: store.unreads.mentionIds.count)
                    viewRow("Starred messages", icon: "star", tag: .starred, badge: 0)
                    viewRow(
                        "All channels", icon: "rectangle.stack", tag: .allChannels, badge: 0)
                }
            }
            Section("Direct messages", isExpanded: expansion("dms")) {
                if dmRows.isEmpty && !isFiltering {
                    Text("No recent direct messages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(dmRows) { conversation in
                    DirectMessageRow(store: store, conversation: conversation)
                        .tag(Destination.conversation(conversation.key))
                }
            }
            if store.channelFolders.isEmpty {
                channelSection(title: "Channels", id: "channels", channels: sortedSubscriptions)
            } else {
                ForEach(store.channelFolders) { folder in
                    channelSection(
                        title: folder.name, id: "folder-\(folder.id)",
                        channels: channels(inFolder: folder.id))
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
        // The suggestions popover's anchor sits directly under the search
        // field; inside the searchable subtree so it sees `isSearching`.
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchSuggestionsAnchor(search: search) {
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
        .onSubmit(of: .search) {
            runSearch(recordInRecents: true)
        }
        .onChange(of: search.tokens) {
            if !search.tokens.isEmpty {
                runSearch(recordInRecents: false)
            }
        }
        .onChange(of: search.filterText) {
            search.loadAllTopicsIfNeeded()
        }
        .onChange(of: expandedChannels) {
            AppStateStore.setExpandedChannels(expandedChannels, for: store.accountId)
        }
        .onChange(of: collapsedSections) {
            AppStateStore.setCollapsedSections(collapsedSections, for: store.accountId)
        }
        // The server switcher lives in the sidebar's toolbar area when more
        // than one server is signed in (⌘1…⌘9 also switch).
        .toolbar {
            if model.global.accounts.count > 1 {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        ForEach(
                            Array(model.global.accounts.prefix(9).enumerated()),
                            id: \.element.id
                        ) { index, account in
                            Button {
                                Task { await model.switchAccount(account.id) }
                            } label: {
                                if account.id == store.accountId {
                                    Label(serverLabel(account), systemImage: "checkmark")
                                } else {
                                    Text(serverLabel(account))
                                }
                            }
                            .keyboardShortcut(
                                KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(store.realmName
                                ?? store.connection.realmURL.host() ?? "Server")
                                .font(.callout.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .help("Switch server (⌘1–⌘\(min(model.global.accounts.count, 9)))")
                }
            }
        }
    }

    private static var searchPlacement: SearchFieldPlacement {
        #if os(macOS)
        return .sidebar
        #else
        return .automatic
        #endif
    }

    private func serverLabel(_ account: Account) -> String {
        account.realmName ?? account.realmURL.host() ?? account.email
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

    @ViewBuilder
    private func channelSection(title: String, id: String, channels: [Subscription]) -> some View {
        let visible = visibleChannels(channels)
        if !visible.isEmpty {
            Section(title, isExpanded: expansion(id)) {
                ForEach(visible, id: \.0.id) { subscription, topicMatches in
                    let streamId = subscription.streamId
                    ChannelRow(
                        store: store, subscription: subscription,
                        isExpanded: expandedChannels.contains(streamId),
                        onToggle: isFiltering ? nil : { toggleChannel(streamId) })
                        .tag(Destination.channel(streamId: streamId))
                        .contextMenu {
                            Button(subscription.muted ? "Unmute Channel" : "Mute Channel") {
                                store.setChannelMuted(streamId, muted: !subscription.muted)
                            }
                            Button("Unsubscribe") {
                                store.unsubscribe(fromChannel: subscription.name)
                            }
                        }
                    if isFiltering {
                        ForEach(topicMatches.prefix(8), id: \.name) { topic in
                            SidebarTopicRow(store: store, streamId: streamId, topic: topic)
                                .tag(Destination.conversation(
                                    .topic(streamId: streamId, topic: topic.name)))
                        }
                    } else if expandedChannels.contains(streamId) {
                        topicRows(for: streamId)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func topicRows(for streamId: Int) -> some View {
        if let topics = search.channelTopics[streamId] {
            ForEach(topics.prefix(Self.maxInlineTopics), id: \.name) { topic in
                SidebarTopicRow(store: store, streamId: streamId, topic: topic)
                    .tag(Destination.conversation(
                        .topic(streamId: streamId, topic: topic.name)))
            }
            if topics.count > Self.maxInlineTopics {
                Text("All topics…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                    .tag(Destination.channelTopics(streamId: streamId))
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.leading, 26)
        }
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
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 4)
            if badge > 0 {
                CountBadge(count: badge)
            }
        }
        .tag(tag)
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
            PresenceDot(state: store.presenceState(of: participantIds.first ?? 0))
            Text(conversation.key.displayTitle(in: store))
                .font(.body.weight(unreadCount > 0 ? .semibold : .regular))
                .lineLimit(1)
            if isBot {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hasMention {
                Text("@")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.tint, in: .circle)
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

    private var glyph: String {
        let stream = store.channels[subscription.streamId]
        if stream?.inviteOnly == true { return "lock.fill" }
        if stream?.isWebPublic == true { return "globe" }
        return "number"
    }

    private var color: Color {
        subscription.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: subscription.streamId)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .frame(width: 12)
                .help(isExpanded ? "Hide topics" : "Show topics")
            }
            Image(systemName: glyph)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(subscription.name)
                .font(.body.weight(unreadCount > 0 && !subscription.muted ? .semibold : .regular))
                .lineLimit(1)
            if subscription.muted {
                Image(systemName: "bell.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if unreadCount > 0 && !subscription.muted {
                CountBadge(count: unreadCount)
            }
        }
        .opacity(subscription.muted ? 0.6 : 1)
        .padding(.vertical, 1)
    }
}

/// An indented topic row under an expanded channel.
private struct SidebarTopicRow: View {
    let store: PerAccountStore
    let streamId: Int
    let topic: ChannelTopic

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

    var body: some View {
        HStack(spacing: 6) {
            if TopicName.isResolved(topic.name) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            Text(TopicName.displayName(topic.name).isEmpty
                ? "general chat" : TopicName.displayName(topic.name))
                .font(.callout.weight(unreadCount > 0 ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hasMention {
                Text("@")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(.tint, in: .circle)
            } else if unreadCount > 0 {
                CountBadge(count: unreadCount)
            }
        }
        .padding(.leading, 26)
        .padding(.vertical, 1)
    }
}

/// The web app's gray rounded count badge.
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
}
