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
