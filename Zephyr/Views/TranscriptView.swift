import SwiftUI
import ZulipAPI
import ZulipModel

/// A focused transcript for one topic or DM thread. Opens anchored at the
/// newest messages; scrolling up pages in history.
struct TranscriptView: View {
    let store: PerAccountStore
    let conversation: ConversationKey
    @Binding var selection: Destination?

    @Environment(KeyboardRouter.self) private var keys
    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()
    @State private var showAddPeople = false

    /// The other people in this DM, seeding the "Add People…" sheet.
    private var dmParticipants: [User] {
        (conversation.dmParticipantIds ?? [])
            .filter { $0 != store.selfUserId }
            .compactMap { store.users[$0] }
    }

    private func channelName(_ streamId: Int) -> String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel"
    }

    /// "#channel › topic" (with a resolved check where applicable); DMs use
    /// their participant title.
    private var windowTitle: String {
        if case .topic(let streamId, let topic) = conversation {
            let display = TopicName.displayName(topic)
            let name = display.isEmpty ? "general chat" : display
            let resolved = TopicName.isResolved(topic) ? "✓ " : ""
            return "#\(channelName(streamId)) › \(resolved)\(name)"
        }
        return conversation.displayTitle(in: store)
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
        .navigationTitle(windowTitle)
        // The title is a real window title (system-truncated, never
        // dropped); channel navigation lives in its title menu.
        .toolbarTitleMenu {
            if case .topic(let streamId, _) = conversation {
                Button("All Messages in #\(channelName(streamId))", systemImage: "number") {
                    selection = .channel(streamId: streamId)
                }
                Button("Topics in #\(channelName(streamId))", systemImage: "list.bullet") {
                    selection = .channelTopics(streamId: streamId)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(
                store: store,
                mode: .fixed(
                    conversation.sendDestination(selfUserId: store.selfUserId),
                    placeholder: conversation.displayTitle(in: store)))
        }
        .toolbar {
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
        // Keyed to the store instance: when the provisional warm-launch
        // store is replaced by the live one (or a queue rebuild swaps
        // stores), the list re-binds — otherwise it stays registered with a
        // dead store and never receives live events.
        .task(id: ObjectIdentifier(store)) {
            // A message link opens anchored at its target.
            var anchor: Int?
            if let pending = keys.pendingNear, pending.key == conversation {
                anchor = pending.messageId
                keys.pendingNear = nil
            }
            let list = MessageListModel(
                store: store, narrow: conversation.narrow(selfUserId: store.selfUserId),
                anchorMessageId: anchor)
            if model == nil {
                // First open: show the fetch in progress.
                model = list
                await list.fetchInitial()
            } else {
                // Store swap (provisional → live at launch, queue rebuild):
                // the rendered transcript stays up until the replacement
                // has content — no blank flash mid-read.
                await list.fetchInitial()
                model = list
            }
            store.markConversationRead(conversation)
        }
    }
}
