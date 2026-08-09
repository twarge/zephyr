import SwiftUI
import TipKit
#if canImport(Translation)
import Translation
#endif
import ZulipAPI
import ZulipContent
import ZulipModel

/// The scrolling message feed shared by topic/DM transcripts and the channel
/// feed. Flat, left-aligned, sender-grouped rows with day separators; the
/// channel feed additionally interleaves clickable topic headers.
///
/// Scroll behavior: the bottom-most visible row is tracked as the scroll
/// anchor, which keeps the viewport stable while older history prepends; the
/// anchor advances to new messages only when already at the bottom.
struct MessageFeedList: View {
    /// How conversation-run headers render: hidden (single-topic/DM
    /// transcripts), topic name only (a channel's own feed), or
    /// "#channel › topic" (cross-channel views like Mentions).
    enum HeaderMode {
        case hidden
        case topicOnly
        case channelAndTopic
    }

    let store: PerAccountStore
    let model: MessageListModel
    let cache: MessageContentCache
    var headerMode = HeaderMode.hidden
    /// Search results: render `match_content` (server-marked term highlights)
    /// instead of the plain content.
    var useMatchHighlights = false
    var onHeaderTap: ((ConversationKey) -> Void)?
    var onNewMessages: (() -> Void)?
    /// Cross-conversation feeds: a message scrolled into view is marked
    /// read (batched).
    var marksReadOnView = false

    @Environment(KeyboardRouter.self) private var keys
    @State private var anchorId: String?
    @State private var nearBottom = true
    @State private var quickLook = FeedQuickLook()
    @State private var pendingReadIds: Set<Int> = []
    @State private var readFlushTask: Task<Void, Never>?
    /// Bumped when the viewport is detected outside the content bounds;
    /// the reader responds with an imperative rescue scroll.
    @State private var recoverNonce = 0

    init(
        store: PerAccountStore, model: MessageListModel, cache: MessageContentCache,
        headerMode: HeaderMode = .hidden, useMatchHighlights: Bool = false,
        onHeaderTap: ((ConversationKey) -> Void)? = nil,
        onNewMessages: (() -> Void)? = nil,
        marksReadOnView: Bool = false
    ) {
        self.store = store
        self.model = model
        self.cache = cache
        self.headerMode = headerMode
        self.useMatchHighlights = useMatchHighlights
        self.onHeaderTap = onHeaderTap
        self.onNewMessages = onNewMessages
        self.marksReadOnView = marksReadOnView
        // The scroll target must be known BEFORE the first layout pass:
        // an onAppear write lands after it, re-targeting the lazy stack
        // mid-estimation — which could park the viewport in unrealized
        // space (a blank transcript until a resize forced re-layout).
        _anchorId = State(initialValue:
            model.firstUnreadMarkerId != nil ? "unread-marker" : Self.bottomAnchorId)
    }

    private var outboxMessages: [OutboxMessage] {
        store.outbox.filter {
            $0.destination.matches(narrow: model.narrow, selfUserId: store.selfUserId)
        }
    }

    /// Names of people typing in this exact conversation (topic/DM narrows).
    private var typistNames: [String]? {
        let key: ConversationKey?
        switch model.narrow {
        case .topic(let streamId, let topic):
            key = .topic(streamId: streamId, topic: topic)
        case .dm(let userIds):
            key = Unreads.dmKey(participantIds: userIds, selfUserId: store.selfUserId)
        default:
            key = nil
        }
        guard let key else { return nil }
        return store.typing.typistIds(in: key)
            .compactMap { store.users[$0]?.fullName }
    }

    /// The sentinel row at the very end of the stack — below the last
    /// message, outbox rows, and typing indicator — so "scroll to bottom"
    /// really lands at the bottom.
    private static let bottomAnchorId = "feed-bottom"

    private struct FeedGeometry: Equatable {
        var nearBottom: Bool
        var lost: Bool
    }

    private enum Item: Identifiable {
        case daySeparator(String)
        case conversationHeader(key: ConversationKey, firstMessageId: Int)
        case unreadMarker
        case message(Message, showHeader: Bool)

        var id: String {
            switch self {
            case .daySeparator(let label): "day-\(label)"
            case .conversationHeader(_, let firstMessageId): "hdr-\(firstMessageId)"
            case .unreadMarker: "unread-marker"
            case .message(let message, _): "msg-\(message.id)"
            }
        }
    }

    /// Messages interleaved with day separators (and conversation headers in
    /// multi-conversation feeds); consecutive messages from the same sender
    /// within 5 minutes coalesce under one header.
    private var items: [Item] {
        var out: [Item] = []
        var lastDay: DateComponents?
        var lastKey: ConversationKey?
        var lastSender: Int?
        var lastTimestamp = 0
        for message in model.messages {
            let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
            let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
            if day != lastDay {
                out.append(.daySeparator(daySeparatorLabel(for: date)))
                lastDay = day
                lastSender = nil
            }
            if headerMode != .hidden,
               let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId),
               key != lastKey {
                out.append(.conversationHeader(key: key, firstMessageId: message.id))
                lastKey = key
                lastSender = nil
            }
            if message.id == model.firstUnreadMarkerId {
                out.append(.unreadMarker)
                lastSender = nil  // The run restarts under the marker.
            }
            let showHeader = message.senderId != lastSender || message.timestamp - lastTimestamp > 300
            out.append(.message(message, showHeader: showHeader))
            lastSender = message.senderId
            lastTimestamp = message.timestamp
        }
        return out
    }

    /// One pinnable run of the feed: a conversation header plus the rows
    /// under it. The header sticks to the top while its rows scroll and is
    /// pushed out by the next section's header (LazyVStack pinnedViews).
    private struct FeedSection: Identifiable {
        var headerKey: ConversationKey?
        var headerFirstMessageId: Int?
        var items: [Item] = []
        var id: String { headerFirstMessageId.map { "sec-\($0)" } ?? "sec-lead" }
    }

    /// `items` split at conversation headers; header-less feeds (topic/DM
    /// transcripts) collapse to one anonymous section.
    private var sections: [FeedSection] {
        var out: [FeedSection] = []
        var current = FeedSection()
        for item in items {
            if case .conversationHeader(let key, let firstMessageId) = item {
                if current.headerKey != nil || !current.items.isEmpty {
                    out.append(current)
                }
                current = FeedSection(headerKey: key, headerFirstMessageId: firstMessageId)
            } else {
                current.items.append(item)
            }
        }
        if current.headerKey != nil || !current.items.isEmpty {
            out.append(current)
        }
        return out
    }

    /// Empty enough to replace the transcript with a centered placeholder
    /// (a typing indicator still counts as content).
    private var isEmptyFeed: Bool {
        model.messages.isEmpty && outboxMessages.isEmpty
            && (typistNames?.isEmpty ?? true)
    }

    var body: some View {
        Group {
            if isEmptyFeed {
                // Outside the bottom-anchored scroll view, so it centers in
                // the full height instead of hugging the bottom.
                ContentUnavailableView("No Messages", systemImage: "bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No scroll-follow on selection: programmatic scrolls were
                // fighting image focus, and selection reads fine without it.
                ScrollViewReader { proxy in
                    feedScrollView
                        .onAppear {
                            // The binding (inner onAppear) has already put
                            // the target at the viewport bottom; once layout
                            // settles, nudge it up to the upper quarter.
                            let target: String?
                            if let highlight = keys.highlightMessageId,
                               model.messages.contains(where: { $0.id == highlight }) {
                                target = "msg-\(highlight)"
                            } else if model.firstUnreadMarkerId != nil {
                                target = "unread-marker"
                            } else {
                                target = nil
                            }
                            guard let target else {
                                // Bottom-anchored open: deferred insurance
                                // passes — no-ops when the initial position
                                // landed, a rescue when estimate drift
                                // parked the viewport in unrealized space.
                                Task { @MainActor in
                                    for delay in [300, 700] {
                                        try? await Task.sleep(for: .milliseconds(delay))
                                        guard nearBottom else { return }
                                        proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                                    }
                                }
                                return
                            }
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.25))
                                }
                            }
                            scheduleHighlightClear()
                        }
                        // Blank-state recovery: the geometry observer bumps
                        // the nonce; the proxy scroll is imperative, so it
                        // can't be coalesced away like a binding rewrite
                        // (nil→same-value collapsed to no change, which is
                        // why recovery used to silently do nothing).
                        .onChange(of: recoverNonce) {
                            let target = anchorId ?? Self.bottomAnchorId
                            Task { @MainActor in
                                for delay in [50, 350] {
                                    try? await Task.sleep(for: .milliseconds(delay))
                                    proxy.scrollTo(target, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: keys.highlightMessageId) { _, newId in
                            // Same-conversation message links scroll live.
                            guard let newId,
                                  model.messages.contains(where: { $0.id == newId })
                            else { return }
                            proxy.scrollTo("msg-\(newId)", anchor: .center)
                            scheduleHighlightClear()
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !nearBottom || !model.haveNewest {
                                Button {
                                    if model.haveNewest {
                                        scrollToBottomSettled(proxy)
                                    } else {
                                        Task {
                                            await model.jumpToNewest()
                                            scrollToBottomSettled(proxy)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 26))
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(.tint)
                                        .background(.bar, in: .circle)
                                }
                                .buttonStyle(.plain)
                                .padding(12)
                                .help("Jump to latest messages")
                            }
                        }
                        .onChange(of: outboxMessages.count) { old, new in
                            // Sending while viewing history jumps to the
                            // newest messages so the send is visible.
                            guard new > old, !model.haveNewest else { return }
                            Task {
                                await model.jumpToNewest()
                                scrollToBottomSettled(proxy)
                            }
                        }
                }
            }
        }
        .environment(quickLook)
        .quickLookPreview(Bindable(quickLook).selection, in: quickLook.items)
        .onChange(of: quickLook.selection) { _, selection in
            if selection != nil {
                QuickLookNavigationTip().invalidate(reason: .actionPerformed)
            }
        }
        .onAppear {
            keys.activeFeed = model
            keys.readMarkingPaused = false
            quickLook.orderedNodes = { orderedImageNodes() }
        }
        .onDisappear {
            if keys.activeFeed === model {
                keys.activeFeed = nil
                keys.selectedMessageId = nil
            }
        }
    }

    @ViewBuilder
    private func feedRow(_ item: Item) -> some View {
        switch item {
        case .daySeparator(let label):
            // Web-style: a rule from the left edge up to the date, date on
            // the right in small caps.
            HStack(spacing: 8) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                Text(label)
                    .font(.body.weight(.semibold).smallCaps())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
        case .conversationHeader(let key, _):
            // Headers are hoisted into section headers by `sections`; this
            // case is unreachable but keeps the switch exhaustive.
            ConversationHeaderRow(
                store: store, conversationKey: key,
                includeChannel: headerMode == .channelAndTopic,
                onTap: onHeaderTap)
        case .unreadMarker:
            HStack(spacing: 8) {
                Rectangle()
                    .fill(.red.opacity(0.45))
                    .frame(height: 1)
                Text("NEW")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
            }
            .padding(.vertical, 6)
        case .message(let message, let showHeader):
            MessageRow(
                store: store, message: message,
                showHeader: showHeader, cache: cache,
                useMatchHighlights: useMatchHighlights,
                isKeySelected: keys.selectedMessageId == message.id,
                isLinkTarget: keys.highlightMessageId == message.id)
                // Actual viewport visibility, not lazy-stack realization
                // (which includes off-screen rows). The low threshold lets
                // rows taller than the window still count once a fifth is
                // shown.
                .onScrollVisibilityChange(threshold: 0.2) { visible in
                    if visible { noteSeen(message) }
                }
        }
    }

    /// Pins the feed to the true bottom. Lazy row heights are estimates
    /// until rows realize, so the binding's scroll can land short —
    /// corrective passes after layout settles converge on the real bottom.
    /// Bails if the user scrolls away mid-settle (the position binding
    /// leaves the sentinel).
    private func scrollToBottomSettled(_ proxy: ScrollViewProxy) {
        anchorId = Self.bottomAnchorId
        Task { @MainActor in
            for delay in [250, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard anchorId == Self.bottomAnchorId else { return }
                proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
            }
        }
    }

    /// Seen-in-view read marking, batched so a scroll doesn't spam the
    /// flags endpoint.
    private func noteSeen(_ message: Message) {
        guard marksReadOnView, !keys.readMarkingPaused,
              !(message.flags ?? []).contains("read") else { return }
        pendingReadIds.insert(message.id)
        readFlushTask?.cancel()
        readFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let ids = Array(pendingReadIds)
            pendingReadIds = []
            store.markMessagesRead(ids: ids)
        }
    }

    /// The message-link flash fades after a beat.
    private func scheduleHighlightClear() {
        guard let target = keys.highlightMessageId else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if keys.highlightMessageId == target {
                withAnimation(.easeOut(duration: 0.6)) {
                    keys.highlightMessageId = nil
                }
            }
        }
    }

    /// Every image in the transcript, in message order — the Quick Look
    /// session's navigation set.
    private func orderedImageNodes() -> [ImageNode] {
        var nodes: [ImageNode] = []
        for message in model.messages {
            for block in cache.content(for: message).blocks {
                switch block {
                case .image(let node):
                    nodes.append(node)
                case .imageGallery(let gallery):
                    nodes.append(contentsOf: gallery)
                default:
                    break
                }
            }
        }
        return nodes
    }

    private var feedScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !model.haveOldest && !model.messages.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear {
                            Task { await model.fetchOlder() }
                        }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            feedRow(item)
                        }
                    } header: {
                        if let key = section.headerKey,
                           let firstMessageId = section.headerFirstMessageId {
                            ConversationHeaderRow(
                                store: store, conversationKey: key,
                                includeChannel: headerMode == .channelAndTopic,
                                onTap: onHeaderTap)
                                // Opaque backing while pinned: the header's
                                // own tint is translucent, and rows would
                                // ghost through it.
                                .background(.bar)
                                .id("hdr-\(firstMessageId)")
                        }
                    }
                }
                if !model.haveNewest && !model.messages.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear {
                            Task { await model.fetchNewer() }
                        }
                }
                if model.haveNewest {
                    ForEach(outboxMessages) { outboxMessage in
                        OutboxRow(store: store, message: outboxMessage)
                            .id("out-\(outboxMessage.id)")
                    }
                }
                if let names = typistNames, !names.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis.bubble")
                            .foregroundStyle(.secondary)
                        Text("\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") typing…")
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.vertical, 6)
                    .padding(.leading, 42)
                }
                // Doubles as the feed's bottom breathing room (in place of
                // stack padding, which the scroll anchor couldn't reach).
                Color.clear
                    .frame(height: 12)
                    .id(Self.bottomAnchorId)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $anchorId, anchor: .bottom)
        // One geometry observer for both signals (two separate ones
        // double-fired per frame): bottom proximity, and the blank-view
        // failure mode — the viewport parked outside the content bounds
        // (offset never re-clamped), fixed by re-asserting the anchor
        // instead of waiting for a window resize to force re-layout.
        .onScrollGeometryChange(for: FeedGeometry.self) { geometry in
            FeedGeometry(
                nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 60,
                lost: geometry.contentSize.height > 0
                    && (geometry.visibleRect.minY >= geometry.contentSize.height - 1
                        || geometry.visibleRect.maxY <= 0))
        } action: { old, new in
            nearBottom = new.nearBottom
            if new.lost, !old.lost {
                recoverNonce &+= 1
            }
        }
        .onAppear {
            // Marker/bottom targets are the @State initial value (set in
            // init, before the first layout); only a message-link
            // highlight overrides here.
            if let highlight = keys.highlightMessageId,
               model.messages.contains(where: { $0.id == highlight }) {
                anchorId = "msg-\(highlight)"
            }
        }
        .onChange(of: model.messages.last?.id) { _, newLastId in
            guard newLastId != nil else { return }
            if nearBottom {
                anchorId = Self.bottomAnchorId
            }
            onNewMessages?()
        }
        .onChange(of: outboxMessages.last?.id) { _, newLastId in
            if newLastId != nil, nearBottom {
                anchorId = Self.bottomAnchorId
            }
        }
    }
}

/// translationPresentation where the framework exists; a no-op elsewhere
/// (e.g. visionOS).
private struct TranslationSheet: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if canImport(Translation) && !os(visionOS)
        content.translationPresentation(isPresented: $isPresented, text: text)
        #else
        content
        #endif
    }
}

/// A recipient bar in the web app's style: full-width, tinted with the
/// channel's color, leading colored channel glyph.
private struct ConversationHeaderRow: View {
    let store: PerAccountStore
    let conversationKey: ConversationKey
    let includeChannel: Bool
    let onTap: ((ConversationKey) -> Void)?

    private var streamId: Int? {
        if case .topic(let id, _) = conversationKey { return id }
        return nil
    }

    private var channelColor: Color {
        guard let streamId else { return .gray }
        return store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    private var glyph: String {
        guard let streamId else { return "person.fill" }
        let stream = store.channels[streamId]
        if stream?.inviteOnly == true { return "lock.fill" }
        if stream?.isWebPublic == true { return "globe" }
        return "number"
    }

    private var isResolved: Bool {
        if case .topic(_, let topic) = conversationKey {
            return TopicName.isResolved(topic)
        }
        return false
    }

    private var label: String {
        switch conversationKey {
        case .topic(let streamId, let topic):
            let display = TopicName.displayName(topic).isEmpty
                ? "general chat" : TopicName.displayName(topic)
            guard includeChannel else { return display }
            let channel = store.channels[streamId]?.name
                ?? store.subscriptions[streamId]?.name ?? "?"
            return "\(channel) › \(display)"
        case .dm:
            return conversationKey.displayTitle(in: store)
        }
    }

    var body: some View {
        Button {
            onTap?(conversationKey)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: glyph)
                    .font(.body.weight(.bold))
                    .foregroundStyle(streamId == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(channelColor))
                if isResolved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Text(label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                streamId == nil
                    ? AnyShapeStyle(.quaternary.opacity(0.45))
                    : AnyShapeStyle(channelColor.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help("Open this conversation")
    }
}

struct MessageRow: View {
    let store: PerAccountStore
    let message: Message
    let showHeader: Bool
    let cache: MessageContentCache
    var useMatchHighlights = false
    var isKeySelected = false
    /// A followed message link flashes its target.
    var isLinkTarget = false

    @Environment(KeyboardRouter.self) private var keys
    @State private var hovering = false
    @State private var showReactionPicker = false
    @State private var editing = false
    @State private var editText = ""
    @State private var showMoveSheet = false
    @State private var showTranslation = false
    @State private var showReadReceipts = false
    @State private var showForward = false
    @State private var showEditHistory = false

    private var content: MessageContent {
        if useMatchHighlights, let match = message.matchContent {
            // Uncached: search results are one-shot lists.
            return ContentParser.parse(html: match)
        }
        return cache.content(for: message)
    }

    private var isStarred: Bool {
        (message.flags ?? []).contains("starred")
    }

    /// The system selection highlight (follows the user's accent setting).
    static var selectionColor: Color {
        #if os(macOS)
        Color(nsColor: .selectedContentBackgroundColor)
        #else
        Color(uiColor: .tintColor)
        #endif
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showHeader {
                AvatarView(store: store, userId: message.senderId, size: 32)
                    .padding(.top, 10)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if showHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Web-style: bold sender at the body text size (the
                        // timestamp lives right-aligned in the row gutter).
                        Text(message.senderFullName)
                            .font(.body.weight(.semibold))
                        if message.lastEditTimestamp != nil {
                            Button {
                                showEditHistory = true
                            } label: {
                                Text("Edited")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .help("Show edit history")
                            .popover(isPresented: $showEditHistory) {
                                EditHistoryView(store: store, message: message)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                if editing {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Message", text: $editText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...12)
                            .padding(6)
                            .background(
                                .quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button("Cancel") { editing = false }
                                .keyboardShortcut(.cancelAction)
                            Button("Save") {
                                let content = editText.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                                if !content.isEmpty {
                                    store.editMessage(message.id, content: content)
                                }
                                editing = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        .controlSize(.small)
                    }
                } else if let widget = MessageWidget.parse(message) {
                    MessageWidgetView(widget: widget, store: store, messageId: message.id)
                } else {
                    MessageContentView(
                        content: content, connection: store.connection)
                        // Same menu over the text: selectable Text otherwise
                        // substitutes the system edit menu on right-click,
                        // which a SwiftUI .contextMenu can't override on
                        // macOS — the AppKit overlay intercepts instead.
                        #if os(macOS)
                        .overlay { RightClickMenu { messageMenu() } }
                        #else
                        .contextMenu { messageMenu() }
                        #endif
                }
                if !message.reactions.isEmpty {
                    ReactionsRow(store: store, message: message)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(
            isLinkTarget
                ? Color.yellow.opacity(0.22)
                : isKeySelected ? Self.selectionColor.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        // The whole row rect is clickable/right-clickable even where it's
        // transparent — without this, only the drawn text (or a selected
        // row's highlight fill) hit-tests, so clicks in the empty trailing
        // space fall through.
        .contentShape(.rect)
        // Click/tap selects (like the web app); simultaneous so links and
        // buttons inside the row keep working.
        .simultaneousGesture(TapGesture().onEnded {
            keys.selectedMessageId = message.id
        })
        .onChange(of: keys.editRequestId) { _, requested in
            guard requested == message.id else { return }
            keys.editRequestId = nil
            Task {
                editText = await store.fetchRawContent(message.id) ?? ""
                if !editText.isEmpty {
                    editing = true
                }
            }
        }
        // Message-menu actions aimed at this (selected) row.
        .onChange(of: keys.messageActionRequest) { _, request in
            guard let request, request.messageId == message.id else { return }
            keys.messageActionRequest = nil
            switch request.action {
            case .replyQuoting:
                quoteAndReply()
            case .copyReference:
                Platform.copyToPasteboard(ConversationKey.permalink(to: message, in: store))
            case .translate:
                showTranslation = true
            case .moveToTopic:
                if message.type == .stream {
                    showMoveSheet = true
                }
            case .forward:
                showForward = true
            case .markUnreadFromHere:
                markUnreadFromHere()
            }
        }
        .overlay(alignment: .topTrailing) {
            // Fixed layout (opacity gating, not insertion) so the star sits
            // in exactly the same spot as control and as starred indicator.
            let controlsActive = hovering || showReactionPicker
            // Top-aligned: the buttons' padding would otherwise center the
            // time a few points below its message's first line.
            HStack(alignment: .top, spacing: 2) {
                Button {
                    showReactionPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(.quaternary.opacity(0.6), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Add reaction")
                .popover(isPresented: $showReactionPicker) {
                    EmojiPickerView(store: store) { entry in
                        store.toggleReaction(
                            message: message, emojiName: entry.name,
                            emojiCode: entry.code, reactionType: entry.reactionType)
                    }
                }
                .opacity(controlsActive ? 1 : 0)
                .allowsHitTesting(controlsActive)
                Button {
                    store.setStarred(!isStarred, messageId: message.id)
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.callout)
                        .foregroundStyle(
                            isStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                        .padding(5)
                        .background(
                            controlsActive
                                ? AnyShapeStyle(.quaternary.opacity(0.6))
                                : AnyShapeStyle(.clear),
                            in: .circle)
                }
                .buttonStyle(.plain)
                .help(isStarred ? "Unstar" : "Star")
                .opacity(controlsActive || isStarred ? 1 : 0)
                .allowsHitTesting(controlsActive || isStarred)
                // The time rides the overlay (not a layout column), so
                // content flows full-width beneath it; the star sits just
                // to its left.
                Text(
                    Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                        .formatted(date: .omitted, time: .shortened))
                    .font(.body.smallCaps())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, showHeader ? 2 : 1)
            }
            .padding(.top, showHeader ? 8 : 0)
        }
        // After the overlay: the hover region must include the reaction
        // button itself, or entering the button drops row-hover and the
        // button vanishes under the pointer (flicker + missed clicks).
        .onHover { hovering = $0 }
        .contextMenu {
            messageMenu()
        }
        // System translation UI, on-device (absent on platforms without
        // the Translation framework).
        .modifier(TranslationSheet(isPresented: $showTranslation, text: content.plainText))
        .sheet(isPresented: $showMoveSheet) {
            MoveTopicSheet(store: store, message: message)
        }
        .sheet(isPresented: $showReadReceipts) {
            ReadReceiptsSheet(store: store, message: message)
        }
        .sheet(isPresented: $showForward) {
            ForwardMessageSheet(store: store) { destination in
                showForward = false
                forwardMessage(to: destination)
            }
        }
    }

    /// The message context menu — one builder, attached both to the row
    /// and to the selectable text subtree (whose system menu would
    /// otherwise replace it).
    @ViewBuilder
    private func messageMenu() -> some View {
        #if os(macOS)
        // Falls back to quoting the whole message when nothing is selected.
        Button("Reply Quoting Selection", systemImage: "text.quote") {
            quoteAndReply(selectionOnly: true)
        }
        #endif
            Button("Reply Quoting Message", systemImage: "text.quote") {
                quoteAndReply()
            }
            Button("Forward Message…", systemImage: "arrowshape.turn.up.right") {
                showForward = true
            }
            Button(isStarred ? "Unstar" : "Star", systemImage: "star") {
                store.setStarred(!isStarred, messageId: message.id)
            }
            Button("Mark as Unread from Here", systemImage: "message.badge") {
                markUnreadFromHere()
            }
            Button("Copy Text", systemImage: "doc.on.doc") {
                Platform.copyToPasteboard(content.plainText)
            }
            Button("Copy Message Reference", systemImage: "link") {
                Platform.copyToPasteboard(
                    ConversationKey.permalink(to: message, in: store))
            }
            #if canImport(Translation) && !os(visionOS)
            Button("Translate", systemImage: "translate") {
                showTranslation = true
            }
            #endif
            Button("Seen By…", systemImage: "eye") {
                showReadReceipts = true
            }
            Menu("Remind Me About This") {
                Button("In 1 Hour") { remind(at: .now.addingTimeInterval(3600)) }
                Button("In 3 Hours") { remind(at: .now.addingTimeInterval(3 * 3600)) }
                Button("Tomorrow at 9 AM") { remind(at: nextMorning(daysAhead: 1)) }
                Button("Next Week at 9 AM") { remind(at: nextMorning(daysAhead: 7)) }
            }
            if message.type == .stream {
                Button("Move to Topic…", systemImage: "arrow.turn.up.right") {
                    showMoveSheet = true
                }
            }
            if message.senderId == store.selfUserId {
                Divider()
                Button("Edit Message", systemImage: "pencil") {
                    Task {
                        editText = await store.fetchRawContent(message.id) ?? ""
                        if !editText.isEmpty {
                            editing = true
                        }
                    }
                }
                Button("Delete Message", systemImage: "trash", role: .destructive) {
                    store.deleteMessage(message.id)
                }
            }
        
    }

    /// Zulip's quote-and-reply block, from the raw markdown:
    ///   @_**Name|id** [said](permalink):
    ///   ```quote
    ///   …
    ///   ```
    /// The quoted block shared by quote-and-reply and forwarding.
    private func quoteBlock(_ raw: String) -> String {
        let link = ConversationKey.permalink(to: message, in: store)
        return """
            @_**\(message.senderFullName)|\(message.senderId)** [said](\(link)):
            ```quote
            \(raw)
            ```

            """
    }

    /// The web app's "Mark as unread from here", with visibility-based read
    /// marking paused so the on-screen rows don't immediately re-mark.
    private func markUnreadFromHere() {
        keys.readMarkingPaused = true
        store.markUnreadFromHere(message)
    }

    private func remind(at date: Date) {
        store.remindAboutMessage(message.id, at: date)
    }

    private func nextMorning(daysAhead: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: daysAhead, to: .now) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// Quotes this message into another conversation's compose field.
    private func forwardMessage(to destination: Destination) {
        Task {
            let raw = await store.fetchRawContent(message.id) ?? content.plainText
            let quote = quoteBlock(raw)
            keys.navigate?(destination)
            try? await Task.sleep(for: .milliseconds(300))
            keys.insertIntoCompose?(quote)
            keys.focusCompose?()
        }
    }

    private func quoteAndReply(selectionOnly: Bool = false) {
        // Read the selection before anything steals focus.
        let selection = selectionOnly ? Platform.currentTextSelection() : nil
        Task {
            let raw: String
            if let selection {
                raw = selection
            } else {
                raw = await store.fetchRawContent(message.id) ?? content.plainText
            }
            let quote = quoteBlock(raw)
            // Cross-conversation feeds have no compose: jump to the
            // message's conversation first, then insert.
            if keys.insertIntoCompose == nil,
               let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId) {
                keys.navigate?(.conversation(key))
                try? await Task.sleep(for: .milliseconds(300))
            }
            keys.insertIntoCompose?(quote)
            keys.focusCompose?()
        }
    }
}

struct ReactionsRow: View {
    let store: PerAccountStore
    let message: Message

    private var reactions: [Reaction] { message.reactions }

    @State private var showPicker = false

    private struct Group: Identifiable {
        var id: String
        var sample: Reaction
        var count: Int
        var reactedBySelf: Bool
        var userIds: [Int]
    }

    private var groups: [Group] {
        var byEmoji: [String: Group] = [:]
        var order: [String] = []
        for reaction in reactions {
            let key = "\(reaction.reactionType):\(reaction.emojiCode)"
            if byEmoji[key] == nil {
                byEmoji[key] = Group(
                    id: key, sample: reaction, count: 0, reactedBySelf: false, userIds: [])
                order.append(key)
            }
            byEmoji[key]?.count += 1
            byEmoji[key]?.userIds.append(reaction.userId)
            if reaction.userId == store.selfUserId {
                byEmoji[key]?.reactedBySelf = true
            }
        }
        return order.compactMap { byEmoji[$0] }.sorted { $0.count > $1.count }
    }

    /// "Steven Nguyen, You" — the hover tooltip; self listed last as "You".
    private func reactorNames(_ group: Group) -> String {
        var names = group.userIds
            .filter { $0 != store.selfUserId }
            .map { store.users[$0]?.fullName ?? "Someone" }
        if group.reactedBySelf {
            names.append("You")
        }
        return names.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(groups) { group in
                Button {
                    store.toggleReaction(
                        message: message,
                        emojiName: group.sample.emojiName,
                        emojiCode: group.sample.emojiCode,
                        reactionType: group.sample.reactionType)
                } label: {
                    HStack(spacing: 4) {
                        emojiView(group.sample)
                            .font(.system(size: 16))
                        if group.count > 1 {
                            Text("\(group.count)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        group.reactedBySelf ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                        in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help("\(reactorNames(group)) reacted with :\(group.sample.emojiName):")
            }
            Button {
                showPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("Add reaction")
            .popover(isPresented: $showPicker) {
                EmojiPickerView(store: store) { entry in
                    store.toggleReaction(
                        message: message, emojiName: entry.name,
                        emojiCode: entry.code, reactionType: entry.reactionType)
                }
            }
        }
        .padding(.top, 1)
    }

    @ViewBuilder
    private func emojiView(_ reaction: Reaction) -> some View {
        if reaction.reactionType == "unicode_emoji",
           let character = emojiCharacter(fromCodes: reaction.emojiCode) {
            Text(character)
        } else if let src = store.realmEmoji[reaction.emojiCode]?.sourceUrl,
                  let image = EmojiImageLoader.shared.image(src: src, connection: store.connection) {
            Image(platform: image)
        } else {
            Text(":\(reaction.emojiName):")
        }
    }
}
