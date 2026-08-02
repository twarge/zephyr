import SwiftUI
import ZulipAPI
import ZulipModel

/// A committed search filter — rendered as a token bubble in the sidebar
/// search field (the native analog of the web app's search pills).
enum SearchToken: Identifiable, Hashable {
    case channel(streamId: Int, name: String)
    case topic(String)
    case sender(userId: Int, name: String)
    case dm(userId: Int, name: String)
    case starred
    case mentioned

    var id: Self { self }

    var narrowElement: NarrowElement {
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
        }
    }

    /// The bubble's text.
    var bubbleText: String {
        switch self {
        case .channel(_, let name): "#\(name)"
        case .topic(let topic): "› \(TopicName.displayName(topic))"
        case .sender(_, let name): "From: \(name)"
        case .dm(_, let name): "DM: \(name)"
        case .starred: "Starred"
        case .mentioned: "Mentions"
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
        }
    }
}

/// Shared state for the sidebar's dual-role field: filter text, committed
/// token bubbles, and the lazily-loaded per-channel topic cache that both
/// filtering and suggestions draw on. Owned by MainSplitView so the
/// suggestions panel (floating over the detail column) sees the same state
/// as the sidebar.
@MainActor
@Observable
final class SidebarSearchModel {
    let store: PerAccountStore
    var filterText = ""
    var tokens: [SearchToken] = []
    private(set) var channelTopics: [Int: [ChannelTopic]] = [:]
    private(set) var loadingAllTopics = false
    private var allTopicsLoaded = false

    init(store: PerAccountStore) {
        self.store = store
    }

    var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Refreshes one channel's topics (sidebar disclosure expands).
    func refreshTopics(_ streamId: Int) {
        let connection = store.connection
        Task {
            if let topics = try? await connection.getTopics(streamId: streamId) {
                channelTopics[streamId] = topics
            }
        }
    }

    /// The filter/suggestions match against topics of every subscribed
    /// channel, so the first filter use fetches them all (bounded
    /// concurrency, cached for the session).
    func loadAllTopicsIfNeeded() {
        guard isFiltering, !allTopicsLoaded, !loadingAllTopics else { return }
        loadingAllTopics = true
        let connection = store.connection
        let ids = store.subscriptions.keys.filter { channelTopics[$0] == nil }
        Task {
            for chunk in ids.chunks(of: 5) {
                await withTaskGroup(of: (Int, [ChannelTopic]).self) { group in
                    for streamId in chunk {
                        group.addTask {
                            (streamId, (try? await connection.getTopics(streamId: streamId)) ?? [])
                        }
                    }
                    for await (streamId, topics) in group {
                        channelTopics[streamId] = topics
                    }
                }
            }
            allTopicsLoaded = true
            loadingAllTopics = false
        }
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
        return result.filter { !tokens.contains($0) }
    }

    /// Commits a suggestion as a token bubble (the caller's onChange runs the
    /// search).
    func commit(_ token: SearchToken) {
        tokens.append(token)
        filterText = ""
    }
}

/// The suggestions popup, floating at the top-leading edge of the detail
/// column — beside the sidebar, so filtered sidebar rows stay visible.
struct SearchSuggestionsPanel: View {
    let search: SidebarSearchModel
    @State private var hovered: SearchToken?

    var body: some View {
        let suggestions = search.suggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("Search")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ForEach(suggestions) { token in
                    Button {
                        search.commit(token)
                    } label: {
                        Label(token.suggestionTitle, systemImage: token.suggestionIcon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                hovered == token
                                    ? AnyShapeStyle(.quaternary)
                                    : AnyShapeStyle(.clear),
                                in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering {
                            hovered = token
                        } else if hovered == token {
                            hovered = nil
                        }
                    }
                }
            }
            .padding(6)
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(12)
        }
    }
}

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// A full search: token filters plus free text (the server's full-text
/// `search` operator).
struct SearchQuery: Hashable {
    var tokens: [SearchToken]
    var text: String

    var isEmpty: Bool {
        tokens.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var narrowElements: [NarrowElement] {
        var elements = tokens.map(\.narrowElement)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            elements.append(NarrowElement("search", .string(trimmed)))
        }
        return elements
    }

    var displayDescription: String {
        var parts = tokens.map(\.bubbleText)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            parts.append("“\(trimmed)”")
        }
        return parts.joined(separator: " ")
    }
}
