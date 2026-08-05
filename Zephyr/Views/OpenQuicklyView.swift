import SwiftUI
import ZulipModel

/// ⌘⇧O "Open Quickly…": type a channel name, or pick from recently viewed
/// and recently active channels. Return opens the channel's feed.
struct OpenQuicklyView: View {
    let store: PerAccountStore
    var open: (Destination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        let streamId: Int
        let name: String
        let subscribed: Bool
        var id: Int { streamId }
    }

    private var results: [Entry] {
        let subscribedIds = Set(store.subscriptions.keys)
        func entry(_ id: Int, _ name: String) -> Entry {
            Entry(streamId: id, name: name, subscribed: subscribedIds.contains(id))
        }
        func name(_ id: Int) -> String? {
            store.channels[id]?.name ?? store.subscriptions[id]?.name
        }
        let typed = query.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            // Recently viewed first, then channels by message activity.
            var seen = Set<Int>()
            var out: [Entry] = []
            for id in AppStateStore.recentChannels(for: store.accountId) {
                guard let name = name(id), seen.insert(id).inserted else { continue }
                out.append(entry(id, name))
            }
            for conversation in store.conversations.conversations {
                guard case .topic(let id, _) = conversation.key,
                      let name = name(id), seen.insert(id).inserted else { continue }
                out.append(entry(id, name))
            }
            return Array(out.prefix(10))
        }
        var candidates: [Entry] = []
        var seen = Set<Int>()
        for (id, channel) in store.channels where seen.insert(id).inserted {
            candidates.append(entry(id, channel.name))
        }
        for (id, subscription) in store.subscriptions where seen.insert(id).inserted {
            candidates.append(entry(id, subscription.name))
        }
        let lowered = typed.lowercased()
        func rank(_ candidate: Entry) -> (Int, Int, String) {
            (candidate.name.lowercased().hasPrefix(lowered) ? 0 : 1,
             candidate.subscribed ? 0 : 1,
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
                TextField("Open channel…", text: $query)
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
                Text(query.isEmpty ? "No channels yet" : "No matching channels")
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
                Image(systemName: glyph(result.streamId))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(result.name)
                    .lineLimit(1)
                Spacer()
                if !result.subscribed {
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

    private func glyph(_ streamId: Int) -> String {
        let channel = store.channels[streamId]
        if channel?.inviteOnly == true { return "lock.fill" }
        if channel?.isWebPublic == true { return "globe" }
        return "number"
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
        open(.channel(streamId: result.streamId))
        dismiss()
    }
}
