import SwiftUI
import ZulipModel

/// A focused transcript for one topic or DM thread. Opens anchored at the
/// newest messages; scrolling up pages in history.
struct TranscriptView: View {
    let store: PerAccountStore
    let conversation: ConversationKey
    @Binding var selection: Destination?

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()

    private var isTopic: Bool {
        if case .topic = conversation { return true }
        return false
    }

    private func channelName(_ streamId: Int) -> String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel"
    }

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                MessageFeedList(
                    store: store, model: model, cache: cache,
                    onNewMessages: { store.markConversationRead(conversation) })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(isTopic ? "" : conversation.displayTitle(in: store))
        .toolbar {
            // Topic transcripts title as a breadcrumb: "#channel › topic",
            // where the channel segment opens the channel's topic list.
            if case .topic(let streamId, let topic) = conversation {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 5) {
                        Button {
                            selection = .channelTopics(streamId: streamId)
                        } label: {
                            Text("#\(channelName(streamId))")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Show all topics in this channel")
                        Text("›")
                            .font(.headline)
                            .foregroundStyle(.tertiary)
                        if TopicName.isResolved(topic) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(.green)
                        }
                        Text(TopicName.displayName(topic).isEmpty
                            ? "general chat" : TopicName.displayName(topic))
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
            }
        }
        .task {
            guard model == nil else { return }
            let list = MessageListModel(store: store, narrow: conversation.narrow)
            model = list
            await list.fetchInitial()
            store.markConversationRead(conversation)
        }
    }
}
