#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import ZulipAPI
import ZulipModel

/// A committed search filter — rendered as a token bubble in the sidebar
/// search field (the native analog of the web app's search pills).
nonisolated enum SearchToken: Identifiable, Hashable, Codable {
    case channel(streamId: Int, name: String)
    case topic(String)
    case sender(userId: Int, name: String)
    case dm(userId: Int, name: String)
    case starred
    case mentioned
    /// The web's `date:` operator: not a filter — the search opens its
    /// other terms anchored at the day (see `SearchQuery.anchorDay`).
    case date(CalendarDay)

    var id: Self { self }

    var isDate: Bool {
        if case .date = self { true } else { false }
    }

    /// The server narrow term; nil for a date, which travels as the
    /// fetch's anchor instead.
    var narrowElement: NarrowElement? {
        switch self {
        case .channel(let streamId, _):
            NarrowElement("channel", .int(streamId))
        case .topic(let topic):
            NarrowElement("topic", .string(topic))
        case .sender(let userId, _):
            NarrowElement("sender", .int(userId))
        case .dm(let userId, _):
            NarrowElement("dm", .intList([userId]))
        case .starred:
            NarrowElement("is", .string("starred"))
        case .mentioned:
            NarrowElement("is", .string("mentioned"))
        case .date:
            nil
        }
    }

    /// The bubble's text. A quick-pick day reads by name, as the web's
    /// pill does — relative to now, so a recent search ages correctly.
    var bubbleText: String {
        switch self {
        case .channel(_, let name): "#\(name)"
        case .topic(let topic): "› \(TopicName.displayName(topic))"
        case .sender(_, let name): "From: \(name)"
        case .dm(_, let name): "DM: \(name)"
        case .starred: "Starred"
        case .mentioned: "Mentions"
        case .date(let day):
            "Around \(day.relativeName() ?? day.start().formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// Suggestion-row presentation.
    var suggestionTitle: String {
        switch self {
        case .channel(_, let name): "Search in #\(name)"
        case .topic(let topic): "Topic: \(TopicName.displayName(topic))"
        case .sender(_, let name): "Messages from \(name)"
        case .dm(_, let name): "Direct messages with \(name)"
        case .starred: "Starred messages"
        case .mentioned: "Messages that mention you"
        case .date(let day):
            "Messages sent around \(day.start().formatted(date: .long, time: .omitted))"
        }
    }

    var suggestionIcon: String {
        switch self {
        case .channel: "number"
        case .topic: "text.bubble"
        case .sender: "person"
        case .dm: "envelope"
        case .starred: "star"
        case .mentioned: "at"
        case .date: "calendar"
        }
    }
}

/// Shared state for the window's dual-role search field: filter text and
/// committed token bubbles, over the account's topic cache that both
/// filtering and suggestions draw on. Owned by MainSplitView so detail
/// views (All Channels, Recent) can filter on the same state as the
/// sidebar.
@MainActor
@Observable
final class SidebarSearchModel {
    /// Repointed by MainSplitView when the store is replaced (provisional
    /// → live, queue rebuild) under the surviving window.
    var store: PerAccountStore
    var filterText = ""
    var tokens: [SearchToken] = []
    private(set) var recentSearches: [SearchQuery] = []

    /// Per-channel topics, recency-ordered (cached across launches).
    var channelTopics: [Int: [ChannelTopic]] {
        store.channelTopics.lists
    }

    /// Only a pass with channels that have no cached list yet shows as
    /// searching: everything else already matches from the cache.
    var loadingAllTopics: Bool {
        store.channelTopics.isLoadingUncached
    }

    private static let recentSearchesKey = "recentSearches"

    /// Hooks installed by SidebarView's Return capture: Return runs the
    /// search; ↓ hands keyboard focus to the list beneath the field
    /// (false when it declined — the key press stays with the field).
    @ObservationIgnored var onSubmit: (() -> Void)?
    @ObservationIgnored var onMoveDown: (() -> Bool)?

    init(store: PerAccountStore) {
        self.store = store
        if let data = UserDefaults.standard.data(forKey: Self.recentSearchesKey),
           let saved = try? JSONDecoder().decode([SearchQuery].self, from: data) {
            recentSearches = saved
        }
    }

    // MARK: Recent searches

    /// User-set cap (Settings); 0 disables recording and hides the section.
    private var recentSearchLimit: Int {
        UserDefaults.standard.object(forKey: "recentSearchLimit") as? Int ?? 5
    }

    func recordSearch(_ query: SearchQuery) {
        guard !query.isEmpty, recentSearchLimit > 0 else { return }
        recentSearches.removeAll { $0 == query }
        recentSearches.insert(query, at: 0)
        if recentSearches.count > recentSearchLimit {
            recentSearches.removeLast(recentSearches.count - recentSearchLimit)
        }
        persistRecents()
    }

    func removeRecentSearch(_ query: SearchQuery) {
        recentSearches.removeAll { $0 == query }
        persistRecents()
    }

    func clearRecentSearches() {
        recentSearches = []
        persistRecents()
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recentSearches) {
            UserDefaults.standard.set(data, forKey: Self.recentSearchesKey)
        }
    }

    var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Commits a suggestion the way picking a native completion does: the
    /// token joins the bubbles and the typed text clears. The sidebar's
    /// tokens observer then runs the search.
    func commit(_ token: SearchToken) {
        guard !tokens.contains(token) else { return }
        tokens.append(token)
        filterText = ""
    }

    /// Refreshes one channel's topics (sidebar disclosure expands, or a
    /// session-restored expansion appears). Offline the cached list stays,
    /// or the message database's topics stand in.
    func refreshTopics(_ streamId: Int) {
        store.channelTopics.refresh(streamId)
    }

    /// The filter/suggestions match against topics of every subscribed
    /// channel: cached lists match at once, and the first filter use each
    /// session refreshes them all (bounded concurrency, retried after an
    /// offline pass).
    func loadAllTopicsIfNeeded() {
        guard isFiltering else { return }
        let topics = store.channelTopics
        Task { await topics.loadAll() }
    }

    /// Typeahead: channels, topics, people, and flag filters matching the
    /// typed text — excluding already-committed tokens.
    var suggestions: [SearchToken] {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        var result: [SearchToken] = []

        result += store.subscriptions.values
            .filter { $0.name.localizedCaseInsensitiveContains(text) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(4)
            .map { SearchToken.channel(streamId: $0.streamId, name: $0.name) }

        var seenTopics = Set<String>()
        var topicTokens: [SearchToken] = []
        outer: for topics in channelTopics.values {
            for topic in topics
            where TopicName.displayName(topic.name).localizedCaseInsensitiveContains(text) {
                if seenTopics.insert(topic.name.lowercased()).inserted {
                    topicTokens.append(.topic(topic.name))
                    if topicTokens.count >= 4 { break outer }
                }
            }
        }
        result += topicTokens

        let people = Array(
            store.users.values.lazy
                .filter { $0.isActive != false && $0.fullName.localizedCaseInsensitiveContains(text) }
                .prefix(3))
        result += people.map { SearchToken.sender(userId: $0.userId, name: $0.fullName) }
        result += people.lazy.filter { !$0.isBot }.prefix(2)
            .map { SearchToken.dm(userId: $0.userId, name: $0.fullName) }

        if text.count >= 3, "starred".localizedCaseInsensitiveContains(text) {
            result.append(.starred)
        }
        if text.count >= 3, "mentions".localizedCaseInsensitiveContains(text) {
            result.append(.mentioned)
        }
        // Dates need the server's date anchor (Zulip 12+), and a search
        // takes one (the web treats a second as incompatible).
        if store.supportsDateAnchor, !tokens.contains(where: \.isDate) {
            result += CalendarDay.suggestions(for: text).map(SearchToken.date)
        }
        return result.filter { !tokens.contains($0) }
    }
}

/// A hidden view inside the searchable subtree: it tracks the search
/// session (`isSearching`) and captures Return while the field is active —
/// SwiftUI's onSubmit(of: .search) does not fire reliably for token search
/// fields on macOS. ↓ hands focus to the list beneath, where the
/// suggestions live as rows (SidebarView's Search section).
struct SearchReturnCapture: View {
    let search: SidebarSearchModel
    let searchFocused: Bool
    let onSubmitSearch: () -> Void
    let onMoveDown: () -> Void

    @Environment(\.isSearching) private var isSearching
    @Environment(KeyboardRouter.self) private var keys
    @State private var keyMonitor: Any?

    var body: some View {
        Color.clear
            .frame(height: 1)
            .onChange(of: isSearching) { syncMonitor() }
            .onChange(of: searchFocused) { syncMonitor() }
            .onAppear { syncMonitor() }
            .onDisappear { removeMonitor() }
    }

    private func syncMonitor() {
        // `isSearching` describes the lifetime of the native search session,
        // not keyboard focus. It can remain true after the user selects a
        // conversation and starts typing in its composer, so only intercept
        // Return while the search field itself is focused.
        if isSearching && searchFocused {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    private func installMonitor() {
        #if os(macOS)
        guard keyMonitor == nil else { return }
        // The monitor is app-wide, and a focused field keeps it installed
        // while another window is key: the hooks act only for this
        // sidebar's window.
        let keys = keys
        let onSubmitSearch = onSubmitSearch
        let onMoveDown = onMoveDown
        search.onSubmit = {
            guard keys.hostWindow?.isKeyWindow != false else { return }
            onSubmitSearch()
        }
        search.onMoveDown = {
            guard keys.hostWindow?.isKeyWindow != false else { return false }
            onMoveDown()
            return true
        }
        keyMonitor = Self.makeReturnMonitor(search: search)
        #endif
    }

    #if os(macOS)
    /// nonisolated so the AppKit handler closure infers nonisolated (the
    /// monitor fires on the main thread; assumeIsolated hops back safely).
    ///
    /// The Return is never consumed here: the field must see it first —
    /// an input method may be using it to confirm marked text, and the
    /// native submit path stays intact. A beat later, if the query is
    /// unchanged and nothing submitted (the token field's dropped-Return
    /// case this monitor exists for), the search runs as a fallback.
    /// ↓ is consumed: it moves keyboard focus into the list.
    private nonisolated static func makeReturnMonitor(search: SidebarSearchModel) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags
                .intersection([.command, .option, .control]).isEmpty
            guard plain else { return event }
            if event.keyCode == 125 {
                let handled = MainActor.assumeIsolated {
                    // Only a ↓ typed into a text field (the search field's
                    // editor, while this monitor is installed) hands off.
                    guard NSApp.keyWindow?.firstResponder is NSTextView,
                          let moveDown = search.onMoveDown
                    else { return false }
                    return moveDown()
                }
                return handled ? nil : event
            }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            guard isReturn else { return event }
            MainActor.assumeIsolated {
                let textBefore = search.filterText
                let tokensBefore = search.tokens
                let hasQuery = !textBefore.trimmingCharacters(in: .whitespaces).isEmpty
                    || !tokensBefore.isEmpty
                guard hasQuery else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard search.filterText == textBefore,
                          search.tokens == tokensBefore,
                          let submit = search.onSubmit else { return }
                    submit()
                }
            }
            return event
        }
    }
    #endif

    private func removeMonitor() {
        #if os(macOS)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        #endif
    }
}

/// Confined to the main actor in practice (all access is @MainActor; the key
/// monitor fires on the main thread and hops via assumeIsolated).
extension SidebarSearchModel: @unchecked Sendable {}

/// A full search: token filters plus free text (the server's full-text
/// `search` operator).
nonisolated struct SearchQuery: Hashable, Codable {
    var tokens: [SearchToken]
    var text: String

    /// Terms omitted by Zulip's default English full-text-search dictionary.
    /// Keep this in sync with `zulip_english.stop` in the Zulip server repo.
    private static let ignoredSearchWords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
        "any", "are", "as", "at", "b", "be", "because", "been", "before", "being",
        "below", "between", "both", "but", "by", "c", "can", "d", "did", "do", "does",
        "doing", "don", "down", "during", "e", "each", "f", "few", "for", "from",
        "further", "g", "h", "had", "has", "have", "having", "he", "her", "here",
        "hers", "herself", "him", "himself", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "itself", "j", "just", "k", "l", "m", "me", "more",
        "most", "my", "myself", "n", "no", "nor", "not", "now", "o", "of", "off",
        "on", "once", "only", "or", "other", "our", "ours", "ourselves", "out", "over",
        "own", "p", "q", "r", "s", "same", "she", "should", "so", "some", "such",
        "t", "than", "that", "the", "their", "theirs", "them", "themselves", "then",
        "there", "these", "they", "this", "those", "through", "to", "too", "u", "under",
        "until", "up", "v", "very", "w", "was", "we", "were", "what", "when", "where",
        "which", "while", "who", "whom", "why", "will", "with", "x", "y", "you", "your",
        "yours", "yourself", "yourselves", "z",
    ]

    var isEmpty: Bool {
        tokens.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Non-empty only when the keyword portion contains no searchable word.
    /// A mixed query such as "this launch" remains an ordinary search because
    /// "launch" is meaningful even though "this" is ignored.
    var exclusivelyIgnoredSearchWords: [String]? {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty, words.allSatisfy(Self.ignoredSearchWords.contains) else {
            return nil
        }
        return words
    }

    var narrowElements: [NarrowElement] {
        var elements = tokens.compactMap(\.narrowElement)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            elements.append(NarrowElement("search", .string(trimmed)))
        }
        // Narrows lacking a channel/dm operator search the user's personal
        // message history — subscribed channels (private included) plus DMs.
        // That matches the web app; appending `channels:public` here would
        // silently exclude private channels and DMs from every search.
        return elements
    }

    /// The `date:` term's day: the fetch opens there, the server's first
    /// message on or after its local midnight (the newest when none is).
    var anchorDay: CalendarDay? {
        tokens.lazy.compactMap { token in
            if case .date(let day) = token { day } else { nil }
        }.first
    }

    var displayDescription: String {
        var parts = tokens.map(\.bubbleText)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts.joined(separator: " ")
    }
}
