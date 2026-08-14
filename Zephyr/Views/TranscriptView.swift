import SwiftUI
import ZulipAPI
import ZulipModel

/// macOS-only channel navigation in the window-title menu, attached
/// only for topic conversations — an empty toolbarTitleMenu still
/// renders its disclosure chevron, dead.
private struct ChannelTitleMenu: ViewModifier {
    let store: PerAccountStore
    let conversation: ConversationKey
    @Binding var selection: Destination?

    private func channelName(_ streamId: Int) -> String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "channel"
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        if case .topic(let streamId, _) = conversation {
            content.toolbarTitleMenu {
                Button("All Messages in #\(channelName(streamId))", systemImage: "number") {
                    selection = .channel(streamId: streamId)
                }
                Button("Topics in #\(channelName(streamId))", systemImage: "list.bullet") {
                    selection = .channelTopics(streamId: streamId)
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A focused transcript for one topic or DM thread. Opens anchored at the
/// newest messages; scrolling up pages in history.
struct TranscriptView: View {
    let store: PerAccountStore
    let conversation: ConversationKey
    @Binding var selection: Destination?

    @Environment(KeyboardRouter.self) private var keys
    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()
    @State private var scrollMemory = FeedScrollMemory()

    init(
        store: PerAccountStore, conversation: ConversationKey,
        selection: Binding<Destination?>
    ) {
        self.store = store
        self.conversation = conversation
        _selection = selection
        // A recently viewed conversation resumes its parked model — set
        // before the first layout pass so there is no spinner frame.
        if let warm = FeedWarmCache.shared.lookup(
            narrow: conversation.narrow(selfUserId: store.selfUserId), store: store)
        {
            _model = State(initialValue: warm.model)
            _cache = State(initialValue: warm.cache)
            _scrollMemory = State(initialValue: warm.scrollMemory)
        }
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
            return "\(channelName(streamId)) › \(resolved)\(name)"
        }
        return conversation.displayTitle(in: store)
    }

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                MessageFeedList(
                    store: store, model: model, cache: cache,
                    onNewMessages: { store.markConversationRead(conversation) },
                    scrollMemory: scrollMemory)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .serverTitled(windowTitle, store: store)
        // The title is a real window title (system-truncated, never
        // dropped); on macOS, channel navigation lives in its title menu —
        // attached only when it has content, or the bare chevron draws
        // anyway. iOS skips the menu entirely: its chevron would duplicate
        // the toolbar's # up-button (and sat dead on DMs).
        .modifier(ChannelTitleMenu(
            store: store, conversation: conversation, selection: $selection))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(
                store: store,
                mode: .fixed(
                    conversation.sendDestination(selfUserId: store.selfUserId),
                    placeholder: conversation.displayTitle(in: store)))
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
            let narrow = conversation.narrow(selfUserId: store.selfUserId)
            // A healthy model already bound to this store (warm start, or
            // a reappearing live view) needs no refetch — parked models
            // keep absorbing live events. Only a message-link anchor
            // forces a fresh fetch.
            if anchor == nil, let model, model.isBound(to: store),
               model.didInitialFetch, model.fetchError == nil
            {
                store.markConversationRead(conversation)
                return
            }
            let list = MessageListModel(
                store: store, narrow: narrow, anchorMessageId: anchor)
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
            // Park for instant return. Anchored fetches stay out: they
            // resume mid-history, which a plain reopen shouldn't.
            if anchor == nil, list.fetchError == nil {
                FeedWarmCache.shared.insert(
                    model: list, cache: cache, scrollMemory: scrollMemory,
                    narrow: narrow, store: store)
            }
            store.markConversationRead(conversation)
        }
    }
}
