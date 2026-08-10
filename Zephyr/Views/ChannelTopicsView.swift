import SwiftUI
import ZulipAPI
import ZulipModel

/// A channel's recent topics (the scoped view reached from channel chips and
/// channel links) — click a topic to open its conversation.
struct ChannelTopicsView: View {
    let store: PerAccountStore
    let streamId: Int
    @Binding var selection: Destination?

    @State private var topics: [ChannelTopic]?
    @State private var errorText: String?

    private var channelName: String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel"
    }

    var body: some View {
        Group {
            if let topics {
                List(topics, id: \.name) { topic in
                    Button {
                        selection = .conversation(.topic(streamId: streamId, topic: topic.name))
                    } label: {
                        TopicRow(store: store, streamId: streamId, topic: topic)
                    }
                    .buttonStyle(.plain)
                }
            } else if let errorText {
                ContentUnavailableView(
                    "Couldn't Load Topics", systemImage: "exclamationmark.triangle",
                    description: Text(errorText))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .serverTitled("#\(channelName)", store: store)
        .task {
            do {
                topics = try await store.connection.getTopics(streamId: streamId)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

private struct TopicRow: View {
    let store: PerAccountStore
    let streamId: Int
    let topic: ChannelTopic

    private var unreadCount: Int {
        store.unreads.unreadIds[.topic(streamId: streamId, topic: topic.name)]?.count ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            if TopicName.isResolved(topic.name) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Text(TopicName.displayName(topic.name).isEmpty
                ? "general chat" : TopicName.displayName(topic.name))
                .font(.body.weight(unreadCount > 0 ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint, in: .capsule)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
