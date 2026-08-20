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
    /// Cross-conversation feeds (Combined, Mentions, Starred, Search):
    /// the hover/tap controls show a go-to-conversation jump in place of
    /// quoted reply (which belongs to in-conversation views).
    var showsConversationJump = false
    var onNewMessages: (() -> Void)?
    /// Cross-conversation feeds: a message scrolled into view is marked
    /// read (batched).
    var marksReadOnView = false
    /// Warm-cache plumbing: where the viewport sits, recorded every scroll
    /// tick and read back on a warm reopen to land exactly there.
    var scrollMemory: FeedScrollMemory?

    @Environment(KeyboardRouter.self) private var keys
    @State private var anchorId: String?
    /// A parked position being restored (nil on fresh opens): overrides
    /// the marker/bottom opening behavior, validated against the model in
    /// init (a row evicted while parked falls back to a fresh open).
    @State private var restoredPosition: FeedScrollPosition?
    /// The mid-history restore ran (one-shot): re-appears of the same view
    /// (sheet dismissals) neither re-restore nor marker-nudge.
    @State private var didRestore = false
    /// A warm reopen found unreads that arrived while the feed was parked
    /// at the bottom: the NEW marker re-aims here on first appear
    /// (consumed one-shot — init must stay side-effect free).
    @State private var pendingMarkerReaim: Int?
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
        showsConversationJump: Bool = false,
        onNewMessages: (() -> Void)? = nil,
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
        self.onNewMessages = onNewMessages
        self.marksReadOnView = marksReadOnView
        self.scrollMemory = scrollMemory
        // A parked viewport position resumes exactly (a remembered row
        // must still be in the window — paging may have trimmed it).
        var restored = scrollMemory?.position
        if case .row(let id, _) = restored,
           !model.messages.contains(where: { $0.id == id })
        {
            restored = nil
        }
        // A feed parked at the bottom reopens at the first unread that
        // arrived while it was away — the logical resume point — not the
        // physical bottom; without fresh arrivals the bottom restore
        // stands. Decision only (this init re-runs on every parent
        // re-evaluation); onAppear re-aims the marker once.
        var reaimId: Int?
        if case .bottom(let newestId) = restored,
           let unreadId = model.firstUnreadId(after: newestId)
        {
            reaimId = unreadId
            restored = nil
        }
        _pendingMarkerReaim = State(initialValue: reaimId)
        _restoredPosition = State(initialValue: restored)
        // The scroll target must be known BEFORE the first layout pass:
        // an onAppear write lands after it, re-targeting the lazy stack
        // mid-estimation — which could park the viewport in unrealized
        // space (a blank transcript until a resize forced re-layout).
        // The restored row is a coarse first-frame stand-in (its bottom at
        // the viewport bottom); onAppear's settle pass nails the offset.
        let initialAnchor: String =
            switch restored {
            case .bottom: Self.bottomAnchorId
            case .row(let id, _): "msg-\(id)"
            case nil:
                // The re-aim targets the message row itself: the marker
                // item doesn't exist until onAppear places it.
                if let reaimId { "msg-\(reaimId)" }
                else if model.firstUnreadMarkerId != nil { "unread-marker" }
                else { Self.bottomAnchorId }
            }
        _anchorId = State(initialValue: initialAnchor)
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
        var containerHeight: CGFloat = 0
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
        PerfLog.measure("FeedList.items") { buildItems() }
    }

    private func buildItems() -> [Item] {
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
        PerfLog.measure("FeedList.sections") { buildSections() }
    }

    private func buildSections() -> [FeedSection] {
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

    /// Live row frames in scroll-viewport coordinates, for reveal
    /// decisions. A reference box, not observed state: frames change on
    /// every scroll tick and must not re-render the feed. (A previous
    /// visibility-set approach went stale — LazyVStack recycles rows
    /// without a final not-visible callback, so off-screen selections
    /// counted as visible and never scrolled.)
    private final class RowFrames {
        var frames: [Int: CGRect] = [:]
    }
    @State private var rowFrames = RowFrames()
    @State private var viewportHeight: CGFloat = 0
    /// Content hit response is paused while the feed scrolls: rows
    /// crossing a stationary cursor otherwise flip their hover state —
    /// a full row re-render (the controls overlay) per crossing, which
    /// stutters heavy transcripts. Restored shortly after the scroll
    /// settles; AppKit then re-delivers hover to the row under the
    /// cursor. (Parity: native scroll views swallow mid-momentum clicks.)
    @State private var isScrolling = false
    /// Debounce box for the hit-response restore (a reference box — a
    /// Task in @State would re-render the feed on every reassignment).
    private final class IdleDebounce {
        var task: Task<Void, Never>?
    }
    @State private var idleDebounce = IdleDebounce()

    var body: some View {
        let _ = PerfLog.render("FeedList")
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
                            // Warm-reopen marker re-aim, deferred out of
                            // init: place the NEW marker at the first
                            // unread that arrived while parked, so the
                            // settle pass below targets it.
                            if let reaimId = pendingMarkerReaim {
                                pendingMarkerReaim = nil
                                model.reaimUnreadMarker(to: reaimId)
                            }
                            // The binding (inner onAppear) has already put
                            // the target at the viewport bottom; once layout
                            // settles, nudge it up to the upper quarter.
                            let target: String?
                            if let highlight = keys.highlightMessageId,
                               model.messages.contains(where: { $0.id == highlight }) {
                                target = "msg-\(highlight)"
                            } else if case .row(let id, let fraction) = restoredPosition,
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
                        // Selection follows into view — but only when the
                        // row isn't already (near-)fully visible, so clicks
                        // and on-screen moves don't jolt. Direction-aware
                        // anchors leave clearance: upward reveals land
                        // below the pinned section header, downward ones
                        // keep a bottom margin. (anchor: nil's documented
                        // minimal reveal neither cleared the pinned header
                        // nor fired reliably in this lazy stack.)
                        .onChange(of: keys.selectedMessageId) { old, newId in
                            guard let newId,
                                  model.messages.contains(where: { $0.id == newId })
                            else { return }
                            revealSelection(newId, previous: old, proxy: proxy)
                        }
                        // ⇧↓/⇧↑ range extension moves the tip, not the
                        // anchor — follow it into view the same way.
                        .onChange(of: keys.extensionTip) { old, newTip in
                            guard let newTip,
                                  model.messages.contains(where: { $0.id == newTip })
                            else { return }
                            revealSelection(newTip, previous: old, proxy: proxy)
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
                keys.selectedMessageId = nil
                keys.clearMediaSelection()
                keys.attachmentList = nil
                keys.presentAttachments = nil
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
                isMultiSelected: keys.selectedMessageIds.contains(message.id),
                isLinkTarget: keys.highlightMessageId == message.id,
                showsConversationJump: showsConversationJump)
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

    /// Pins the feed to the true bottom. Lazy row heights are estimates
    /// until rows realize, so the binding's scroll can land short —
    /// corrective passes after layout settles converge on the real bottom.
    /// Bails if the user scrolls away mid-settle (the position binding
    /// leaves the sentinel).
    private func scrollToBottomSettled(_ proxy: ScrollViewProxy) {
        anchorId = Self.bottomAnchorId
        Task { @MainActor in
            // Same per-frame polling as selection reveals: watch the
            // geometry, re-assert sparingly, finish with one exact pass
            // the moment the viewport reaches the bottom neighborhood.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(1)
            var lastAssert = clock.now
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                guard anchorId == Self.bottomAnchorId else { return }
                if nearBottom {
                    proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                    return
                }
                guard clock.now - lastAssert >= .milliseconds(150) else { continue }
                proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                lastAssert = clock.now
            }
        }
    }

    /// Restores a parked viewport: the remembered row's bottom edge back
    /// at its remembered viewport fraction. The init anchor put the row's
    /// neighborhood on screen (realizing it); the exact pass targets the
    /// row's bottom sentinel — a fractional row anchor would drift with
    /// row height. Same settle-poll shape as scrollToBottomSettled: lazy
    /// height estimates land the first pass short, re-asserts converge.
    private func settleRestore(id: Int, fraction: CGFloat, proxy: ScrollViewProxy) {
        let fraction = min(max(fraction, 0), 1)
        Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(1)
            var lastAssert = clock.now
            proxy.scrollTo("msgbot-\(id)", anchor: UnitPoint(x: 0, y: fraction))
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                if let frame = rowFrames.frames[id], viewportHeight > 0,
                   abs(frame.maxY - fraction * viewportHeight) < 2
                {
                    return
                }
                guard clock.now - lastAssert >= .milliseconds(150) else { continue }
                proxy.scrollTo("msgbot-\(id)", anchor: UnitPoint(x: 0, y: fraction))
                lastAssert = clock.now
            }
        }
    }

    /// Clearance under the pinned section header: a row whose top is
    /// inside it counts as covered, not visible.
    private static let headerClearance: CGFloat = 28

    /// Whether the row sits acceptably in the viewport (top clear of the
    /// pinned header; tall rows only need their top placed). The lenient
    /// gate: an already-visible row is never scrolled.
    private func revealPlaced(_ id: Int) -> Bool {
        guard viewportHeight > 0, let frame = rowFrames.frames[id] else { return false }
        if frame.height > viewportHeight * 0.8 {
            return frame.minY >= Self.headerClearance
                && frame.minY <= viewportHeight * 0.25
        }
        return frame.minY >= Self.headerClearance && frame.maxY <= viewportHeight
    }

    /// Settle-phase success: fully visible AND at the direction-appropriate
    /// end. A coarse recovery can land the row at the wrong extreme
    /// (bottom of the screen while keying up); this keeps the settle loop
    /// running until the exact directional pass has placed it.
    private func revealSettled(_ id: Int, movingUp: Bool) -> Bool {
        guard viewportHeight > 0, let frame = rowFrames.frames[id] else { return false }
        if frame.height > viewportHeight * 0.8 {
            return frame.minY >= Self.headerClearance
                && frame.minY <= viewportHeight * 0.25
        }
        guard frame.minY >= Self.headerClearance, frame.maxY <= viewportHeight
        else { return false }
        return movingUp
            ? frame.minY <= viewportHeight * 0.55
            : frame.maxY >= viewportHeight * 0.45
    }

    /// Reveal diagnostics, silent unless launched with `-perfLog YES`
    /// (`make perf`) — kept for future scroll-placement debugging.
    private func revealLog(_ stage: String, id: Int) {
        guard PerfLog.enabled else { return }
        let frameText = rowFrames.frames[id].map { String(describing: $0) }
            ?? "nil (unrealized)"
        print("perf reveal \(stage): id=\(id) frame=\(frameText) viewport=\(viewportHeight)")
    }

    /// Scrolls the newly selected message into place. Unrealized targets
    /// scroll by the lazy stack's height estimates (or not at all when the
    /// id isn't registered yet), so settle passes re-check the actual
    /// frame and re-assert until placement verifies — the first attempt's
    /// churn realizes the row, the retry lands it exactly.
    private func revealSelection(_ id: Int, previous: Int?, proxy: ScrollViewProxy) {
        guard !revealPlaced(id) else {
            revealLog("already placed", id: id)
            return
        }
        revealLog("begin", id: id)
        let movingUp = previous.map { id < $0 } ?? false
        assertReveal(id, movingUp: movingUp, proxy: proxy)
        Task { @MainActor in
            // Poll per frame (geometry lands at most once per frame), so
            // settling registers immediately; re-assert sparingly so the
            // in-flight scroll animation gets room to run. One-second
            // deadline; abandons the moment the selection moves on.
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(1)
            var lastAssert = clock.now
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                // Anchor reveals abandon when the anchor moves on; tip
                // reveals (⇧ extension) when the tip does.
                guard keys.selectedMessageId == id || keys.extensionTip == id
                else { return }
                if revealSettled(id, movingUp: movingUp) {
                    revealLog("settled", id: id)
                    return
                }
                guard clock.now - lastAssert >= .milliseconds(150) else { continue }
                revealLog("re-assert", id: id)
                assertReveal(id, movingUp: movingUp, proxy: proxy)
                lastAssert = clock.now
            }
        }
    }

    /// One reveal assertion. A realized row gets the exact sentinel
    /// placement; an unrealized one is unreachable by proxy.scrollTo (its
    /// id isn't registered — the no-op could never realize it), so the
    /// scroll-position BINDING coarse-jumps there instead. The binding
    /// resolves the layout's DIRECT child identities — the row item ids,
    /// not the overlay sentinels — bottom-anchored, so the row lands
    /// fully visible and realized; the poll then verifies or refines.
    private func assertReveal(_ id: Int, movingUp: Bool, proxy: ScrollViewProxy) {
        guard rowFrames.frames[id] == nil else {
            performReveal(id, movingUp: movingUp, proxy: proxy)
            return
        }
        if anchorId != "msg-\(id)" {
            withAnimation(.easeInOut(duration: 0.2)) {
                anchorId = "msg-\(id)"
            }
            return
        }
        // The binding already holds the target — an identical write
        // coalesces to nothing (the estimate-based jump missed and won't
        // re-fire). Page toward the target via its nearest REALIZED
        // neighbor, which proxy.scrollTo can always reach; each pass
        // realizes more rows until the target itself appears.
        let neighbor = movingUp
            ? rowFrames.frames.keys.filter { $0 > id }.min()
            : rowFrames.frames.keys.filter { $0 < id }.max()
        guard let neighbor else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(
                "msg-\(neighbor)",
                anchor: movingUp ? .bottom : .top)
        }
    }

    private func performReveal(_ id: Int, movingUp: Bool, proxy: ScrollViewProxy) {
        let tall = viewportHeight > 0
            && (rowFrames.frames[id]?.height ?? 0) > viewportHeight * 0.8
        withAnimation(.easeInOut(duration: 0.2)) {
            if movingUp || tall {
                // Top edge at 8% of the viewport — below the pinned header.
                proxy.scrollTo("msgtop-\(id)", anchor: UnitPoint(x: 0.5, y: 0.08))
            } else {
                // Bottom edge at 92% — clear of the viewport bottom.
                proxy.scrollTo("msgbot-\(id)", anchor: UnitPoint(x: 0.5, y: 0.92))
            }
        }
    }

    /// One auto-scroll pass per launch, no matter how many feeds open.
    @MainActor private static var didRunAutoScroll = false

    /// Perf harness (`make perf` plus `-perfAutoScroll YES`): drives a fast
    /// upward scroll through history and back down to the bottom, so probe
    /// numbers are repeatable without hand-scrolling. Paging kicks in the
    /// same way it does for a real fling (the top loader realizes as the
    /// viewport reaches it). No-op unless both flags are set.
    private func runAutoScrollIfRequested(_ proxy: ScrollViewProxy) async {
        guard PerfLog.enabled,
              UserDefaults.standard.bool(forKey: "perfAutoScroll"),
              case .channel = model.narrow,  // The harness's own target.
              !Self.didRunAutoScroll
        else { return }
        Self.didRunAutoScroll = true
        // Wait out the initial server fetch — paging is blocked behind
        // isFetching, and the offline preview's window is not the real one.
        for _ in 0..<80 {
            if model.didInitialFetch, !model.isFetching { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(2))
        // A perf pass must not touch server state: cross-conversation
        // feeds mark rows read as they scroll into view. (The next feed's
        // onAppear unpauses, so this only covers the harness itself.)
        keys.readMarkingPaused = true
        print(
            "perf autoscroll: begin narrow=\(model.narrow) "
                + "messages=\(model.messages.count) haveOldest=\(model.haveOldest) "
                + "offline=\(model.isOfflineFallback)")
        // Fill the window to its cap up front (the loader row's onAppear
        // does not re-fire under programmatic sweeps), so the sweeps
        // traverse the largest window the channel supports.
        var lastCount = -1
        while model.messages.count < 590, !model.haveOldest,
              model.messages.count != lastCount {
            lastCount = model.messages.count
            await model.fetchOlder()
        }
        print(
            "perf autoscroll: window filled, messages=\(model.messages.count) "
                + "haveOldest=\(model.haveOldest) "
                + "error=\(model.fetchError.map { String(describing: $0) } ?? "none")")
        // Upward in continuous sweeps: ~45 rows over 1.4 s each, so rows
        // cross the scroll anchor continuously, like a real fling. Keeps
        // going while older history pages in, until the window is full
        // (the 600 cap) or history runs out.
        var cursor = model.messages.last?.id
        for sweep in 0..<24 {
            guard !Task.isCancelled, let id = cursor, !model.messages.isEmpty
            else { break }
            let index = model.messages.firstIndex { $0.id == id }
                ?? model.messages.count / 2  // Cursor row trimmed away.
            let nextIndex = max(0, index - 45)
            let next = model.messages[nextIndex].id
            withAnimation(.linear(duration: 1.4)) {
                // At the very top, land the first row at the viewport
                // bottom instead: the older-history loader sits above it
                // and must come on screen to realize and page.
                proxy.scrollTo(
                    "msg-\(next)", anchor: nextIndex == 0 ? .bottom : .top)
            }
            cursor = next
            try? await Task.sleep(for: .milliseconds(1500))
            if nextIndex == 0 {
                if model.haveOldest || model.messages.count >= 590 {
                    print("perf autoscroll: top of window at sweep \(sweep), messages=\(model.messages.count)")
                    break
                }
                // At the top edge while more history pages in.
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        print("perf autoscroll: up leg done, messages=\(model.messages.count)")
        // Downward: same sweeps back to the newest message (paging newer
        // again if the window trimmed the bottom away).
        for _ in 0..<24 {
            guard !Task.isCancelled, let id = cursor, !model.messages.isEmpty
            else { break }
            let index = model.messages.firstIndex { $0.id == id }
                ?? model.messages.count / 2
            let nextIndex = min(model.messages.count - 1, index + 45)
            let next = model.messages[nextIndex].id
            withAnimation(.linear(duration: 1.4)) {
                proxy.scrollTo("msg-\(next)", anchor: .bottom)
            }
            cursor = next
            try? await Task.sleep(for: .milliseconds(1500))
            if nextIndex == model.messages.count - 1, model.haveNewest {
                break
            }
        }
        proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
        print("perf autoscroll: done, messages=\(model.messages.count)")
    }

    /// Seen-in-view read marking, batched so a scroll doesn't spam the
    /// flags endpoint.
    private func noteSeen(_ identifiers: [String]) {
        guard marksReadOnView else { return }
        for identifier in identifiers {
            guard identifier.hasPrefix("msg-"),
                  let id = Int(identifier.dropFirst(4)),
                  let message = model.messages.first(where: { $0.id == id })
            else { continue }
            noteSeen(message)
        }
    }

    private func noteSeen(_ message: Message) {
        guard marksReadOnView, !keys.readMarkingPaused,
              !(message.flags ?? []).contains("read"),
              !pendingReadIds.contains(message.id)
        else { return }
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
        .scrollPosition(id: $anchorId, anchor: .bottom)
        // Read-marking feeds need actual viewport visibility, not lazy-
        // stack realization. Observe the scroll target IDs once at the
        // container instead of installing a visibility observer on every
        // message row. Transcripts that mark the whole conversation read
        // install no visibility tracking at all.
        .modifier(VisibleMessageTargets(enabled: marksReadOnView) { identifiers in
            noteSeen(identifiers)
        })
        .onScrollPhaseChange { _, newPhase in
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
            return FeedGeometry(
                nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 60,
                lost: lost,
                containerHeight: geometry.containerSize.height)
        } action: { old, new in
            viewportHeight = new.containerHeight
            // Distance alone misfires: the floating bar's bottom insets
            // can park the rest position right at the 60pt threshold,
            // showing the jump arrow while visually at the bottom. The
            // last row's actual frame is authoritative when realized —
            // bottom message in view means no arrow.
            let lastRowVisible = model.messages.last
                .flatMap { rowFrames.frames[$0.id] }
                .map { $0.minY < new.containerHeight && $0.maxY > 0 } ?? false
            nearBottom = new.nearBottom || lastRowVisible
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
                    scrollMemory.position = .row(
                        id: id, fraction: frame.maxY / new.containerHeight)
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

/// Conditionally installs the feed-wide visible-target observer. Keeping
/// the disabled branch genuinely modifier-free matters for ordinary topic
/// and DM transcripts, which do not mark individual rows as they pass by.
private struct VisibleMessageTargets: ViewModifier {
    let enabled: Bool
    let action: ([String]) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onScrollTargetVisibilityChange(
                idType: String.self, threshold: 0.2, action)
        } else {
            content
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

    @Environment(KeyboardRouter.self) private var keys: KeyboardRouter?
    @State private var showRename = false
    @State private var renameText = ""

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
                // The # (or lock/globe) marks the channel — shown only when
                // the channel is part of the label. A topic-only header in
                // a channel feed shouldn't wear a channel glyph.
                if includeChannel || streamId == nil {
                    Image(systemName: glyph)
                        .font(.body.weight(.bold))
                        .foregroundStyle(
                            streamId == nil
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(channelColor))
                }
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
        .contextMenu {
            switch conversationKey {
            case .topic(let streamId, let topic):
                topicMenu(streamId: streamId, topic: topic)
            case .dm:
                Button("Mark as Read") {
                    store.markConversationRead(conversationKey)
                }
                Button("Copy Link to Conversation", systemImage: "link") {
                    Platform.copyToPasteboard(conversationKey.link(in: store))
                }
            }
        }
        .alert("Rename Topic", isPresented: $showRename) {
            TextField("Topic", text: $renameText)
            Button("Rename") {
                if case .topic(let streamId, let topic) = conversationKey {
                    store.renameTopic(streamId: streamId, topic: topic, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message in the topic moves to the new name.")
        }
    }

    @ViewBuilder
    private func topicMenu(streamId: Int, topic: String) -> some View {
        let visibility = store.topicVisibility(streamId: streamId, topic: topic)
        Button(visibility == .muted ? "Unmute Topic" : "Mute Topic") {
            store.setTopicVisibility(
                streamId: streamId, topic: topic,
                policy: visibility == .muted ? .none : .muted)
        }
        Button(visibility == .followed ? "Unfollow Topic" : "Follow Topic") {
            store.setTopicVisibility(
                streamId: streamId, topic: topic,
                policy: visibility == .followed ? .none : .followed)
        }
        Button(
            isResolved ? "Unresolve Topic" : "Resolve Topic",
            systemImage: isResolved ? "checkmark.circle.badge.xmark" : "checkmark.circle"
        ) {
            store.setTopicResolved(streamId: streamId, topic: topic, resolved: !isResolved)
        }
        Button("Rename Topic…") {
            renameText = TopicName.displayName(topic)
            showRename = true
        }
        Divider()
        Button("Mark Topic as Read") {
            store.markConversationRead(conversationKey)
        }
        Button("Mark All as Unread") {
            keys?.readMarkingPaused = true
            store.markConversationUnread(conversationKey)
        }
        Button("Copy Link to Topic", systemImage: "link") {
            Platform.copyToPasteboard(conversationKey.link(in: store))
        }
        if includeChannel {
            Divider()
            Button("Open Channel") {
                keys?.navigate?(.channel(streamId: streamId))
            }
        }
    }
}

struct MessageRow: View {
    let store: PerAccountStore
    let message: Message
    let showHeader: Bool
    let cache: MessageContentCache
    var useMatchHighlights = false
    var isKeySelected = false
    /// Extended-selection member (lighter ring than the anchor's).
    var isMultiSelected = false
    /// A followed message link flashes its target.
    var isLinkTarget = false
    /// Set in cross-conversation feeds: the control row swaps quoted
    /// reply for a jump to the message's own conversation.
    var showsConversationJump = false

    @Environment(KeyboardRouter.self) private var keys
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// One state box per realized row instead of a box for every control.
    /// All of these values invalidate the same row body, so splitting them
    /// only multiplies AttributeGraph setup and teardown while scrolling.
    private struct InteractionState {
        var hovering = false
        var showReactionPicker = false
        var editing = false
        var editText = ""
        var showMoveSheet = false
        var showTranslation = false
        var showReadReceipts = false
        var showForward = false
        var showRemindPicker = false
        var showEditHistory = false
        #if !os(macOS)
        /// Context-menu Share…: the message as text, staged for the sheet.
        var sharePayload: SharePayload?
        #endif
        #if os(iOS)
        /// Live horizontal swipe translation (right = mark unread, left =
        /// toggle star); springs back after release.
        var swipeOffset: CGFloat = 0
        var swipeTriggerCount = 0
        #endif
    }
    @State private var interaction = InteractionState()

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

    private var isUnread: Bool {
        !(message.flags ?? []).contains("read")
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
        let _ = PerfLog.render("MessageRow")
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
                                interaction.showEditHistory = true
                            } label: {
                                Text("Edited")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .help("Show edit history")
                            .popover(isPresented: $interaction.showEditHistory) {
                                EditHistoryView(store: store, message: message)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                if interaction.editing {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Message", text: $interaction.editText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...12)
                            .padding(6)
                            .background(
                                .quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button("Cancel") { interaction.editing = false }
                                .keyboardShortcut(.cancelAction)
                            Button("Save") {
                                let content = interaction.editText.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                                if !content.isEmpty {
                                    store.editMessage(message.id, content: content)
                                }
                                interaction.editing = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        .controlSize(.small)
                    }
                } else if let widget = MessageWidget.parse(message) {
                    MessageWidgetView(widget: widget, store: store, messageId: message.id)
                        // Polls/todos are what the message window is for;
                        // surface its tip on one.
                        .popoverTip(MessageWindowTip())
                        .onAppear {
                            MessageWindowTip.supportsMultipleWindows =
                                supportsMultipleWindows
                        }
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
            isLinkTarget ? Color.yellow.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        // Selection reads as a system-highlight outline, not a fill; the
        // anchor gets the full ring, extended members a lighter one.
        // While an attachment inside the message is selected, only its
        // accent ring shows — the message stays the keyboard context
        // (reply/star/j/k) without reading as a second selection.
        .overlay {
            if keys.selectedMediaId == nil {
                if isKeySelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Self.selectionColor, lineWidth: 2)
                } else if isMultiSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Self.selectionColor.opacity(0.45), lineWidth: 2)
                }
            }
        }
        // The whole row rect is clickable/right-clickable even where it's
        // transparent — without this, only the drawn text (or a selected
        // row's highlight fill) hit-tests, so clicks in the empty trailing
        // space fall through.
        .contentShape(.rect)
        #if os(iOS)
        // Swipe: right marks unread, left toggles star. The hint icons sit
        // behind the row and fade in as the swipe approaches its trigger.
        .offset(x: interaction.swipeOffset)
        .background(alignment: .leading) {
            if interaction.swipeOffset > 8 {
                Image(systemName: "message.badge.filled.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .opacity(min(interaction.swipeOffset / Self.swipeTrigger, 1))
                    .padding(.leading, 10)
            }
        }
        .background(alignment: .trailing) {
            if interaction.swipeOffset < -8 {
                Image(systemName: isStarred ? "star.slash.fill" : "star.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .opacity(min(-interaction.swipeOffset / Self.swipeTrigger, 1))
                    .padding(.trailing, 10)
            }
        }
        .gesture(messageSwipe, isEnabled: Self.swipeEnabled)
        .sensoryFeedback(.impact(weight: .medium), trigger: interaction.swipeTriggerCount)
        #endif
        // Web-style unread marker: an accent line on the left that melts
        // away when the message is marked read. Always present (at zero
        // opacity once read) so the disappearance animates.
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.tint)
                .frame(width: 3)
                .padding(.vertical, 2)
                .opacity(isUnread ? 1 : 0)
                .animation(.easeOut(duration: 0.6), value: isUnread)
        }
        // Click/tap selects (like the web app); simultaneous so links and
        // buttons inside the row keep working. macOS: ⌘-click toggles
        // multi-selection membership, ⇧-click ranges from the anchor.
        .simultaneousGesture(TapGesture().onEnded {
            #if os(macOS)
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) || flags.contains(.shift) {
                // Deferred: an attachment under the same click reports
                // too, and its report wins (the router arbitrates).
                keys.reportModifierClick(
                    message: message.id, command: flags.contains(.command))
            } else {
                keys.selectedMessageId = message.id
                // A tap on an attachment also lands here (simultaneous,
                // in unspecified order); that tap's media selection must
                // survive — any other row tap drops a stale one.
                if !keys.mediaTapInFlight {
                    keys.clearMediaSelection()
                }
            }
            #else
            keys.selectedMessageId = message.id
            if !keys.mediaTapInFlight {
                keys.clearMediaSelection()
            }
            #endif
            // Clicking a message reclaims arrow keys from the sidebar.
            keys.focusMessages?()
        })
        // Double-click pops the message into its own window (the message
        // sibling of the sidebar's detach) — handy for monitoring a poll
        // or todo list. Plain .gesture, not simultaneous: interactive
        // children (links, vote buttons, attachments with their own
        // double-click) win where they hit-test.
        .gesture(
            TapGesture(count: 2).onEnded {
                MessageWindowTip().invalidate(reason: .actionPerformed)
                openWindow(value: MessageWindow(
                    accountId: store.accountId, messageId: message.id))
            },
            isEnabled: supportsMultipleWindows)
        .onChange(of: interaction.editing) {
            // The inline editor's TextField must also silence single-key
            // navigation (it shares the detail focus scope).
            keys.editingMessage = interaction.editing
        }
        .onDisappear {
            if interaction.editing {
                keys.editingMessage = false
            }
        }
        .onChange(of: keys.editRequestId) { _, requested in
            guard requested == message.id else { return }
            keys.editRequestId = nil
            Task {
                interaction.editText = await store.fetchRawContent(message.id) ?? ""
                if !interaction.editText.isEmpty {
                    interaction.editing = true
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
                interaction.showTranslation = true
            case .moveToTopic:
                if message.type == .stream {
                    interaction.showMoveSheet = true
                }
            case .forward:
                interaction.showForward = true
            case .markUnreadFromHere:
                markUnreadFromHere()
            }
        }
        .overlay(alignment: .topTrailing) {
            // Fixed layout (opacity gating, not insertion) so the star sits
            // in exactly the same spot as control and as starred indicator.
            // macOS reveals on hover; touch reveals on tap (selection).
            #if os(macOS)
            let controlsActive = interaction.hovering || interaction.showReactionPicker
            #else
            let controlsActive = isKeySelected || interaction.showReactionPicker
            #endif
            // Top-aligned: the buttons' padding would otherwise center the
            // time a few points below its message's first line.
            HStack(alignment: .top, spacing: 2) {
                if showsConversationJump {
                    // Cross-conversation feeds swap quoted reply for a
                    // jump to the message's own conversation.
                    Button {
                        goToConversation()
                    } label: {
                        Image(systemName: "arrow.turn.down.right")
                            .font(controlFont)
                            .foregroundStyle(.secondary)
                            .padding(controlPadding)
                            .background(.quaternary.opacity(0.6), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Go to conversation")
                    .opacity(controlsActive ? 1 : 0)
                    .allowsHitTesting(controlsActive)
                } else {
                    Button {
                        quoteAndReply()
                    } label: {
                        Image(systemName: "text.quote")
                            .font(controlFont)
                            .foregroundStyle(.secondary)
                            .padding(controlPadding)
                            .background(.quaternary.opacity(0.6), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Reply quoting this message")
                    .opacity(controlsActive ? 1 : 0)
                    .allowsHitTesting(controlsActive)
                }
                Button {
                    interaction.showReactionPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(controlFont)
                        .foregroundStyle(.secondary)
                        .padding(controlPadding)
                        .background(.quaternary.opacity(0.6), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Add reaction")
                .popover(isPresented: $interaction.showReactionPicker) {
                    EmojiPickerView(store: store) { entry in
                        store.toggleReaction(
                            message: message, emojiName: entry.name,
                            emojiCode: entry.code, reactionType: entry.reactionType)
                    }
                }
                .opacity(controlsActive ? 1 : 0)
                .allowsHitTesting(controlsActive)
                if store.supportsReminders {
                    // Hover control and pending-reminder indicator in one:
                    // gray outline clock on hover, orange filled clock while
                    // a reminder is set (the star's treatment).
                    let reminder = store.reminderForMessage(message.id)
                    Menu {
                        reminderMenuItems()
                    } label: {
                        Image(systemName: reminder == nil ? "clock" : "clock.fill")
                            .font(controlFont)
                            .foregroundStyle(
                                reminder == nil
                                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .padding(controlPadding)
                            .background(
                                controlsActive
                                    ? AnyShapeStyle(.quaternary.opacity(0.6))
                                    : AnyShapeStyle(.clear),
                                in: .circle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(
                        reminder.map { "Reminder: \(Self.reminderTimeText($0))" }
                            ?? "Remind me about this")
                    .opacity(controlsActive || reminder != nil ? 1 : 0)
                    .allowsHitTesting(controlsActive || reminder != nil)
                }
                Button {
                    store.setStarred(!isStarred, messageId: message.id)
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(controlFont)
                        .foregroundStyle(
                            isStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                        .padding(controlPadding)
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
        .onHover { interaction.hovering = $0 }
        .contextMenu {
            messageMenu()
        }
        // System translation UI, on-device (absent on platforms without
        // the Translation framework).
        .modifier(TranslationSheet(
            isPresented: $interaction.showTranslation, text: content.plainText))
        .sheet(isPresented: $interaction.showMoveSheet) {
            MoveTopicSheet(store: store, subject: .message(message))
        }
        .sheet(isPresented: $interaction.showReadReceipts) {
            ReadReceiptsSheet(store: store, message: message)
        }
        .sheet(isPresented: $interaction.showForward) {
            ForwardMessageSheet(store: store) { destination in
                interaction.showForward = false
                forwardMessage(to: destination)
            }
        }
        .sheet(isPresented: $interaction.showRemindPicker) {
            RemindTimeSheet { date in
                remind(at: date)
            }
        }
        #if !os(macOS)
        .sheet(item: $interaction.sharePayload) { payload in
            ShareActivityView(items: payload.items) { interaction.sharePayload = nil }
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    static func reminderTimeText(_ reminder: Reminder) -> String {
        Date(timeIntervalSince1970: TimeInterval(reminder.scheduledDeliveryTimestamp))
            .formatted(date: .abbreviated, time: .shortened)
    }

    #if os(iOS)
    /// Swipe actions (right = mark unread, left = star) are parked for
    /// now; flip to re-enable.
    private static let swipeEnabled = false
    private static let swipeTrigger: CGFloat = 60

    private var messageSwipe: some Gesture {
        DragGesture(minimumDistance: 25)
            .onChanged { value in
                // Horizontal intent only — vertical belongs to the scroll.
                guard abs(value.translation.width)
                    > abs(value.translation.height) * 1.5 else { return }
                let translation = value.translation.width
                let magnitude = abs(translation)
                // Rubber-band past the trigger distance.
                let banded = min(magnitude, Self.swipeTrigger)
                    + max(magnitude - Self.swipeTrigger, 0) * 0.2
                interaction.swipeOffset = translation < 0 ? -banded : banded
            }
            .onEnded { value in
                defer {
                    withAnimation(.snappy) { interaction.swipeOffset = 0 }
                }
                guard abs(value.translation.width)
                    > abs(value.translation.height) * 1.5 else { return }
                if value.translation.width > Self.swipeTrigger {
                    interaction.swipeTriggerCount += 1
                    // Same pause as Mark as Unread from Here: the on-screen
                    // row must not immediately re-mark itself read.
                    keys.readMarkingPaused = true
                    store.markMessageUnread(message.id)
                } else if value.translation.width < -Self.swipeTrigger {
                    interaction.swipeTriggerCount += 1
                    store.setStarred(!isStarred, messageId: message.id)
                }
            }
    }
    #endif

    /// Hover-control metrics: pointer-sized on macOS, tap-sized on touch.
    private var controlFont: Font {
        #if os(macOS)
        .callout
        #else
        .title3
        #endif
    }

    private var controlPadding: CGFloat {
        #if os(macOS)
        5
        #else
        10
        #endif
    }

    /// The reminder actions, shared by the hover clock button and the
    /// context menu: preset times (plus custom) — or just Cancel while a
    /// reminder is already pending.
    @ViewBuilder
    private func reminderMenuItems() -> some View {
        if let reminder = store.reminderForMessage(message.id) {
            Button("Cancel Reminder", systemImage: "clock.badge.xmark") {
                store.cancelReminder(reminder.reminderId)
            }
        } else {
            Button("In 1 Hour") { remind(at: .now.addingTimeInterval(3600)) }
            Button("In 3 Hours") { remind(at: .now.addingTimeInterval(3 * 3600)) }
            Button("Tomorrow at 9 AM") { remind(at: nextMorning(daysAhead: 1)) }
            Button("Next Week at 9 AM") { remind(at: nextMorning(daysAhead: 7)) }
            Divider()
            Button("At a Custom Time…") { interaction.showRemindPicker = true }
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
                interaction.showForward = true
            }
            if message.senderId != store.selfUserId {
                Button(
                    "Direct Message \(message.senderFullName)",
                    systemImage: "envelope"
                ) {
                    keys.navigate?(.conversation(Unreads.dmKey(
                        participantIds: [message.senderId],
                        selfUserId: store.selfUserId)))
                }
            }
            Button(isStarred ? "Unstar" : "Star", systemImage: "star") {
                store.setStarred(!isStarred, messageId: message.id)
            }
            Button("Mark as Unread from Here", systemImage: "message.badge") {
                markUnreadFromHere()
            }
            #if !os(macOS)
            // Out-of-app share (AirDrop, Messages, save, print) — distinct
            // from Forward, which stays inside Zulip.
            Button("Share…", systemImage: "square.and.arrow.up") {
                interaction.sharePayload = SharePayload(
                    items: [messageShareText(message, content: content)])
            }
            #endif
            Button("Copy Text", systemImage: "doc.on.doc") {
                Platform.copyToPasteboard(content.plainText)
            }
            Button("Copy Message Reference", systemImage: "link") {
                Platform.copyToPasteboard(
                    ConversationKey.permalink(to: message, in: store))
            }
            #if canImport(Translation) && !os(visionOS)
            Button("Translate", systemImage: "translate") {
                interaction.showTranslation = true
            }
            #endif
            Button("Seen By…", systemImage: "eye") {
                interaction.showReadReceipts = true
            }
            if store.supportsReminders {
                if store.reminderForMessage(message.id) != nil {
                    reminderMenuItems()
                } else {
                    Menu("Remind Me About This") {
                        reminderMenuItems()
                    }
                }
            }
            if message.type == .stream {
                Button("Move Message…", systemImage: "arrow.turn.up.right") {
                    interaction.showMoveSheet = true
                }
            }
            if message.senderId == store.selfUserId {
                Divider()
                Button("Edit Message", systemImage: "pencil") {
                    Task {
                        interaction.editText = await store.fetchRawContent(message.id) ?? ""
                        if !interaction.editText.isEmpty {
                            interaction.editing = true
                        }
                    }
                }
                Button("Delete Message", systemImage: "trash", role: .destructive) {
                    store.deleteMessage(message.id)
                }
            }
        
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
            let quote = messageQuoteBlock(message, raw: raw, store: store)
            keys.navigate?(destination)
            try? await Task.sleep(for: .milliseconds(300))
            keys.insertIntoCompose?(quote)
            keys.focusCompose?()
        }
    }

    /// Jumps to the message's own conversation, anchored at (and
    /// flashing) the message — the near-link navigation pattern.
    private func goToConversation() {
        guard let key = Unreads.conversationKey(
            for: message, selfUserId: store.selfUserId) else { return }
        keys.highlightMessageId = message.id
        keys.pendingNear = (key, message.id)
        keys.navigate?(.conversation(key))
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
            let quote = messageQuoteBlock(message, raw: raw, store: store)
            // Cross-conversation feeds have no compose: jump to the
            // message's conversation first, then insert.
            if keys.insertIntoCompose == nil,
               let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId) {
                keys.navigate?(.conversation(key))
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Channel feed: the topic field follows the quoted message
            // (no-op elsewhere — only channel-mode compose registers).
            keys.setComposeTopic?(message.subject)
            keys.insertIntoCompose?(quote)
            keys.focusCompose?()
        }
    }
}

/// Hugs its content's ideal width up to `maxWidth`, wrapping beyond it.
/// Overlays propose the base view's size, which defeats the usual
/// frame(maxWidth:)/fixedSize combinations — a hover card anchored to a
/// small pill needs its own sizing.
private struct CappedWidthLayout: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(.unspecified)
        if ideal.width <= maxWidth { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct ReactionsRow: View {
    let store: PerAccountStore
    let message: Message

    private var reactions: [Reaction] { message.reactions }

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

    /// "Steven Nguyen, You" — the hover card; self listed last as "You",
    /// long lists capped ("…, 14 others").
    private func reactorNames(_ group: Group) -> String {
        var names = group.userIds
            .filter { $0 != store.selfUserId }
            .map { store.users[$0]?.fullName ?? "Someone" }
        if group.reactedBySelf {
            names.append("You")
        }
        if names.count > 12 {
            let extra = names.count - 11
            names = Array(names.prefix(11)) + ["\(extra) others"]
        }
        return names.joined(separator: ", ")
    }

    /// The pill whose reactor card is showing (pointer rested on it for a
    /// beat; macOS and iPad-trackpad hover).
    @State private var hoverCardGroupId: String?
    @State private var hoverTask: Task<Void, Never>?

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
                .accessibilityLabel(
                    "\(reactorNames(group)) reacted with \(group.sample.emojiName)")
                // Immediate who-reacted card (the system tooltip's 1.5s
                // delay made it feel absent): a real popover after a short
                // rest — window-backed, so the message view can't clip it,
                // and the system flips it below when there's no room above.
                .popover(
                    isPresented: Binding(
                        get: { hoverCardGroupId == group.id },
                        set: { if !$0 { hoverCardGroupId = nil } }),
                    arrowEdge: .top
                ) {
                    reactorCard(group)
                        .presentationCompactAdaptation(.popover)
                }
                .onHover { inside in
                    hoverTask?.cancel()
                    if inside {
                        hoverTask = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            hoverCardGroupId = group.id
                        }
                    } else if hoverCardGroupId == group.id {
                        hoverCardGroupId = nil
                    }
                }
            }
            // No trailing "+" pill: adding lives in the hover controls
            // (and the context menu), keeping the row to actual reactions.
        }
        .padding(.top, 1)
    }

    private func reactorCard(_ group: Group) -> some View {
        // The popover supplies its own chrome; the layout caps the width
        // (popovers propose ideal size, which would put a long reactor
        // list on one very wide line).
        CappedWidthLayout(maxWidth: 240) {
            VStack(alignment: .leading, spacing: 2) {
                Text(reactorNames(group))
                    .font(.caption.weight(.medium))
                Text(":\(group.sample.emojiName):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
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
