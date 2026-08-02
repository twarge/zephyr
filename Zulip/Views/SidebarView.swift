import SwiftUI
import ZulipContent
import ZulipModel

/// The unified conversation list: DM threads and channel topics interleaved
/// by recency, with Messages-style scope filters.
struct SidebarView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case unread = "Unread"
        case dms = "DMs"
        case mentions = "Mentions"
        var id: String { rawValue }
    }

    let store: PerAccountStore
    @Binding var selection: ConversationKey?
    @State private var scope = Scope.all

    private var rows: [ConversationList.Conversation] {
        let all = store.conversations.conversations
        switch scope {
        case .all:
            return all
        case .unread:
            return all.filter { store.unreads.unreadIds[$0.key]?.isEmpty == false }
        case .dms:
            return all.filter {
                if case .dm = $0.key { return true }
                return false
            }
        case .mentions:
            return all.filter { conversation in
                guard let ids = store.unreads.unreadIds[conversation.key] else { return false }
                return !ids.isDisjoint(with: store.unreads.mentionIds)
            }
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(rows) { conversation in
                ConversationRow(store: store, conversation: conversation)
                    .tag(conversation.key)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    scope == .all ? "No Conversations Yet" : "Nothing in \(scope.rawValue)",
                    systemImage: "tray")
            }
        }
    }
}

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
        switch conversation.key {
        case .dm(let joined):
            let ids = joined.split(separator: ",").compactMap { Int($0) }
            if ids.isEmpty { return "Yourself" }
            let names = ids.map { store.users[$0]?.fullName ?? "User \($0)" }
            return names.joined(separator: ", ")
        case .topic(let streamId, let topic):
            let channel = store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name
            return topic.isEmpty ? (channel.map { "#\($0)" } ?? "topic") : topic
        }
    }

    private var subtitleChannel: String? {
        guard case .topic(let streamId, _) = conversation.key else { return nil }
        return (store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name)
            .map { "#\($0)" }
    }

    private var snippet: String {
        guard let html = conversation.snippetHTML else { return "" }
        let text = ContentParser.parse(html: html).plainText
        if let sender = conversation.senderName, case .topic = conversation.key {
            return "\(sender.split(separator: " ").first.map(String.init) ?? sender): \(text)"
        }
        return text
    }

    var body: some View {
        HStack(spacing: 10) {
            ConversationAvatar(store: store, key: conversation.key)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitleChannel {
                        Text(subtitleChannel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

/// Channel-colored `#` badge for topics; initials circle for DMs.
struct ConversationAvatar: View {
    let store: PerAccountStore
    let key: ConversationKey

    var body: some View {
        switch key {
        case .topic(let streamId, _):
            let color = store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
                ?? .stableColor(for: streamId)
            Image(systemName: store.channels[streamId]?.inviteOnly == true ? "lock.fill" : "number")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient, in: .circle)
        case .dm(let joined):
            let ids = joined.split(separator: ",").compactMap { Int($0) }
            let name = ids.first.flatMap { store.users[$0]?.fullName } ?? "?"
            Text(Self.initials(name))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.stableColor(for: ids.first ?? 0).gradient, in: .circle)
        }
    }

    private static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
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
