import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// The sidebar: Direct Messages (recent threads, Messages-style rows) above
/// the subscribed Channels (pinned first, unread badges).
struct SidebarView: View {
    let store: PerAccountStore
    @Binding var selection: Destination?

    private var dmRows: [ConversationList.Conversation] {
        store.conversations.conversations.filter {
            if case .dm = $0.key { return true }
            return false
        }
    }

    private var channels: [Subscription] {
        store.subscriptions.values.sorted { a, b in
            let aPinned = a.pinToTop ?? false
            let bPinned = b.pinToTop ?? false
            if aPinned != bPinned { return aPinned }
            if a.muted != b.muted { return b.muted }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section("Direct Messages") {
                if dmRows.isEmpty {
                    Text("No recent direct messages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(dmRows) { conversation in
                    ConversationRow(store: store, conversation: conversation)
                        .tag(Destination.conversation(conversation.key))
                }
            }
            Section("Channels") {
                ForEach(channels) { subscription in
                    ChannelRow(store: store, subscription: subscription)
                        .tag(Destination.channel(streamId: subscription.streamId))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct ChannelRow: View {
    let store: PerAccountStore
    let subscription: Subscription

    private var unreadCount: Int {
        store.unreads.unreadCount(inChannel: subscription.streamId)
    }

    var body: some View {
        HStack(spacing: 8) {
            ChannelBadge(store: store, streamId: subscription.streamId, size: 24)
            Text(subscription.name)
                .font(.body.weight(unreadCount > 0 && !subscription.muted ? .semibold : .regular))
                .lineLimit(1)
            if subscription.muted {
                Image(systemName: "bell.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if unreadCount > 0 && !subscription.muted {
                Text("\(unreadCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.tint, in: .capsule)
            }
        }
        .opacity(subscription.muted ? 0.6 : 1)
        .padding(.vertical, 1)
    }
}

/// Channel-colored `#` (or lock) badge.
struct ChannelBadge: View {
    let store: PerAccountStore
    let streamId: Int
    var size: CGFloat = 34

    var body: some View {
        let color = store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
        Image(systemName: store.channels[streamId]?.inviteOnly == true ? "lock.fill" : "number")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: .circle)
    }
}

/// A Messages-style row for a DM conversation.
struct ConversationRow: View {
    let store: PerAccountStore
    let conversation: ConversationList.Conversation

    private var unreadCount: Int {
        store.unreads.unreadIds[conversation.key]?.count ?? 0
    }

    private var hasMention: Bool {
        guard let ids = store.unreads.unreadIds[conversation.key] else { return false }
        return !ids.isDisjoint(with: store.unreads.mentionIds)
    }

    private var title: String {
        conversation.key.displayTitle(in: store)
    }

    private var snippet: String {
        guard let html = conversation.snippetHTML else { return "" }
        return ContentParser.parse(html: html).plainText
    }

    var body: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let timestamp = conversation.timestamp {
                        Text(Self.relativeTime(timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                    Spacer(minLength: 4)
                    if hasMention {
                        Text("@")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(.tint, in: .circle)
                    } else if unreadCount > 0 {
                        Circle()
                            .fill(.tint)
                            .frame(width: 9, height: 9)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var avatar: some View {
        switch conversation.key {
        case .dm(let joined):
            let ids = joined.split(separator: ",").compactMap { Int($0) }
            AvatarView(store: store, userId: ids.first ?? store.selfUserId, size: 34)
        case .topic(let streamId, _):
            ChannelBadge(store: store, streamId: streamId, size: 34)
        }
    }

    private static func relativeTime(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension Color {
    /// Parses Zulip's subscription color strings ("#e79ab5").
    init?(zulipHex: String) {
        var hex = zulipHex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255)
    }

    /// A stable per-id hue for avatars/badges without server colors.
    static func stableColor(for id: Int) -> Color {
        Color(hue: Double((id &* 2654435761) % 360) / 360, saturation: 0.55, brightness: 0.75)
    }
}
