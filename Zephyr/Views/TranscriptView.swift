import SwiftUI
import ZulipAPI
import ZulipModel

/// A focused transcript for one topic or DM thread. Opens anchored at the
/// newest messages; scrolling up pages in history.
struct TranscriptView: View {
    let store: PerAccountStore
    let conversation: ConversationKey
    @Binding var selection: Destination?

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()
    @State private var showAddPeople = false

    private var isTopic: Bool {
        if case .topic = conversation { return true }
        return false
    }

    /// The other people in this DM, seeding the "Add People…" sheet.
    private var dmParticipants: [User] {
        (conversation.dmParticipantIds ?? [])
            .filter { $0 != store.selfUserId }
            .compactMap { store.users[$0] }
    }

    private func channelName(_ streamId: Int) -> String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel"
    }

    private func breadcrumb(streamId: Int, topic: String) -> some View {
        HStack(spacing: 5) {
            Button {
                selection = .channel(streamId: streamId)
            } label: {
                Text("#\(channelName(streamId))")
                    .font(.headline)
            }
            .buttonStyle(.plain)
            .help("Show all messages in this channel")
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(
                store: store,
                mode: .fixed(
                    conversation.sendDestination(selfUserId: store.selfUserId),
                    placeholder: conversation.displayTitle(in: store)))
        }
        .toolbar {
            // Topic transcripts title as a breadcrumb: "#channel › topic",
            // where the channel segment opens the channel's full feed.
            if case .topic(let streamId, let topic) = conversation {
                if #available(macOS 26.0, iOS 26.0, *) {
                    // No glass capsule around the breadcrumb — it's a title,
                    // not a control.
                    ToolbarItem(placement: .navigation) {
                        breadcrumb(streamId: streamId, topic: topic)
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) {
                        breadcrumb(streamId: streamId, topic: topic)
                    }
                }
            }
            // A DM can't change membership (Zulip semantics), so "Add
            // People" starts a new conversation pre-seeded with everyone
            // here.
            if case .dm = conversation {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAddPeople = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .help("New conversation with these people plus others")
                }
            }
        }
        .sheet(isPresented: $showAddPeople) {
            NewConversationSheet(
                store: store, selection: $selection,
                mode: .directMessage(initialUsers: dmParticipants))
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
