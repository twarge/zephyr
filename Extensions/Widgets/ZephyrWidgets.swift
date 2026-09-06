import SwiftUI
import WidgetKit

// The unreads widget: renders the summary the app writes into the App
// Group container (Shared/UnreadSummary.swift). The app reloads the
// timeline whenever unread state changes (UnreadMirror); the schedule
// below is only a fallback.

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
            servers: [
                .init(name: "DC Quantum", unread: 9, mentions: 2),
                .init(name: "Zulip Community", unread: 3, mentions: 0),
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

    /// The hero count: total unreads with the @ mention count inline at
    /// the same size ("12 @4"), scaling down before it would clip.
    private func countLine(_ summary: UnreadSummary, size: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 5) {
            rollingCount(summary.totalUnread)
            if summary.mentions > 0 {
                rollingCount(summary.mentions, prefix: "@")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    /// A count whose digits roll when a new entry changes it — upward as
    /// it grows, downward as it shrinks. WidgetKit animates between
    /// entries only through modifiers like these (no withAnimation), and
    /// its default for text is a blur; the explicit animation makes the
    /// roll the transition it uses.
    private func rollingCount(_ count: Int, prefix: String = "") -> some View {
        Text("\(prefix)\(count)")
            .contentTransition(.numericText(value: Double(count)))
            .animation(.spring(duration: 0.4), value: count)
    }

    private func small(_ summary: UnreadSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
            countLine(summary, size: 34)
            Text(summary.totalUnread == 1 ? "unread" : "unreads")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Top conversations, titles only — no room for counts here.
            if !summary.lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(summary.lines.prefix(3)) { line in
                        Text(line.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 3)
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
                countLine(summary, size: 30)
                Text(summary.totalUnread == 1 ? "unread" : "unreads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // One row per server when several are connected, each with
            // its own unread and @ mention counts; top conversations
            // fill whatever rows remain.
            let servers = (summary.servers ?? []).count > 1
                ? Array((summary.servers ?? []).prefix(3)) : []
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(servers.enumerated()), id: \.offset) { _, server in
                    HStack {
                        Text(server.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if server.mentions > 0 {
                            Label {
                                rollingCount(server.mentions)
                            } icon: {
                                Image(systemName: "at")
                            }
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.orange)
                        }
                        rollingCount(server.unread)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !servers.isEmpty && !summary.lines.isEmpty {
                    Divider()
                }
                ForEach(summary.lines.prefix(4 - servers.count)) { line in
                    HStack {
                        Text(line.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        rollingCount(line.count)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if summary.lines.isEmpty && servers.isEmpty {
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

#Preview("Three servers", as: .systemMedium) {
    UnreadsWidget()
} timeline: {
    UnreadsEntry(date: .now, summary: UnreadSummary(
        totalUnread: 14, mentions: 3,
        lines: [
            .init(title: "#general › releases", count: 7),
            .init(title: "Nikolai", count: 3),
        ],
        servers: [
            .init(name: "DC Quantum", unread: 9, mentions: 2),
            .init(name: "Zulip Community", unread: 4, mentions: 1),
            .init(name: "Recurse Center", unread: 1, mentions: 0),
        ],
        updated: .now))
}

#Preview("One server", as: .systemMedium) {
    UnreadsWidget()
} timeline: {
    UnreadsEntry(date: .now, summary: UnreadSummary(
        totalUnread: 12, mentions: 2,
        lines: [
            .init(title: "#general › releases", count: 7),
            .init(title: "Nikolai", count: 3),
            .init(title: "#design › icons", count: 2),
        ],
        servers: [.init(name: "DC Quantum", unread: 12, mentions: 2)],
        updated: .now))
}

// Two entries, so the canvas plays the count roll between them.
#Preview("Update", as: .systemMedium) {
    UnreadsWidget()
} timeline: {
    UnreadsEntry(date: .now, summary: UnreadSummary(
        totalUnread: 12, mentions: 2,
        lines: [
            .init(title: "#general › releases", count: 7),
            .init(title: "Nikolai", count: 3),
        ],
        servers: [.init(name: "DC Quantum", unread: 12, mentions: 2)],
        updated: .now))
    UnreadsEntry(date: .now.addingTimeInterval(2), summary: UnreadSummary(
        totalUnread: 15, mentions: 4,
        lines: [
            .init(title: "#general › releases", count: 9),
            .init(title: "Nikolai", count: 4),
        ],
        servers: [.init(name: "DC Quantum", unread: 15, mentions: 4)],
        updated: .now))
}

#Preview("Caught up", as: .systemMedium) {
    UnreadsWidget()
} timeline: {
    UnreadsEntry(date: .now, summary: UnreadSummary(
        totalUnread: 0, mentions: 0, lines: [], servers: [], updated: .now))
}

#Preview("Small", as: .systemSmall) {
    UnreadsWidget()
} timeline: {
    UnreadsEntry(date: .now, summary: UnreadSummary(
        totalUnread: 12, mentions: 4,
        lines: [
            .init(title: "#general › releases", count: 7),
            .init(title: "Nikolai", count: 3),
            .init(title: "#design › icons", count: 2),
        ],
        servers: [
            .init(name: "DC Quantum", unread: 9, mentions: 4),
            .init(name: "Zulip Community", unread: 3, mentions: 0),
        ],
        updated: .now))
}
