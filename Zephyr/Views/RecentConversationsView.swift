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
    @Binding var selection: Destination?

    @AppStorage("recentIncludeDMs") private var includeDMs = false
    @AppStorage("recentUnreadOnly") private var unreadOnly = false
    @AppStorage("recentParticipatedOnly") private var participatedOnly = false
    @State private var filterText = ""

    fileprivate struct Row: Identifiable {
        var key: ConversationKey
        var streamId: Int?
        var channelName: String
        var title: String
        var timestamp: Int?
        var senderIds: [Int]
        var extraSenders: Bool
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
        let filter = filterText.trimmingCharacters(in: .whitespaces).lowercased()

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

            var senders: [Int] = []
            var extra = false
            for message in cached {
                if !senders.contains(message.senderId) {
                    if senders.count == 3 {
                        extra = true
                        break
                    }
                    senders.append(message.senderId)
                }
            }

            out.append(
                Row(
                    key: key, streamId: streamId, channelName: channelName, title: title,
                    timestamp: conversation.timestamp ?? cached.first?.timestamp,
                    senderIds: senders, extraSenders: extra, unreadCount: unread))
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
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter topics", text: $filterText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
        .navigationTitle("Recent conversations")
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

    private var channelColor: Color {
        guard let streamId = row.streamId else { return .gray }
        return store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
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
                .font(.callout)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(row.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.unreadCount > 0 {
                    Text("\(row.unreadCount)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint, in: .capsule)
                }
                HStack(spacing: -6) {
                    ForEach(row.senderIds, id: \.self) { userId in
                        AvatarView(store: store, userId: userId, size: 22)
                    }
                }
                if row.extraSenders {
                    Text("+")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Group {
                    if let timestamp = row.timestamp {
                        Text(
                            Date(timeIntervalSince1970: TimeInterval(timestamp)),
                            format: .relative(presentation: .named))
                    } else {
                        Text("")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
