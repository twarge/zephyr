import SwiftUI
import ZulipModel

/// A cross-channel feed for the sidebar Views (Combined feed, Mentions,
/// Starred): messages from any conversation, with "#channel › topic" headers
/// that jump to the focused conversation. Never auto-marks read.
struct NarrowFeedView: View {
    let store: PerAccountStore
    let title: String
    let narrow: Narrow
    var useMatchHighlights = false
    var ignoredSearchWords: [String]?
    /// The control row swaps quoted reply for a go-to-conversation jump
    /// (Combined, Mentions, Starred, Search).
    var showsConversationJump = false
    @Binding var selection: Destination?

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()
    @State private var scrollMemory = FeedScrollMemory()

    private var isCustomNarrow: Bool {
        if case .custom = narrow { true } else { false }
    }

    init(
        store: PerAccountStore, title: String, narrow: Narrow,
        useMatchHighlights: Bool = false,
        ignoredSearchWords: [String]? = nil,
        showsConversationJump: Bool = false,
        selection: Binding<Destination?>
    ) {
        self.store = store
        self.title = title
        self.narrow = narrow
        self.useMatchHighlights = useMatchHighlights
        self.ignoredSearchWords = ignoredSearchWords
        self.showsConversationJump = showsConversationJump
        _selection = selection
        // A recently viewed feed resumes its parked model — set before
        // the first layout pass so there is no spinner frame. Search
        // narrows (`.custom`) never park: they can't live-append (see
        // Narrow.custom), so a parked one would silently go stale.
        if case .custom = narrow { return }
        if let warm = FeedWarmCache.shared.lookup(narrow: narrow, store: store) {
            _model = State(initialValue: warm.model)
            _cache = State(initialValue: warm.cache)
            _scrollMemory = State(initialValue: warm.scrollMemory)
        }
    }

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                if let error = model.fetchError, model.messages.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load Messages",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription))
                } else if model.messages.isEmpty, let ignoredSearchWords {
                    ContentUnavailableView(
                        "Search Terms Ignored",
                        systemImage: "magnifyingglass",
                        description: Text(ignoredSearchDescription(ignoredSearchWords)))
                } else {
                    MessageFeedList(
                        store: store, model: model, cache: cache,
                        headerMode: .channelAndTopic,
                        useMatchHighlights: useMatchHighlights,
                        onHeaderTap: { key in
                            selection = .conversation(key)
                        },
                        showsConversationJump: showsConversationJump,
                        marksReadOnView: narrow == .combinedFeed,
                        scrollMemory: scrollMemory)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .serverTitled(title, store: store)
        // Store-keyed: re-binds when the store instance is replaced
        // (warm-launch swap, queue rebuild).
        .task(id: ObjectIdentifier(store)) {
            // A healthy model bound to this store (warm start, or a
            // reappearing live view) needs no refetch.
            if let model, model.isBound(to: store),
               model.didInitialFetch, model.fetchError == nil
            {
                return
            }
            let list = MessageListModel(store: store, narrow: narrow)
            if model == nil {
                model = list
                await list.fetchInitial(count: 100)
            } else {
                // Store swap: keep rendering the old feed until the
                // replacement has content.
                await list.fetchInitial(count: 100)
                model = list
            }
            if list.fetchError == nil, !isCustomNarrow {
                FeedWarmCache.shared.insert(
                    model: list, cache: cache, scrollMemory: scrollMemory,
                    narrow: narrow, store: store)
            }
        }
    }

    private func ignoredSearchDescription(_ words: [String]) -> String {
        let terms = words.map { "\u{201c}\($0)\u{201d}" }.joined(separator: ", ")
        let verb = words.count == 1 ? "is" : "are"
        let pronoun = words.count == 1 ? "it" : "them"
        return "\(terms) \(verb) too common to search for, so Zulip ignores \(pronoun). "
            + "Try adding a more distinctive word."
    }
}
