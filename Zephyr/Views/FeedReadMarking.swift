import Combine
import SwiftUI
import ZulipAPI
import ZulipModel

/// Read marking: rows seen in cross-conversation feeds, arrivals in
/// transcripts — both only while a reader is present.
extension MessageFeedList {
    /// Seen-in-view read marking, batched so a scroll doesn't spam the
    /// flags endpoint.
    func noteSeen(_ identifiers: [String]) {
        guard marksReadOnView else { return }
        for identifier in identifiers {
            guard identifier.hasPrefix("msg-"),
                  let id = Int(identifier.dropFirst(4)),
                  let message = model.messages.first(where: { $0.id == id })
            else { continue }
            noteSeen(message)
        }
    }

    func noteSeen(_ message: Message) {
        guard marksReadOnView, !keys.readMarkingPaused,
              !(message.flags ?? []).contains("read"),
              !pendingReads.ids.contains(message.id)
        else { return }
        let pending = pendingReads
        pending.ids.insert(message.id)
        pending.flushTask?.cancel()
        pending.flushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let ids = Array(pending.ids)
            pending.ids = []
            store.markMessagesRead(ids: ids)
        }
    }

    /// Nobody is looking any more: rows noted in the last beat were never
    /// really seen, and a feed at the bottom is about to follow arrivals
    /// unattended — remember where the reader's reading actually ended.
    func readerWentAway() {
        pendingReads.flushTask?.cancel()
        pendingReads.ids = []
        awayAtBottom = nearBottom ? (model.messages.last?.id, .now) : nil
    }

    /// The reader is back. Arrivals the feed followed while they were
    /// gone are still unread, but scrolled past: reopen at the first of
    /// them, as a fresh open would. A glance away is not a departure —
    /// the feed stays put, and what's on screen marks read as usual.
    func readerReturned() -> Bool {
        defer { awayAtBottom = nil }
        guard let away = awayAtBottom,
              Date.now.timeIntervalSince(away.since) > 20,
              keys.highlightMessageId == nil, keys.selectedMessageId == nil,
              let unreadId = model.firstUnreadId(after: away.newestId)
        else { return false }
        model.reaimUnreadMarker(to: unreadId)
        returnReaimNonce &+= 1
        return true
    }

    /// Transcript arrivals: the new messages past `previousLastId` that
    /// are unread wait in `arrivalReads` until a reader can see them.
    func noteArrivals(after previousLastId: Int?) {
        guard marksArrivalsRead else { return }
        let floor = previousLastId ?? Int.min
        for message in model.messages.reversed() {
            guard message.id > floor else { break }
            if !(message.flags ?? []).contains("read") {
                arrivalReads.ids.insert(message.id)
            }
        }
        flushArrivalReads()
    }

    /// Marks the waiting arrivals read once they can be seen: a reader
    /// present, read marking not paused, and the feed at the bottom.
    func flushArrivalReads() {
        guard marksArrivalsRead, !arrivalReads.ids.isEmpty, arrivalReads.readerPresent,
              !keys.readMarkingPaused, nearBottom
        else { return }
        let ids = arrivalReads.ids.sorted()
        arrivalReads.ids = []
        store.markMessagesRead(ids: ids)
    }
}

/// Conditionally installs the feed-wide visible-target observer. Keeping
/// the disabled branch genuinely modifier-free matters for ordinary topic
/// and DM transcripts, which do not mark individual rows as they pass by.
struct VisibleMessageTargets: ViewModifier {
    let enabled: Bool
    let action: ([String]) -> Void
    let onReaderAway: () -> Void
    /// True when the return is about to move the viewport (what's in
    /// view now is on its way out, and must not be reported as seen).
    let onReaderReturn: () -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(PresentReaderTargets(
                action: action, onReaderAway: onReaderAway,
                onReaderReturn: onReaderReturn))
        } else {
            content
        }
    }
}

/// Reports the visible scroll targets only while someone can be reading
/// them. Visibility is a layout fact, not an attention one: a feed left
/// open at the bottom keeps following arrivals in an inactive window, a
/// backgrounded app, or behind a sleeping or locked screen — and marking
/// those read erases the reader's resume point. The targets in view when
/// the reader returns are reported then.
private struct PresentReaderTargets: ViewModifier {
    let action: ([String]) -> Void
    let onReaderAway: () -> Void
    /// True when the return is about to move the viewport (what's in
    /// view now is on its way out, and must not be reported as seen).
    let onReaderReturn: () -> Bool

    /// A reference box, not observed state: the visible set changes on
    /// every scroll tick and must not re-render anything.
    private final class Visible {
        var identifiers: [String] = []
        var readerPresent = true
    }
    @State private var visible = Visible()

    func body(content: Content) -> some View {
        content
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.2) { identifiers in
                visible.identifiers = identifiers
                if visible.readerPresent { action(identifiers) }
            }
            .modifier(ReaderPresence { isPresent, initial in
                visible.readerPresent = isPresent
                guard !initial else { return }
                if isPresent {
                    if !onReaderReturn() { action(visible.identifiers) }
                } else {
                    onReaderAway()
                }
            })
    }
}

/// Whether someone can be reading the window: it's active, the app is in
/// the foreground, and (macOS) the screen is awake, unlocked, and this
/// session's. Reports the initial state, then each change.
private struct ReaderPresence: ViewModifier {
    /// (present, initial report)
    let onChange: (Bool, Bool) -> Void

    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.scenePhase) private var scenePhase
    /// Why the screen itself can't be seen (macOS) — the window stays key,
    /// and `appearsActive`, through all of these.
    @State private var screenAway: Set<ScreenAwayReason> = []

    private var readerIsPresent: Bool {
        #if os(macOS)
        // scenePhase is per-window and unreliable on the Mac; the window's
        // active appearance is the focus signal there.
        appearsActive && screenAway.isEmpty
        #else
        appearsActive && scenePhase == .active
        #endif
    }

    func body(content: Content) -> some View {
        content
            .onAppear { onChange(readerIsPresent, true) }
            .onChange(of: readerIsPresent) { _, isPresent in
                onChange(isPresent, false)
            }
            #if os(macOS)
            .onReceive(ScreenAwayReason.events) { reason, isAway in
                if isAway {
                    screenAway.insert(reason)
                } else {
                    screenAway.remove(reason)
                }
            }
            #endif
    }
}

/// Transcripts' reader-presence signal for arrival read marking; nothing
/// installed when disabled.
struct ArrivalPresence: ViewModifier {
    let enabled: Bool
    let onChange: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(ReaderPresence { isPresent, _ in onChange(isPresent) })
        } else {
            content
        }
    }
}

#if os(macOS)
/// The ways a Mac's screen stops being watched without any window losing
/// focus. Tracked separately: displays wake before the session unlocks.
private enum ScreenAwayReason: Hashable {
    case displaysAsleep, sessionLocked, sessionSwitchedOut

    static let events: AnyPublisher<(ScreenAwayReason, Bool), Never> = {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let sources: [(NotificationCenter, Notification.Name, ScreenAwayReason, Bool)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, .displaysAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .displaysAsleep, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionSwitchedOut, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionSwitchedOut, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .sessionLocked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .sessionLocked, false),
        ]
        // Hop to main before any closure runs: these closures are
        // main-actor isolated, and the posting thread isn't promised.
        return Publishers.MergeMany(sources.map { center, name, reason, isAway in
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .map { _ in (reason, isAway) }
        })
        .eraseToAnyPublisher()
    }()
}
#else
private enum ScreenAwayReason: Hashable {}
#endif
