import SwiftUI
import ZulipAPI
import ZulipModel

/// A channel's recent topics (the scoped view reached from channel chips and
/// channel links) — click a topic to open its conversation.
struct ChannelTopicsView: View {
    let store: PerAccountStore
    let streamId: Int
    @Binding var selection: Destination?

    /// Settles the loading state: past it, no list means unreachable.
    @State private var loadFinished = false

    /// The account's cached list (last session's, or the message
    /// database's offline), replaced by the server's when it lands.
    private var topics: [ChannelTopic]? {
        store.channelTopics.lists[streamId]
    }

    private var channelName: String {
        store.channelName(streamId)
    }

    var body: some View {
        Group {
            // An empty list is only an answer once the server gave it;
            // offline it just means the database knows no topics here.
            if let topics, !topics.isEmpty || store.channelTopics.isFresh(streamId) {
                List(topics, id: \.name) { topic in
                    Button {
                        selection = .conversation(.topic(streamId: streamId, topic: topic.name))
                    } label: {
                        TopicRow(store: store, streamId: streamId, topic: topic)
                    }
                    .buttonStyle(.plain)
                }
            } else if loadFinished {
                ContentUnavailableView(
                    "Couldn't Load Topics", systemImage: "exclamationmark.triangle",
                    description: Text("This channel's topics appear once the server can be reached."))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .serverTitled("#\(channelName)", store: store)
        .subtitled { unreadSubtitle(store.unreads.unreadCount(inChannel: streamId)) }
        .task {
            // The cached list shows meanwhile; topics move fast.
            await store.channelTopics.load(streamId, refetch: true)
            loadFinished = true
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
