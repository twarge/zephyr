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
                        marksReadOnView: narrow == .combinedFeed)
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
