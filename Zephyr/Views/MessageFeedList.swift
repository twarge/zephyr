import SwiftUI
import TipKit
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
    /// Cross-conversation feeds (Combined, Mentions, Starred, Search):
    /// the hover/tap controls show a go-to-conversation jump in place of
    /// quoted reply (which belongs to in-conversation views).
    var showsConversationJump = false
    /// Topic/DM transcripts: messages arriving while the reader is at the
    /// bottom and present are marked read; arrivals nobody saw (away,
    /// scrolled up, read marking paused) wait until someone does.
    var marksArrivalsRead = false
    /// Cross-conversation feeds: a message scrolled into view is marked
    /// read (batched).
    var marksReadOnView = false
    /// Warm-cache plumbing: where the viewport sits, recorded every scroll
    /// tick and read back on a warm reopen to land exactly there.
    var scrollMemory: FeedScrollMemory?

    @Environment(KeyboardRouter.self) var keys
    @State var anchorId: String?
    /// Where `anchorId`'s row sits in the viewport — set with every write
    /// of it (`scroll(to:at:)`), since the scroll binding has one anchor
    /// for both. Bottom unless an open is placing a marker or a parked row.
    @State var anchorPlacement: UnitPoint = .bottom
    /// A parked position being restored (nil on fresh opens): overrides
    /// the marker/bottom opening behavior, validated against the model in
    /// init (a row evicted while parked falls back to a fresh open).
    @State var restoredPosition: FeedScrollPosition?
    /// The mid-history restore ran (one-shot): re-appears of the same view
    /// (sheet dismissals) neither re-restore nor marker-nudge.
    @State var didRestore = false
    /// A warm reopen found unreads that arrived while the feed was parked
    /// at the bottom: the NEW marker re-aims here on first appear
    /// (consumed one-shot — init must stay side-effect free).
    @State var pendingMarkerReaim: Int?
    /// The unread the opening anchor targeted (nil = a bottom open).
    /// Compared against the server's answer when it replaces an offline
    /// preview: a differing marker re-runs the opening scroll.
    @State var openingMarkerId: Int?
    /// The reader has scrolled the feed themselves; the opening scroll
    /// must no longer be corrected out from under them.
    @State var userDidScroll = false
    @State var nearBottom = true
    @State var quickLook = FeedQuickLook()
    /// Rows seen but not yet flushed as read. A reference box, not
    /// observed state: nothing draws from it, and as state every row
    /// scrolling into view re-rendered the feed — which re-fired the
    /// visibility observer within the frame ("tried to update multiple
    /// times per frame").
    final class PendingReads {
        var ids: Set<Int> = []
        var flushTask: Task<Void, Never>?
    }
    @State var pendingReads = PendingReads()
    /// Transcript arrivals (`marksArrivalsRead`) not yet marked read, and
    /// whether a reader is present. A box for the same reason as
    /// `pendingReads`.
    final class ArrivalReads {
        var ids: Set<Int> = []
        var readerPresent = true
    }
    @State var arrivalReads = ArrivalReads()
    /// `sections`, memoized: rebuilt only when the messages
    /// (`messagesVersion`), the NEW marker, or the day changes; selection
    /// moves and typing never rebuild it.
    final class SectionsMemo {
        var version: Int?
        var markerId: Int?
        var day: Date?
        var sections: [FeedSection]?
    }
    @State var sectionsMemo = SectionsMemo()
    /// Mark-on-view feeds: the reader stepped away (inactive window,
    /// backgrounded app, sleeping or locked screen) with the feed parked
    /// at the bottom — `newestId` is the window's newest message at that
    /// moment. The feed keeps following arrivals unseen; the return
    /// re-aims at the first of them. Nil while present, or away
    /// mid-history (that viewport doesn't move).
    @State var awayAtBottom: (newestId: Int?, since: Date)?
    /// Bumped when the reader returns to unreads that arrived while away;
    /// the scroll reader responds by opening at the re-aimed NEW marker.
    @State var returnReaimNonce = 0
    /// Bumped when the viewport is detected outside the content bounds;
    /// the reader responds with an imperative rescue scroll.
    @State var recoverNonce = 0
    /// A send from this feed is awaiting its echo: the echo's reveal must
    /// not depend on `nearBottom` (which can read stale-false right after
    /// an append) or on the anchor binding (re-setting an unchanged value
    /// doesn't scroll). Cleared when the last outbox row for this narrow
    /// resolves.
    @State var ownSendRevealPending = false

    init(
        store: PerAccountStore, model: MessageListModel, cache: MessageContentCache,
        headerMode: HeaderMode = .hidden, useMatchHighlights: Bool = false,
        onHeaderTap: ((ConversationKey) -> Void)? = nil,
        showsConversationJump: Bool = false,
        marksArrivalsRead: Bool = false,
        marksReadOnView: Bool = false,
        scrollMemory: FeedScrollMemory? = nil
    ) {
        self.store = store
        self.model = model
        self.cache = cache
        self.headerMode = headerMode
        self.useMatchHighlights = useMatchHighlights
        self.onHeaderTap = onHeaderTap
        self.showsConversationJump = showsConversationJump
        self.marksArrivalsRead = marksArrivalsRead
        self.marksReadOnView = marksReadOnView
        self.scrollMemory = scrollMemory
        // A parked viewport position resumes exactly (a remembered row
        // must still be in the window — paging may have trimmed it).
        var restored = scrollMemory?.position
        if case .row(let id, _, _) = restored,
           !model.messages.contains(where: { $0.id == id })
        {
            restored = nil
        }
        // A feed parked at the bottom reopens at the first unread that
        // arrived while it was away — the logical resume point — not the
        // physical bottom; without fresh arrivals the bottom restore
        // stands. A catch-up feed resumes at its oldest unread wherever
        // it sits, exactly as its fresh open would: parked at the bottom
        // says nothing about what was skipped on the way there. Decision
        // only (this init re-runs on every parent re-evaluation);
        // onAppear re-aims the marker once.
        var reaimId: Int?
        if case .bottom(let newestId) = restored,
           let unreadId = model.firstUnreadId(after: marksReadOnView ? nil : newestId)
        {
            reaimId = unreadId
            restored = nil
        }
        _pendingMarkerReaim = State(initialValue: reaimId)
        _restoredPosition = State(initialValue: restored)
        _openingMarkerId = State(
            initialValue: reaimId
                ?? (restored == nil ? model.firstUnreadMarkerId : nil))
        // The scroll target must be known BEFORE the first layout pass:
        // an onAppear write lands after it, re-targeting the lazy stack
        // mid-estimation — which could park the viewport in unrealized
        // space (a blank transcript until a resize forced re-layout).
        // The restored row is a coarse first-frame stand-in (its bottom at
        // the viewport bottom); onAppear's settle pass nails the offset.
        // The anchor goes in with it, so the first layout lands where the
        // settle passes would otherwise move it a moment later: a marker
        // open at the upper quarter, a parked row back at its offset.
        let initialAnchor: String
        let initialPlacement: UnitPoint
        switch restored {
        case .bottom:
            (initialAnchor, initialPlacement) = (Self.bottomAnchorId, .bottom)
        case .row(let id, _, let anchorY):
            (initialAnchor, initialPlacement) = ("msg-\(id)", UnitPoint(x: 0, y: anchorY))
        case nil:
            // The re-aim targets the message row itself: the marker
            // item doesn't exist until onAppear places it.
            if let reaimId {
                (initialAnchor, initialPlacement) = ("msg-\(reaimId)", Self.markerPlacement)
            } else if model.firstUnreadMarkerId != nil {
                (initialAnchor, initialPlacement) = ("unread-marker", Self.markerPlacement)
            } else {
                (initialAnchor, initialPlacement) = (Self.bottomAnchorId, .bottom)
            }
        }
        _anchorId = State(initialValue: initialAnchor)
        _anchorPlacement = State(initialValue: initialPlacement)
        _opening = State(initialValue: Opening(target: initialAnchor, placement: initialPlacement))
        // As the open will find it: starting `true` for a mid-history open
        // flipped on the first geometry pass, re-rendering the feed inside
        // the frame its scroll observers were reporting.
        _nearBottom = State(initialValue: initialPlacement == .bottom)
    }

    var outboxMessages: [OutboxMessage] {
        store.outbox.filter {
            $0.destination.matches(narrow: model.narrow, selfUserId: store.selfUserId)
        }
    }


    /// The sentinel row at the very end of the stack — below the last
    /// message, outbox rows, and typing indicator — so "scroll to bottom"
    /// really lands at the bottom.
    static let bottomAnchorId = "feed-bottom"

    /// An unread marker (or a linked message) opens in the upper quarter,
    /// with what follows it below.
    static let markerPlacement = UnitPoint(x: 0.5, y: 0.25)

    /// Points the scroll binding at a row, placed as given — the only way
    /// `anchorId` is written, so the binding's anchor always matches.
    func scroll(to id: String, at placement: UnitPoint = .bottom) {
        if anchorPlacement != placement { anchorPlacement = placement }
        anchorId = id
    }

    struct FeedGeometry: Equatable {
        var nearBottom: Bool
        var lost: Bool
        var containerHeight: CGFloat = 0
        /// Off the very bottom at all — what a bottom open must not be.
        var offBottom = false
    }

    enum Item: Identifiable {
        case daySeparator(String)
        case unreadMarker
        case message(Message, showHeader: Bool)

        var id: String {
            switch self {
            case .daySeparator(let label): "day-\(label)"
            case .unreadMarker: "unread-marker"
            case .message(let message, _): "msg-\(message.id)"
            }
        }
    }

    /// One pinnable run of the feed: a conversation header plus the rows
    /// under it. The header sticks to the top while its rows scroll and is
    /// pushed out by the next section's header (LazyVStack pinnedViews).
    struct FeedSection: Identifiable {
        var headerKey: ConversationKey?
        var headerFirstMessageId: Int?
        var items: [Item] = []
        var id: String { headerFirstMessageId.map { "sec-\($0)" } ?? "sec-lead" }
    }

    /// Messages interleaved with day separators, split into sections at
    /// conversation headers (multi-conversation feeds; header-less topic/DM
    /// transcripts collapse to one anonymous section). Consecutive messages
    /// from the same sender within 5 minutes coalesce under one header.
    var sections: [FeedSection] {
        let memo = sectionsMemo
        let today = Calendar.current.startOfDay(for: .now)
        if let cached = memo.sections, memo.markerId == model.firstUnreadMarkerId,
           memo.day == today, memo.version == model.messagesVersion
        {
            return cached
        }
        let built = PerfLog.measure("FeedList.sections") { buildSections() }
        memo.version = model.messagesVersion
        memo.markerId = model.firstUnreadMarkerId
        memo.day = today
        memo.sections = built
        return built
    }

    func buildSections() -> [FeedSection] {
        var out: [FeedSection] = []
        var current = FeedSection()
        var lastDay: DateComponents?
        var lastKey: ConversationKey?
        var lastSender: Int?
        var lastTimestamp = 0
        for message in model.messages {
            let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
            let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
            if day != lastDay {
                // Ends the previous section, above the next one's header.
                current.items.append(.daySeparator(daySeparatorLabel(for: date)))
                lastDay = day
                lastSender = nil
            }
            if headerMode != .hidden,
               let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId),
               key != lastKey {
                if current.headerKey != nil || !current.items.isEmpty {
                    out.append(current)
                }
                current = FeedSection(headerKey: key, headerFirstMessageId: message.id)
                lastKey = key
                lastSender = nil
            }
            if message.id == model.firstUnreadMarkerId {
                current.items.append(.unreadMarker)
                lastSender = nil  // The run restarts under the marker.
            }
            let showHeader = message.senderId != lastSender || message.timestamp - lastTimestamp > 300
            current.items.append(.message(message, showHeader: showHeader))
            lastSender = message.senderId
            lastTimestamp = message.timestamp
        }
        if current.headerKey != nil || !current.items.isEmpty {
            out.append(current)
        }
        return out
    }

    /// Empty enough to replace the transcript with a centered placeholder
    /// (a typing indicator still counts as content). Typing is consulted
    /// only for an empty window, so typists don't re-render a full feed.
    var isEmptyFeed: Bool {
        model.messages.isEmpty && outboxMessages.isEmpty
            && TypingIndicatorRow.typistNames(store: store, narrow: model.narrow).isEmpty
    }

    /// Live row frames in scroll-viewport coordinates, for reveal
    /// decisions. A reference box, not observed state: frames change on
    /// every scroll tick and must not re-render the feed. (A previous
    /// visibility-set approach went stale — LazyVStack recycles rows
    /// without a final not-visible callback, so off-screen selections
    /// counted as visible and never scrolled.)
    final class RowFrames {
        var frames: [Int: CGRect] = [:]
        /// In the box with the frames, for the same reason: read by scroll
        /// passes, never drawn — as state, each geometry tick re-rendered
        /// the feed and re-fired the geometry observer within the frame.
        var viewportHeight: CGFloat = 0
    }
    @State var rowFrames = RowFrames()

    var viewportHeight: CGFloat { rowFrames.viewportHeight }

    /// The open's placement, kept through the window's own opening layout
    /// (`reassertOpening`). A box: the geometry observer reaches it
    /// mid-frame, where a state write would re-render the feed.
    final class Opening {
        /// What the open placed. The binding can't hold it: it's two-way,
        /// and as the viewport moved SwiftUI rewrote it to whatever row
        /// then sat at the anchor — and kept holding that one there.
        let target: String
        let placement: UnitPoint
        var proxy: ScrollViewProxy?
        var settled = false
        var reassertPending = false

        init(target: String = "", placement: UnitPoint = .bottom) {
            self.target = target
            self.placement = placement
        }
    }
    @State var opening = Opening()
    /// Content hit response is paused while the feed scrolls: rows
    /// crossing a stationary cursor otherwise flip their hover state —
    /// a full row re-render (the controls overlay) per crossing, which
    /// stutters heavy transcripts. Restored shortly after the scroll
    /// settles; AppKit then re-delivers hover to the row under the
    /// cursor. (Parity: native scroll views swallow mid-momentum clicks.)
    @State var isScrolling = false
    /// Debounce box for the hit-response restore (a reference box — a
    /// Task in @State would re-render the feed on every reassignment).
    final class IdleDebounce {
        var task: Task<Void, Never>?
    }
    @State var idleDebounce = IdleDebounce()

    /// Everywhere but a topic or DM transcript, a row's message is shown
    /// away from its own conversation: the context menu offers a jump to
    /// the message there.
    var offersConversationJump: Bool {
        switch model.narrow {
        case .topic, .dm: false
        default: true
        }
    }

    var body: some View {
        let _ = PerfLog.render("FeedList")
        let _ = PerfLog.mark(isEmptyFeed ? "Feed body (empty)" : "Feed body (messages)")
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
                            opening.proxy = proxy
                            let opening = opening
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1.5))
                                opening.settled = true
                            }
                            // Warm-reopen marker re-aim, deferred out of
                            // init: place the NEW marker at the first
                            // unread that arrived while parked, so the
                            // settle pass below targets it.
                            if let reaimId = pendingMarkerReaim {
                                pendingMarkerReaim = nil
                                model.reaimUnreadMarker(to: reaimId)
                            }
                            // A link target this window doesn't hold (a
                            // failed anchored fetch) must not leave the
                            // highlight stuck: it gates the re-aims.
                            if let highlight = keys.highlightMessageId,
                               !model.messages.contains(where: { $0.id == highlight }) {
                                scheduleHighlightClear(after: .seconds(8))
                            }
                            // The binding (inner onAppear) has already put
                            // the target at the viewport bottom; once layout
                            // settles, nudge it up to the upper quarter.
                            let target: String?
                            if let highlight = keys.highlightMessageId,
                               model.messages.contains(where: { $0.id == highlight }) {
                                target = "msg-\(highlight)"
                            } else if case .row(let id, let fraction, _) = restoredPosition,
                                      !didRestore {
                                // Warm reopen mid-history: place the
                                // remembered row's bottom edge back at its
                                // remembered viewport fraction — no
                                // animation, no marker nudge. One-shot: a
                                // later re-appear (sheet dismissal) must
                                // not yank the viewport back.
                                didRestore = true
                                settleRestore(id: id, fraction: fraction, proxy: proxy)
                                return
                            } else if restoredPosition == nil,
                                      model.firstUnreadMarkerId != nil {
                                target = "unread-marker"
                            } else {
                                // Fresh bottom-anchored open, or a warm
                                // reopen parked at the bottom.
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
                                        // openingMarkerId turning non-nil means
                                        // the server's answer re-anchored the
                                        // open at an unread marker mid-pass.
                                        guard nearBottom, openingMarkerId == nil
                                        else { return }
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
                            guard let newId else { return }
                            // Same-conversation message links scroll live.
                            // An unloaded target is being refetched around
                            // it (KeyboardRouter.aimMessageLink); the
                            // flash still fades, later — a stuck highlight
                            // would disable the return and offline re-aims.
                            guard model.messages.contains(where: { $0.id == newId }) else {
                                scheduleHighlightClear(after: .seconds(8))
                                return
                            }
                            proxy.scrollTo("msg-\(newId)", anchor: .center)
                            scheduleHighlightClear()
                        }
                        // The anchored refetch for an unloaded link target
                        // replaced the window: land on the target.
                        .onChange(of: ObjectIdentifier(model)) {
                            guard let target = keys.highlightMessageId,
                                  model.messages.contains(where: { $0.id == target })
                            else { return }
                            scroll(to: "msg-\(target)", at: Self.markerPlacement)
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(100))
                                proxy.scrollTo("msg-\(target)", anchor: .center)
                            }
                            scheduleHighlightClear()
                        }
                        // Selection follows into view — but only when the
                        // row isn't already (near-)fully visible, so clicks
                        // and on-screen moves don't jolt. Direction-aware
                        // anchors leave clearance: upward reveals land
                        // below the pinned section header, downward ones
                        // keep a bottom margin. (anchor: nil's documented
                        // minimal reveal neither cleared the pinned header
                        // nor fired reliably in this lazy stack.) Observed
                        // in a modifier of its own, so the feed body never
                        // depends on the selection.
                        .modifier(SelectionFollow { id, previous in
                            guard model.messages.contains(where: { $0.id == id }) else { return }
                            // A reveal request has no previous selection:
                            // direction from where the row sits relative
                            // to the realized rows.
                            let previous = previous ?? rowFrames.frames.keys.min()
                                .flatMap { id < $0 ? $0 : nil }
                            revealSelection(id, previous: previous, proxy: proxy)
                        })
                        // The offline preview committed the opening anchor
                        // before the server answered (cold launches render
                        // the cached transcript instantly, and a cache
                        // written before the newest arrivals reads fully-
                        // read, so the preview parks at the bottom). When
                        // the server's answer then places the first unread
                        // elsewhere, re-run the opening scroll — but only
                        // while the reader hasn't touched the feed.
                        .onChange(of: model.isOfflineFallback) { wasFallback, isFallback in
                            guard wasFallback, !isFallback, model.fetchError == nil,
                                  !userDidScroll, !didRestore,
                                  keys.highlightMessageId == nil,
                                  keys.selectedMessageId == nil,
                                  model.firstUnreadMarkerId != openingMarkerId
                            else { return }
                            // Rows the swept-away viewport grazed were never
                            // actually seen — they must not flush as read.
                            pendingReads.flushTask?.cancel()
                            pendingReads.ids = []
                            openingMarkerId = model.firstUnreadMarkerId
                            if model.firstUnreadMarkerId != nil {
                                scroll(to: "unread-marker", at: Self.markerPlacement)
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(350))
                                    guard !userDidScroll else { return }
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo(
                                            "unread-marker",
                                            anchor: UnitPoint(x: 0.5, y: 0.25))
                                    }
                                }
                            } else {
                                // The preview anchored at a cached marker the
                                // server has since cleared (read elsewhere):
                                // the true open is the bottom.
                                scrollToBottomSettled(proxy)
                            }
                        }
                        // Back from being away (readerReturned re-aimed the
                        // NEW marker at the first unseen arrival): open
                        // there, like a fresh open — upper quarter, with
                        // the unreads below it.
                        .onChange(of: returnReaimNonce) {
                            scroll(to: "unread-marker", at: Self.markerPlacement)
                            openingMarkerId = model.firstUnreadMarkerId
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(50))
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(
                                        "unread-marker",
                                        anchor: UnitPoint(x: 0.5, y: 0.25))
                                }
                                // A short run of arrivals leaves the
                                // viewport where it was (already at the
                                // bottom) — no visibility change will
                                // report those rows, so note them here.
                                try? await Task.sleep(for: .milliseconds(400))
                                for (id, frame) in rowFrames.frames
                                where frame.maxY > 0 && frame.minY < viewportHeight {
                                    if let message = model.messages.first(where: { $0.id == id }) {
                                        noteSeen(message)
                                    }
                                }
                            }
                        }
                        // Where no compose bar sits below it, the feed's
                        // corner is the window's (the display's on
                        // iPhone): the button rises clear of its curve,
                        // keeping the compose pill's 12pt trailing line.
                        .cornerAdaptiveOverlay(
                            alignment: .bottomTrailing, padding: 12, axis: .vertical
                        ) {
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
                                .help("Jump to latest messages")
                                .accessibilityLabel("Jump to latest messages")
                            }
                        }
                        .onChange(of: outboxMessages.count) { old, new in
                            // A send targeting this narrow always reveals
                            // itself — regardless of `nearBottom`, which
                            // only gates arrivals from others.
                            guard new > old else { return }
                            ownSendRevealPending = true
                            guard !model.haveNewest else {
                                scrollToBottomSettled(proxy)
                                return
                            }
                            // Viewing history: jump to the newest messages
                            // so the send is visible. Retried — the echo
                            // consumes the outbox row, so a failed jump
                            // would otherwise leave the sent message
                            // invisible in the pending buffer with nothing
                            // else to surface it.
                            Task {
                                for delay in [0, 2, 5] {
                                    if delay > 0 {
                                        try? await Task.sleep(for: .seconds(delay))
                                    }
                                    if !model.haveNewest {
                                        await model.jumpToNewest()
                                    }
                                    if model.haveNewest {
                                        scrollToBottomSettled(proxy)
                                        return
                                    }
                                }
                            }
                        }
                        .onChange(of: model.messages.last?.id) { _, newLastId in
                            // The echo of a send from this feed: reveal it
                            // even when `nearBottom` reads stale-false, via
                            // the imperative settle (the anchor binding
                            // alone is a no-op when already at the bottom
                            // sentinel).
                            guard newLastId != nil, ownSendRevealPending,
                                  model.messages.last?.senderId == store.selfUserId
                            else { return }
                            ownSendRevealPending = !outboxMessages.isEmpty
                            scrollToBottomSettled(proxy)
                        }
                        .task {
                            await runAutoScrollIfRequested(proxy)
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
            // An inline edit left open in another conversation would keep
            // single-key navigation silenced.
            if let editing = keys.editingMessageId,
               !model.messages.contains(where: { $0.id == editing }) {
                keys.endInlineEdit()
            }
            // A selection carried over from another conversation would make
            // the first arrow press jump to the newest message.
            if let selected = keys.selectedMessageId,
               !model.messages.contains(where: { $0.id == selected }) {
                keys.selectedMessageId = nil
                keys.clearMediaSelection()
            } else if !keys.selectedMessageIds.allSatisfy({ id in
                model.messages.contains { $0.id == id }
            }) {
                // Extended members that aren't in this feed collapse the
                // selection back to its anchor.
                keys.collapseSelectionToAnchor()
            }
            quickLook.orderedNodes = { orderedImageNodes() }
            keys.attachmentList = { messageId in
                guard let message = model.messages.first(where: { $0.id == messageId }),
                      MessageWidget.parse(message) == nil
                else { return [] }
                return MessageAttachment.list(in: cache.content(for: message))
            }
            keys.presentAttachments = { attachments, focusIndex in
                Task {
                    await quickLook.present(
                        paths: attachments.map(\.path), focusIndex: focusIndex,
                        connection: store.connection)
                }
            }
        }
        .onDisappear {
            if keys.activeFeed === model {
                keys.activeFeed = nil
                keys.endInlineEdit()
                keys.selectedMessageId = nil
                keys.clearMediaSelection()
                keys.attachmentList = nil
                keys.presentAttachments = nil
            }
        }
    }

    @ViewBuilder
    func feedRow(_ item: Item) -> some View {
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
            // Rows read selection and highlight themselves: as arguments
            // here, every arrow key re-rendered the whole feed.
            MessageRow(
                store: store, message: message,
                showHeader: showHeader, cache: cache,
                useMatchHighlights: useMatchHighlights,
                showsConversationJump: showsConversationJump,
                offersConversationJump: offersConversationJump)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .scrollView)
                } action: { frame in
                    rowFrames.frames[message.id] = frame
                }
                .onDisappear {
                    rowFrames.frames.removeValue(forKey: message.id)
                }
                // Zero-height edge sentinels: anchoring THEM at a viewport
                // fraction places the row's top/bottom at an exact offset
                // regardless of the row's height — row-anchor math drifts
                // with height (tall rows landed touching the bottom edge).
                .overlay(alignment: .top) {
                    Color.clear
                        .frame(height: 1)
                        .id("msgtop-\(message.id)")
                }
                .overlay(alignment: .bottom) {
                    Color.clear
                        .frame(height: 1)
                        .id("msgbot-\(message.id)")
                }
        }
    }

    /// Every image in the transcript, in message order — the Quick Look
    /// session's navigation set.
    func orderedImageNodes() -> [ImageNode] {
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

    var feedScrollView: some View {
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
                // Unconditionally — a pending send must never be invisible.
                // Mid-history the rows sit below the paging spinner until
                // the send-triggered jump lands the real window.
                ForEach(outboxMessages) { outboxMessage in
                    OutboxRow(store: store, message: outboxMessage)
                        .id("out-\(outboxMessage.id)")
                }
                // Its own view: typing changes re-render just this row.
                TypingIndicatorRow(store: store, narrow: model.narrow)
                // Doubles as the feed's bottom breathing room (in place of
                // stack padding, which the scroll anchor couldn't reach).
                Color.clear
                    .frame(height: 12)
                    .id(Self.bottomAnchorId)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            // See isScrolling: hover, cursor rects, and clicks pause
            // while scrolling. Content only — the scroll view itself
            // still receives wheel/trackpad events, and the jump-to-
            // bottom overlay (outside the content) stays clickable.
            .allowsHitTesting(!isScrolling)
        }
        // Clicking or tapping empty feed space (not on a message) drops
        // the selection, like Escape — rows and interactive content
        // consume their own taps first, so only misses land here.
        .onTapGesture {
            guard keys.selectedMessageId != nil || keys.selectedMediaId != nil else { return }
            keys.selectedMessageId = nil
            keys.clearMediaSelection()
        }
        .defaultScrollAnchor(.bottom)
        // Explicitly for size changes too, the viewport's included: the
        // window's opening layout shrinks it (its toolbar grows in a pass
        // late), and kept at its top, a bottom open slid off the bottom.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollPosition(id: $anchorId, anchor: anchorPlacement)
        // Read-marking feeds need actual viewport visibility, not lazy-
        // stack realization. Observe the scroll target IDs once at the
        // container instead of installing a visibility observer on every
        // message row. Transcripts that mark the whole conversation read
        // install no visibility tracking at all.
        .modifier(VisibleMessageTargets(
            enabled: marksReadOnView,
            action: { identifiers in noteSeen(identifiers) },
            onReaderAway: { readerWentAway() },
            onReaderReturn: { readerReturned() }))
        // Transcripts: arrivals mark read only with someone there to see.
        .modifier(ArrivalPresence(enabled: marksArrivalsRead) { isPresent in
            arrivalReads.readerPresent = isPresent
            flushArrivalReads()
        })
        .onScrollPhaseChange { _, newPhase in
            // User-driven phases only — programmatic scrolls (anchor
            // binding, settle passes) report `.animating`.
            switch newPhase {
            case .tracking, .interacting, .decelerating: if !userDidScroll { userDidScroll = true }
            default: break
            }
            idleDebounce.task?.cancel()
            if newPhase.isScrolling {
                // Same-value writes still invalidate; write only edges.
                if !isScrolling { isScrolling = true }
            } else {
                // Debounced restore: a physical scroll wheel bounces
                // through idle between ticks — re-enabling per tick
                // would thrash hover (and re-render the feed) mid-scroll.
                idleDebounce.task = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    isScrolling = false
                }
            }
        }
        // One geometry observer for both signals (two separate ones
        // double-fired per frame): bottom proximity, and the blank-view
        // failure mode — the viewport parked outside the content bounds
        // (offset never re-clamped), fixed by re-asserting the anchor
        // instead of waiting for a window resize to force re-layout.
        .onScrollGeometryChange(for: FeedGeometry.self) { geometry in
            #if os(macOS)
            // The blank-view failure mode is macOS-only, and so is its
            // rescue: on iPadOS these rects thrash during live window
            // resizes, and the rescue's scroll re-assertions fought the
            // resize until message views froze mid-scale.
            let lost = geometry.contentSize.height > 0
                && (geometry.visibleRect.minY >= geometry.contentSize.height - 1
                    || geometry.visibleRect.maxY <= 0)
            #else
            let lost = false
            #endif
            let bottomGap = geometry.contentSize.height - geometry.visibleRect.maxY
            return FeedGeometry(
                nearBottom: bottomGap < 60,
                lost: lost,
                containerHeight: geometry.containerSize.height,
                offBottom: bottomGap > 2)
        } action: { old, new in
            rowFrames.viewportHeight = new.containerHeight
            // The window's opening layout moving the viewport (100 is its
            // size before the first real layout), or anything else
            // drifting a bottom open off the bottom: put the open back.
            if (old.containerHeight > 100 && old.containerHeight != new.containerHeight)
                || (new.offBottom && opening.target == Self.bottomAnchorId)
            {
                reassertOpening()
            }
            // Distance alone misfires: the floating bar's bottom insets
            // can park the rest position right at the 60pt threshold,
            // showing the jump arrow while visually at the bottom. The
            // last row's actual frame is authoritative when realized —
            // bottom message in view means no arrow.
            let lastRowVisible = model.messages.last
                .flatMap { rowFrames.frames[$0.id] }
                .map { $0.minY < new.containerHeight && $0.maxY > 0 } ?? false
            // Edges only: a same-value write still re-renders the feed.
            // A bottom open counts as at the bottom until it settles: the
            // window's opening layout drifts it, `reassertOpening` puts it
            // back, and the flip in between flashed the jump-to-latest
            // button into the window as it appeared.
            let holdingBottomOpen = !opening.settled && !userDidScroll
                && opening.target == Self.bottomAnchorId
            let isNearBottom = new.nearBottom || lastRowVisible || holdingBottomOpen
            if nearBottom != isNearBottom {
                nearBottom = isNearBottom
                // Back at the bottom: arrivals scrolled past are seen now.
                if isNearBottom, marksArrivalsRead, !arrivalReads.ids.isEmpty {
                    Task { @MainActor in flushArrivalReads() }
                }
            }
            // Park the viewport for a warm reopen: at the bottom the
            // restore sticks to bottom (newest); mid-history it's the
            // bottom-most row whose bottom edge is on screen, plus that
            // edge's viewport fraction. Continuous (a reference box, no
            // invalidation) — teardown order makes a one-shot
            // onDisappear read unreliable.
            if let scrollMemory, new.containerHeight > 0 {
                if nearBottom {
                    scrollMemory.position = .bottom(newestId: model.messages.last?.id)
                } else if let (id, frame) = rowFrames.frames
                    .filter({ $0.value.maxY > 0 && $0.value.maxY <= new.containerHeight })
                    .max(by: { $0.value.maxY < $1.value.maxY })
                {
                    let height = new.containerHeight
                    scrollMemory.position = .row(
                        id: id, fraction: frame.maxY / height,
                        anchorY: frame.height < height
                            ? min(max(frame.minY / (height - frame.height), 0), 1) : 1)
                }
            }
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
                scroll(to: "msg-\(highlight)", at: Self.markerPlacement)
            }
        }
        .onChange(of: model.messages.last?.id) { oldLastId, newLastId in
            guard newLastId != nil else { return }
            if nearBottom {
                scroll(to: Self.bottomAnchorId)
            }
            noteArrivals(after: oldLastId)
        }
        // (Outbox appends reveal via the reader-scoped send hook, which
        // isn't gated on nearBottom — a send always shows itself.)
    }
}

/// Follows the keyboard selection into view: the anchor, the ⇧-extension
/// tip, and explicit reveal requests (an action posted to the selected
/// row). Its own modifier so only it — not the feed — observes selection.
private struct SelectionFollow: ViewModifier {
    /// (message to reveal, the previous one — direction)
    let reveal: (Int, Int?) -> Void

    @Environment(KeyboardRouter.self) private var keys

    func body(content: Content) -> some View {
        content
            .onChange(of: keys.selectedMessageId) { old, new in
                if let new { reveal(new, old) }
            }
            // ⇧↓/⇧↑ range extension moves the tip, not the anchor.
            .onChange(of: keys.extensionTip) { old, new in
                if let new { reveal(new, old) }
            }
            .onChange(of: keys.revealSelectionNonce) {
                if let id = keys.selectedMessageId { reveal(id, nil) }
            }
    }
}

/// "Ada is typing…" under the last message, for topic and DM narrows.
private struct TypingIndicatorRow: View {
    let store: PerAccountStore
    let narrow: Narrow

    /// Names of people typing in this exact conversation.
    static func typistNames(store: PerAccountStore, narrow: Narrow) -> [String] {
        let key: ConversationKey
        switch narrow {
        case .topic(let streamId, let topic):
            key = .topic(streamId: streamId, topic: topic)
        case .dm(let userIds):
            key = Unreads.dmKey(participantIds: userIds, selfUserId: store.selfUserId)
        default:
            return []
        }
        return store.typing.typistIds(in: key)
            .compactMap { store.users[$0]?.fullName }
    }

    var body: some View {
        let names = Self.typistNames(store: store, narrow: narrow)
        if !names.isEmpty {
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
    }
}
