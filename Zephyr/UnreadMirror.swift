import Foundation
import Observation
import WidgetKit
import ZulipModel

/// Mirrors unread state out of the process: the app icon badge and the
/// widget digest in the App Group container. Armed once at launch,
/// observation tracking fires on any store's unread change — message
/// arrival, mark-read, another device catching up — independent of any
/// window, so a macOS app with every window closed still keeps the Dock
/// and widgets fresh.
@MainActor
final class UnreadMirror {
    static let shared = UnreadMirror()

    private var global: GlobalStore?
    private var refreshScheduled = false
    /// Last digest written, to skip no-op timeline reloads (WidgetKit
    /// reloads are budget-limited while the iOS app is backgrounded).
    private var lastWritten: UnreadSummary?

    /// Called once at launch. Tracking covers the store map itself, so
    /// accounts added, removed, or rebuilt later are folded in.
    func activate(global: GlobalStore) {
        self.global = global
        arm()
        refresh()
    }

    /// Immediate re-sync. Badge policy changes call this directly:
    /// UserDefaults isn't observation-tracked.
    func refresh() {
        guard let global else { return }
        Platform.setAppBadge(badgeCount(global))
        writeWidgetSummary(global)
    }

    private func arm() {
        guard let global else { return }
        withObservationTracking {
            for store in global.stores.values {
                // Reads unreadIds, subscriptions, and topicVisibility, so
                // muting a channel or topic re-fires tracking too.
                _ = store.visibleUnreadCount
                _ = store.unreads.mentionIds
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
    }

    /// Events arrive in bursts (catch-up poll, mark-all-read): coalesce
    /// into one write. Tracking stays disarmed during the wait, so the
    /// burst's mutations fold into the refresh that re-arms it.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            refreshScheduled = false
            refresh()
            arm()
        }
    }

    /// Badge aggregates across every connected server, not just the front one.
    private func badgeCount(_ global: GlobalStore) -> Int {
        let policy = BadgePolicy(
            rawValue: UserDefaults.standard.string(forKey: "badgePolicy") ?? ""
        ) ?? .dmsAndMentions
        return global.stores.values.reduce(0) { total, store in
            switch policy {
            case .dmsAndMentions:
                total + store.unreads.dmAndMentionCount
            case .allUnreads:
                total + store.visibleUnreadCount
            case .none:
                total
            }
        }
    }

    /// Writes the widget's unread digest into the App Group container and
    /// pokes the timeline; a no-op when the App Group isn't provisioned.
    private func writeWidgetSummary(_ global: GlobalStore) {
        guard let url = UnreadSummary.containerFileURL else { return }
        var total = 0
        var mentions = 0
        var lines: [UnreadSummary.Line] = []
        // Count what the app surfaces: unreads in muted or unsubscribed
        // channels stay out, or the widget shows counts the app doesn't.
        for store in global.stores.values {
            total += store.visibleUnreadCount
            mentions += store.unreads.mentionIds.count
            for (key, ids) in store.unreads.unreadIds
            where !ids.isEmpty && store.isUnreadVisible(key) {
                lines.append(UnreadSummary.Line(
                    title: key.displayTitle(in: store), count: ids.count))
            }
        }
        let summary = UnreadSummary(
            totalUnread: total, mentions: mentions,
            lines: Array(lines.sorted { $0.count > $1.count }.prefix(6)),
            updated: .now)
        if var previous = lastWritten {
            previous.updated = summary.updated
            if previous == summary { return }
        }
        // A failed write must not update lastWritten: the next refresh
        // with the same state has to retry, not dedup against a file
        // that still holds the old counts.
        guard let data = try? JSONEncoder().encode(summary),
              (try? data.write(to: url, options: .atomic)) != nil else { return }
        lastWritten = summary
        WidgetCenter.shared.reloadTimelines(ofKind: "ZephyrUnreads")
    }
}
