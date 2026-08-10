import SwiftUI
import ZulipAPI
import ZulipModel

/// The web app's "Recent conversations" view: every conversation with recent
/// activity, newest first, with participants, unread counts, and filters
/// (include DMs / unread / participated + a topic filter field).
///
/// Built entirely from in-memory state: `ConversationList` supplies recency
/// order, the canonical message map (fed by fetches, events, and the offline
/// cache) supplies participants, timestamps, and participation.
struct RecentConversationsView: View {
    let store: PerAccountStore
    let search: SidebarSearchModel
    @Binding var selection: Destination?

    @AppStorage("recentIncludeDMs") private var includeDMs = false
    @AppStorage("recentUnreadOnly") private var unreadOnly = false
    @AppStorage("recentParticipatedOnly") private var participatedOnly = false

    fileprivate struct Row: Identifiable {
        var key: ConversationKey
        var streamId: Int?
        var channelName: String
        var title: String
        var timestamp: Int?
        var unreadCount: Int

        var id: ConversationKey { key }
    }

    private var rows: [Row] {
        // One pass over the canonical map: recent senders + participation.
        var messagesByKey: [ConversationKey: [Message]] = [:]
        for message in store.messages.values {
            guard let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId)
            else { continue }
            messagesByKey[key, default: []].append(message)
        }
        // Filtered by the shared toolbar search field, like All Channels.
        let filter = search.filterText.trimmingCharacters(in: .whitespaces).lowercased()

        var out: [Row] = []
        for conversation in store.conversations.conversations {
            let key = conversation.key
            var streamId: Int?
            var channelName = ""
            switch key {
            case .topic(let id, _):
                streamId = id
                // Muted channels are hidden, matching the web app's default.
                if store.subscriptions[id]?.isMuted == true { continue }
                channelName = store.channels[id]?.name ?? store.subscriptions[id]?.name ?? "?"
            case .dm:
                if !includeDMs { continue }
            }

            let unread = store.unreads.unreadIds[key]?.count ?? 0
            if unreadOnly && unread == 0 { continue }

            let cached = (messagesByKey[key] ?? []).sorted { $0.id > $1.id }
            if participatedOnly && !cached.contains(where: { $0.senderId == store.selfUserId }) {
                continue
            }

            let title = key.displayTitle(in: store)
            if !filter.isEmpty,
               !channelName.lowercased().contains(filter),
               !title.lowercased().contains(filter) {
                continue
            }

            out.append(
                Row(
                    key: key, streamId: streamId, channelName: channelName, title: title,
                    timestamp: conversation.timestamp ?? cached.first?.timestamp,
                    unreadCount: unread))
            if out.count == 150 { break }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Toggle("Include DMs", isOn: $includeDMs)
                    Toggle("Unread", isOn: $unreadOnly)
                    Toggle("Participated", isOn: $participatedOnly)
                    Spacer()
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Recent Conversations", systemImage: "clock",
                    description: Text("Conversations with recent activity appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List(rows) { row in
                    RecentConversationRow(store: store, row: row) {
                        selection = .conversation(row.key)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                .listStyle(.plain)
            }
        }
        .serverTitled("Recent conversations", store: store)
        // Widen the recency window beyond the sidebar's initial seed.
        .task { await store.seedConversations(count: 200) }
    }
}

private struct RecentConversationRow: View {
    let store: PerAccountStore
    let row: RowData
    let onTap: () -> Void

    // The parent's Row type, re-exposed without generics noise.
    typealias RowData = RecentConversationsView.Row

    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Compact width stacks the row on two lines; the wide table keeps
    /// its aligned columns.
    private var isCompact: Bool {
        #if os(macOS)
        false
        #else
        sizeClass == .compact
        #endif
    }

    private var channelColor: Color {
        guard let streamId = row.streamId else { return .gray }
        return store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    var body: some View {
        Button(action: onTap) {
            if isCompact {
                // Two lines: channel › title (+ badge), then the time —
                // no fixed column widths; nothing aligns across lines.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        channelLabel
                        chevron
                        titleText
                        Spacer(minLength: 8)
                        unreadBadge
                    }
                    timeText
                }
                .contentShape(.rect)
            } else {
                HStack(spacing: 8) {
                    channelLabel
                        .frame(width: 160, alignment: .leading)
                    chevron
                    titleText
                    Spacer(minLength: 8)
                    unreadBadge
                    timeText
                        .frame(width: 118, alignment: .trailing)
                }
                .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
    }

    private var channelLabel: some View {
        HStack(spacing: 5) {
            if row.streamId != nil {
                Image(systemName: "number")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(channelColor)
                Text(row.channelName)
            } else {
                Image(systemName: "person.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Direct messages")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .lineLimit(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private var titleText: some View {
        Text(row.title)
            .font(.body.weight(.medium))
            .lineLimit(1)
    }

    @ViewBuilder
    private var unreadBadge: some View {
        if row.unreadCount > 0 {
            Text("\(row.unreadCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.tint, in: .capsule)
        }
    }

    private var timeText: some View {
        Group {
            if let timestamp = row.timestamp {
                Text(
                    Date(timeIntervalSince1970: TimeInterval(timestamp)),
                    format: .relative(presentation: .named))
            } else {
                Text("")
            }
        }
        // The same small-caps time treatment as the message feed.
        .font(.body.smallCaps())
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
