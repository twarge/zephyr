import SwiftUI
import ZulipModel

/// ⌘⇧O "Open Quickly…": type a channel, person, or view name, or pick
/// from the special views, recent channels, and recent DMs. Return opens
/// it. (Also the destination picker for sharing and Forward Message.)
struct OpenQuicklyView: View {
    let store: PerAccountStore
    var open: (Destination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let destination: Destination
        let name: String
        let icon: String
        var unsubscribed = false
        var id: Destination { destination }
    }

    /// The sidebar's Views section, same names and icons.
    private static let specialViews: [Entry] = [
        Entry(destination: .recentConversations, name: "Recent", icon: "clock"),
        Entry(destination: .combinedFeed, name: "Combined", icon: "line.3.horizontal"),
        Entry(destination: .mentions, name: "Mentions", icon: "at"),
        Entry(destination: .starred, name: "Starred", icon: "star"),
        Entry(destination: .drafts, name: "Drafts", icon: "pencil.line"),
        Entry(destination: .outbox, name: "Outbox", icon: "tray.and.arrow.up"),
        Entry(destination: .allChannels, name: "All Channels", icon: "square.grid.2x2"),
    ]

    private func channelEntry(_ id: Int, _ name: String, subscribed: Bool) -> Entry {
        let channel = store.channels[id]
        let icon = channel?.inviteOnly == true
            ? "lock.fill" : channel?.isWebPublic == true ? "globe" : "number"
        return Entry(
            destination: .channel(streamId: id), name: name, icon: icon,
            unsubscribed: !subscribed)
    }

    private func dmEntry(_ key: ConversationKey) -> Entry {
        let participants: Int
        if case .dm(let joined) = key {
            participants = joined.split(separator: ",").count
        } else {
            participants = 1
        }
        return Entry(
            destination: .conversation(key), name: key.displayTitle(in: store),
            icon: participants > 1 ? "person.2" : "person")
    }

    private var results: [Entry] {
        let subscribedIds = Set(store.subscriptions.keys)
        func name(_ id: Int) -> String? {
            store.channels[id]?.name ?? store.subscriptions[id]?.name
        }
        let typed = query.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            // The special views, then recently viewed channels, recent
            // DMs, then channels by message activity.
            var out = Self.specialViews
            var seen = Set<Int>()
            for id in AppStateStore.recentChannels(for: store.accountId) {
                guard let name = name(id), seen.insert(id).inserted else { continue }
                out.append(channelEntry(id, name, subscribed: subscribedIds.contains(id)))
            }
            var dms = 0
            for conversation in store.conversations.conversations {
                if case .dm = conversation.key, dms < 4 {
                    out.append(dmEntry(conversation.key))
                    dms += 1
                }
            }
            for conversation in store.conversations.conversations {
                guard case .topic(let id, _) = conversation.key,
                      let name = name(id), seen.insert(id).inserted else { continue }
                out.append(channelEntry(id, name, subscribed: subscribedIds.contains(id)))
            }
            return Array(out.prefix(12))
        }
        var candidates = Self.specialViews
        var seen = Set<Int>()
        for (id, channel) in store.channels where seen.insert(id).inserted {
            candidates.append(channelEntry(id, channel.name, subscribed: subscribedIds.contains(id)))
        }
        for (id, subscription) in store.subscriptions where seen.insert(id).inserted {
            candidates.append(channelEntry(id, subscription.name, subscribed: true))
        }
        for user in store.users.values where user.isActive != false {
            candidates.append(
                Entry(
                    destination: .conversation(
                        Unreads.dmKey(
                            participantIds: [user.userId], selfUserId: store.selfUserId)),
                    name: user.fullName, icon: user.isBot ? "cpu" : "person"))
        }
        let lowered = typed.lowercased()
        func rank(_ candidate: Entry) -> (Int, Int, String) {
            (candidate.name.lowercased().hasPrefix(lowered) ? 0 : 1,
             candidate.unsubscribed ? 1 : 0,
             candidate.name.lowercased())
        }
        return Array(
            candidates
                .filter { $0.name.localizedCaseInsensitiveContains(typed) }
                .sorted { rank($0) < rank($1) }
                .prefix(10))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open channel, person, or view…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
            }
            .padding(12)
            Divider()
            if results.isEmpty {
                Text("No matching channels, people, or views")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        row(result, isSelected: index == selectedIndex)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 440)
        .onAppear { focused = true }
        .onChange(of: query) { selectedIndex = 0 }
    }

    private func row(_ result: Entry, isSelected: Bool) -> some View {
        Button {
            openEntry(result)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: result.icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(result.name)
                    .lineLimit(1)
                Spacer()
                if result.unsubscribed {
                    Text("Not subscribed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
        return .handled
    }

    private func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        openEntry(results[selectedIndex])
    }

    private func openEntry(_ result: Entry) {
        open(result.destination)
        dismiss()
    }
}
