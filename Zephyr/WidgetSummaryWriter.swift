import Foundation
import WidgetKit
import ZulipModel

/// Writes the widget's unread digest into the App Group container and
/// pokes the timeline. Called whenever the badge count changes; a no-op
/// when the App Group isn't provisioned.
@MainActor
enum WidgetSummaryWriter {
    static func update(global: GlobalStore) {
        guard let url = UnreadSummary.containerFileURL else { return }
        var total = 0
        var mentions = 0
        var lines: [UnreadSummary.Line] = []
        for store in global.stores.values {
            total += store.unreads.totalCount
            mentions += store.unreads.mentionIds.count
            for (key, ids) in store.unreads.unreadIds where !ids.isEmpty {
                lines.append(UnreadSummary.Line(
                    title: key.displayTitle(in: store), count: ids.count))
            }
        }
        let summary = UnreadSummary(
            totalUnread: total, mentions: mentions,
            lines: Array(lines.sorted { $0.count > $1.count }.prefix(6)),
            updated: .now)
        guard let data = try? JSONEncoder().encode(summary) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: "ZephyrUnreads")
    }
}
