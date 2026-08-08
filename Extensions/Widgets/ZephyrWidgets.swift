import SwiftUI
import WidgetKit

// The unreads widget: renders the summary the app writes into the App
// Group container (Shared/UnreadSummary.swift). The app reloads the
// timeline whenever the badge count changes; the schedule below is only
// a fallback.

struct UnreadsEntry: TimelineEntry {
    let date: Date
    let summary: UnreadSummary?
}

struct UnreadsProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadsEntry {
        UnreadsEntry(date: .now, summary: UnreadSummary(
            totalUnread: 12, mentions: 2,
            lines: [
                .init(title: "#general › releases", count: 7),
                .init(title: "Nikolai", count: 3),
                .init(title: "#design › icons", count: 2),
            ],
            updated: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadsEntry) -> Void) {
        completion(UnreadsEntry(date: .now, summary: UnreadSummary.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadsEntry>) -> Void) {
        let entry = UnreadsEntry(date: .now, summary: UnreadSummary.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800))))
    }
}

struct UnreadsWidgetView: View {
    var entry: UnreadsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let summary = entry.summary {
            switch family {
            case .systemSmall:
                small(summary)
            default:
                medium(summary)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Open Zephyr to populate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func small(_ summary: UnreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            Text("\(summary.totalUnread)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text(summary.totalUnread == 1 ? "unread" : "unreads")
                .font(.caption)
                .foregroundStyle(.secondary)
            if summary.mentions > 0 {
                Label("\(summary.mentions)", systemImage: "at")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func medium(_ summary: UnreadSummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text("\(summary.totalUnread)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(summary.totalUnread == 1 ? "unread" : "unreads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if summary.mentions > 0 {
                    Label("\(summary.mentions)", systemImage: "at")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(summary.lines.prefix(4)) { line in
                    HStack {
                        Text(line.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(line.count)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if summary.lines.isEmpty {
                    Text("All caught up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct UnreadsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ZephyrUnreads", provider: UnreadsProvider()) { entry in
            UnreadsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unreads")
        .description("Unread messages across your Zulip servers.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ZephyrWidgetBundle: WidgetBundle {
    var body: some Widget {
        UnreadsWidget()
    }
}
