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
        .navigationTitle(conversation.displayTitle(in: store))
        .toolbar {
            if case .topic(let streamId, let topic) = conversation {
                ToolbarItemGroup(placement: .automatic) {
                    if TopicName.isResolved(topic) {
                        Label("Resolved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    }
                    Button {
                        selection = .channel(streamId: streamId)
                    } label: {
                        Text("#\(store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel")")
                    }
                    .help("Show the whole channel")
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
