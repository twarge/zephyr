import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// The sidebar, modeled on the Zulip web app's: a Views section (smart
/// lists), compact Direct Messages, then channels grouped by folder with
/// unread count badges — with a filter field on top.
struct SidebarView: View {
    let store: PerAccountStore
    @Binding var selection: Destination?

    @State private var filterText = ""
    @State private var collapsedSections: Set<String> = []

    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func matchesFilter(_ name: String) -> Bool {
        !isFiltering || name.localizedCaseInsensitiveContains(filterText)
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedSections.contains(id) },
            set: { expanded in
                if expanded {
                    collapsedSections.remove(id)
                } else {
                    collapsedSections.insert(id)
                }
            })
    }

    private var dmRows: [ConversationList.Conversation] {
        store.conversations.conversations.filter { conversation in
            guard case .dm = conversation.key else { return false }
            return matchesFilter(conversation.key.displayTitle(in: store))
        }
    }

    private var sortedSubscriptions: [Subscription] {
        store.subscriptions.values
            .filter { matchesFilter($0.name) }
            .sorted { a, b in
                let aPinned = a.pinToTop ?? false
                let bPinned = b.pinToTop ?? false
                if aPinned != bPinned { return aPinned }
                if a.muted != b.muted { return b.muted }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    private func channels(inFolder folderId: Int?) -> [Subscription] {
        sortedSubscriptions.filter { store.channels[$0.streamId]?.folderId == folderId }
    }

    var body: some View {
        List(selection: $selection) {
            if !isFiltering {
                Section("Views", isExpanded: expansion("views")) {
                    viewRow("Combined feed", icon: "line.3.horizontal", tag: .combinedFeed, badge: 0)
                    viewRow(
                        "Mentions", icon: "at", tag: .mentions,
                        badge: store.unreads.mentionIds.count)
                    viewRow("Starred messages", icon: "star", tag: .starred, badge: 0)
                }
            }
            Section("Direct messages", isExpanded: expansion("dms")) {
                if dmRows.isEmpty && !isFiltering {
                    Text("No recent direct messages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(dmRows) { conversation in
                    DirectMessageRow(store: store, conversation: conversation)
                        .tag(Destination.conversation(conversation.key))
                }
            }
            if store.channelFolders.isEmpty {
                channelSection(title: "Channels", id: "channels", channels: sortedSubscriptions)
            } else {
                ForEach(store.channelFolders) { folder in
                    channelSection(
                        title: folder.name, id: "folder-\(folder.id)",
                        channels: channels(inFolder: folder.id))
                }
                channelSection(
                    title: "Other channels", id: "folder-none",
                    channels: channels(inFolder: nil))
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filterText, placement: .sidebar, prompt: "Filter")
    }

    @ViewBuilder
    private func channelSection(title: String, id: String, channels: [Subscription]) -> some View {
        if !channels.isEmpty {
            Section(title, isExpanded: expansion(id)) {
                ForEach(channels) { subscription in
                    ChannelRow(store: store, subscription: subscription)
                        .tag(Destination.channel(streamId: subscription.streamId))
                }
            }
        }
    }

    private func viewRow(
        _ title: String, icon: String, tag: Destination, badge: Int
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 4)
            if badge > 0 {
                CountBadge(count: badge)
            }
        }
        .tag(tag)
    }
}

/// Compact one-line DM row: presence dot (placeholder until M2), name(s),
/// bot marker, unread badge.
private struct DirectMessageRow: View {
    let store: PerAccountStore
    let conversation: ConversationList.Conversation

    private var participantIds: [Int] {
        conversation.key.dmParticipantIds ?? []
    }

    private var isBot: Bool {
        participantIds.count == 1 && store.users[participantIds[0]]?.isBot == true
    }

    private var unreadCount: Int {
        store.unreads.unreadIds[conversation.key]?.count ?? 0
    }

    private var hasMention: Bool {
        guard let ids = store.unreads.unreadIds[conversation.key] else { return false }
        return !ids.isDisjoint(with: store.unreads.mentionIds)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(.tertiary, lineWidth: 1.5)
                .frame(width: 8, height: 8)
            Text(conversation.key.displayTitle(in: store))
                .font(.body.weight(unreadCount > 0 ? .semibold : .regular))
                .lineLimit(1)
            if isBot {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hasMention {
                Text("@")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.tint, in: .circle)
            } else if unreadCount > 0 {
                CountBadge(count: unreadCount)
            }
        }
        .padding(.vertical, 1)
    }
}

/// Web-style channel row: colored type glyph (globe/lock/#), name, badge.
private struct ChannelRow: View {
    let store: PerAccountStore
    let subscription: Subscription

    private var unreadCount: Int {
        store.unreads.unreadCount(inChannel: subscription.streamId)
    }

    private var glyph: String {
        let stream = store.channels[subscription.streamId]
        if stream?.inviteOnly == true { return "lock.fill" }
        if stream?.isWebPublic == true { return "globe" }
        return "number"
    }

    private var color: Color {
        subscription.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: subscription.streamId)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 18)
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
                CountBadge(count: unreadCount)
            }
        }
        .opacity(subscription.muted ? 0.6 : 1)
        .padding(.vertical, 1)
    }
}

/// The web app's gray rounded count badge.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Channel-colored `#` (or lock) badge, used by feed/topic-list contexts.
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
