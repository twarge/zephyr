import SwiftUI
import ZulipModel

/// Scroll placement for the feed: bottom pins, opening re-assertion,
/// parked-position restores, selection reveals, and the perf harness's
/// auto-scroll — all converging through one settle loop.
extension MessageFeedList {
    /// Pins the feed to the true bottom. Lazy row heights are estimates
    /// until rows realize, so the binding's scroll can land short —
    /// corrective passes after layout settles converge on the real bottom.
    /// Bails if the user scrolls away mid-settle (the position binding
    /// leaves the sentinel).
    func scrollToBottomSettled(_ proxy: ScrollViewProxy) {
        scroll(to: Self.bottomAnchorId)
        // Finishes with one exact pass the moment the viewport reaches
        // the bottom neighborhood.
        settle {
            guard anchorId == Self.bottomAnchorId else { return true }
            if nearBottom {
                proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                return true
            }
            return false
        } reassert: {
            proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
        }
    }

    /// The settle loop shared by bottom pins, restores, and selection
    /// reveals. Lazy row heights are estimates until rows realize, so a
    /// first scroll can land short: poll per frame (geometry lands at most
    /// once per frame) until `done` — settled, or abandoned — re-asserting
    /// sparingly so an in-flight scroll animation gets room to run, for up
    /// to a second.
    func settle(
        done: @escaping @MainActor () -> Bool, reassert: @escaping @MainActor () -> Void
    ) {
        Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(1)
            var lastAssert = clock.now
            while clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                if done() { return }
                guard clock.now - lastAssert >= .milliseconds(150) else { continue }
                reassert()
                lastAssert = clock.now
            }
        }
    }

    /// Puts the open back where it was placed when the window's opening
    /// layout resizes the viewport under it: the toolbar takes its full
    /// height a pass after the feed's first placement, and the feed
    /// drifted with it. On the next turn — before the window is on screen
    /// — rather than leaving it to the deferred passes, whose correction
    /// was a visible jump just after the window opened. Only until the
    /// open settles, and never once the reader has scrolled.
    func reassertOpening() {
        guard !opening.settled, !userDidScroll, !opening.reassertPending,
              let proxy = opening.proxy
        else { return }
        opening.reassertPending = true
        let opening = opening
        Task { @MainActor in
            opening.reassertPending = false
            guard !userDidScroll else { return }
            // The binding back on the target first, or it holds the row
            // the drift left at the anchor — undoing the scroll below.
            scroll(to: opening.target, at: opening.placement)
            if case .row(let id, let fraction, _) = restoredPosition {
                proxy.scrollTo("msgbot-\(id)", anchor: UnitPoint(x: 0, y: fraction))
            } else {
                proxy.scrollTo(opening.target, anchor: opening.placement)
            }
        }
    }

    /// Restores a parked viewport: the remembered row's bottom edge back
    /// at its remembered viewport fraction. The init anchor put the row's
    /// neighborhood on screen (realizing it); the exact pass targets the
    /// row's bottom sentinel — a fractional row anchor would drift with
    /// row height. Same settle-poll shape as scrollToBottomSettled: lazy
    /// height estimates land the first pass short, re-asserts converge.
    func settleRestore(id: Int, fraction: CGFloat, proxy: ScrollViewProxy) {
        let fraction = min(max(fraction, 0), 1)
        let place = { proxy.scrollTo("msgbot-\(id)", anchor: UnitPoint(x: 0, y: fraction)) }
        place()
        settle {
            guard let frame = rowFrames.frames[id], viewportHeight > 0 else { return false }
            return abs(frame.maxY - fraction * viewportHeight) < 2
        } reassert: {
            place()
        }
    }

    /// Clearance under the pinned section header: a row whose top is
    /// inside it counts as covered, not visible.
    static let headerClearance: CGFloat = 28

    /// Whether the row sits acceptably in the viewport (top clear of the
    /// pinned header; tall rows only need their top placed). The lenient
    /// gate: an already-visible row is never scrolled.
    func revealPlaced(_ id: Int) -> Bool {
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
    func revealSettled(_ id: Int, movingUp: Bool) -> Bool {
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
    func revealLog(_ stage: String, id: Int) {
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
    func revealSelection(_ id: Int, previous: Int?, proxy: ScrollViewProxy) {
        guard !revealPlaced(id) else {
            revealLog("already placed", id: id)
            return
        }
        revealLog("begin", id: id)
        let movingUp = previous.map { id < $0 } ?? false
        assertReveal(id, movingUp: movingUp, proxy: proxy)
        settle {
            // Anchor reveals abandon when the anchor moves on; tip
            // reveals (⇧ extension) when the tip does.
            guard keys.selectedMessageId == id || keys.extensionTip == id else { return true }
            guard revealSettled(id, movingUp: movingUp) else { return false }
            revealLog("settled", id: id)
            return true
        } reassert: {
            revealLog("re-assert", id: id)
            assertReveal(id, movingUp: movingUp, proxy: proxy)
        }
    }

    /// One reveal assertion. A realized row gets the exact sentinel
    /// placement; an unrealized one is unreachable by proxy.scrollTo (its
    /// id isn't registered — the no-op could never realize it), so the
    /// scroll-position BINDING coarse-jumps there instead. The binding
    /// resolves the layout's DIRECT child identities — the row item ids,
    /// not the overlay sentinels — bottom-anchored, so the row lands
    /// fully visible and realized; the poll then verifies or refines.
    func assertReveal(_ id: Int, movingUp: Bool, proxy: ScrollViewProxy) {
        guard rowFrames.frames[id] == nil else {
            performReveal(id, movingUp: movingUp, proxy: proxy)
            return
        }
        if anchorId != "msg-\(id)" {
            withAnimation(.easeInOut(duration: 0.2)) {
                scroll(to: "msg-\(id)")
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

    func performReveal(_ id: Int, movingUp: Bool, proxy: ScrollViewProxy) {
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
    @MainActor static var didRunAutoScroll = false

    /// Perf harness (`make perf` plus `-perfAutoScroll YES`): drives a fast
    /// upward scroll through history and back down to the bottom, so probe
    /// numbers are repeatable without hand-scrolling. Paging kicks in the
    /// same way it does for a real fling (the top loader realizes as the
    /// viewport reaches it). No-op unless both flags are set.
    func runAutoScrollIfRequested(_ proxy: ScrollViewProxy) async {
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

    /// The message-link flash fades after a beat.
    func scheduleHighlightClear(after delay: Duration = .seconds(2)) {
        guard let target = keys.highlightMessageId else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if keys.highlightMessageId == target {
                withAnimation(.easeOut(duration: 0.6)) {
                    keys.highlightMessageId = nil
                }
            }
        }
    }
}
