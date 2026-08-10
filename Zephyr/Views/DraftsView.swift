import SwiftUI
import ZulipModel

/// The full-page Drafts view (`#drafts` links and Open Quickly land here).
/// Selecting a draft resumes composing in its conversation — the compose
/// bar restores the text itself.
struct DraftsView: View {
    let store: PerAccountStore
    @Binding var selection: Destination?

    private var rows: [(destination: SendDestination, key: ConversationKey, text: String)] {
        DraftStore.shared.entries(account: store.accountId)
            .compactMap { destination, entry -> (SendDestination, ConversationKey, String)? in
                let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let key: ConversationKey
                switch destination {
                case .topic(let streamId, let topic):
                    guard store.channels[streamId] != nil
                        || store.subscriptions[streamId] != nil else { return nil }
                    key = .topic(streamId: streamId, topic: topic)
                case .dm(let userIds):
                    guard userIds.contains(where: { store.users[$0] != nil }) else { return nil }
                    key = Unreads.dmKey(participantIds: userIds, selfUserId: store.selfUserId)
                }
                return (destination, key, trimmed)
            }
            .sorted {
                title(for: $0.1).localizedCaseInsensitiveCompare(title(for: $1.1))
                    == .orderedAscending
            }
    }

    private func title(for key: ConversationKey) -> String {
        if case .topic(let streamId, let topic) = key {
            let channel = store.channels[streamId]?.name
                ?? store.subscriptions[streamId]?.name ?? "?"
            let display = TopicName.displayName(topic)
            return "#\(channel) › \(display.isEmpty ? "general chat" : display)"
        }
        return key.displayTitle(in: store)
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Drafts", systemImage: "pencil.line",
                    description: Text(
                        "Start typing in any conversation and navigate away — the draft waits here."))
            } else {
                List {
                    ForEach(rows, id: \.destination) { row in
                        Button {
                            selection = .conversation(row.key)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(title(for: row.key), systemImage: "pencil.line")
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(row.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Discard Draft", role: .destructive) {
                                DraftStore.shared.setDraft(
                                    "", for: row.destination, account: store.accountId)
                            }
                        }
                    }
                }
            }
        }
        .serverTitled("Drafts", store: store)
    }
}
