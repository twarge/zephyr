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

    func body(content: Content) -> some View {
        #if os(macOS)
        if case .topic(let streamId, _) = conversation {
            content.toolbarTitleMenu {
                Button("All Messages in #\(store.channelName(streamId))", systemImage: "number") {
                    selection = .channel(streamId: streamId)
                }
                Button("Topics in #\(store.channelName(streamId))", systemImage: "list.bullet") {
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
    /// The window, for per-window scroll memory (FeedWarmCache).
    let scene: FeedWarmCache.Scene

    @Environment(KeyboardRouter.self) private var keys
    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()
    @State private var scrollMemory = FeedScrollMemory()

    init(
        store: PerAccountStore, conversation: ConversationKey,
        selection: Binding<Destination?>, scene: FeedWarmCache.Scene
    ) {
        self.store = store
        self.conversation = conversation
        self.scene = scene
        _selection = selection
        // A recently viewed conversation resumes its parked model, and a
        // cold one opens on its cached messages — set before the first
        // layout pass so there is no spinner frame.
        let narrow = conversation.narrow(selfUserId: store.selfUserId)
        if let warm = FeedWarmCache.shared.lookupOrPreview(
            narrow: narrow, store: store, scene: scene,
            makeModel: { MessageListModel(store: store, narrow: narrow) })
        {
            _model = State(initialValue: warm.model)
            _cache = State(initialValue: warm.cache)
            _scrollMemory = State(initialValue: warm.scrollMemory)
        }
    }

    /// "#channel › topic" (with a resolved check where applicable); DMs use
    /// their participant title.
    private var windowTitle: String {
        if case .topic(let streamId, let topic) = conversation {
            let display = TopicName.displayName(topic)
            let name = display.isEmpty ? "general chat" : display
            let resolved = TopicName.isResolved(topic) ? "✓ " : ""
            return "\(store.channelName(streamId)) › \(resolved)\(name)"
        }
        return conversation.displayTitle(in: store)
    }

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                MessageFeedList(
                    store: store, model: model, cache: cache,
                    marksArrivalsRead: true,
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
            await bindModel()
        }
        // A message link into this conversation whose target isn't in the
        // loaded window (MainSplitView leaves it pending): refetch there.
        .onChange(of: keys.pendingNearRequest) {
            guard let pending = keys.pendingNear, pending.key == conversation else { return }
            Task { await bindModel() }
        }
    }

    private func bindModel() async {
        // A message link opens anchored at its target.
        var anchor: Int?
        if let pending = keys.pendingNear, pending.key == conversation {
            anchor = pending.messageId
            keys.pendingNear = nil
        }
        let narrow = conversation.narrow(selfUserId: store.selfUserId)
        // Only a message-link anchor forces a fresh fetch. A link replaces
        // a cached preview outright, as a first open would: the preview
        // sits at the first unread, not the link's target. Anchored
        // fetches stay out of the warm cache: they resume mid-history,
        // which a plain reopen shouldn't.
        await FeedWarmCache.shared.bind(
            current: model, store: store, narrow: narrow, count: 60,
            keepsCurrent: anchor == nil, replacesPreview: true, parks: anchor == nil,
            warm: (cache, scrollMemory), scene: scene,
            makeModel: {
                MessageListModel(store: store, narrow: narrow, anchorMessageId: anchor)
            },
            install: { model = $0 })
        store.markConversationRead(conversation)
    }
}
