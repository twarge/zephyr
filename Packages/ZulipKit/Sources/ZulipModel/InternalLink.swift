import Foundation

/// A Zulip internal narrow link (`/#narrow/…` — from rendered message HTML,
/// or a pasted web-app URL on a signed-in realm), parsed into an in-app
/// destination. Unsupported narrows (search, settings…) parse as nil and
/// should fall through to the web app.
public enum InternalLink: Equatable, Sendable {
    case channel(streamId: Int)
    case topic(streamId: Int, topic: String, nearMessageId: Int?)
    case dm(userIds: [Int], nearMessageId: Int?)
    case starred
    case mentions
    case recent
    case inbox
    case combinedFeed
    case drafts
    case search(text: String?, senderId: Int?, streamId: Int?, topic: String?)

    public static func parse(href: String, realmURL: URL) -> InternalLink? {
        guard let hashIndex = href.firstIndex(of: "#") else { return nil }
        if href.hasPrefix("http") {
            guard let url = URL(string: href), url.host() == realmURL.host() else { return nil }
        }
        let parts = href[href.index(after: hashIndex)...]
            .split(separator: "/")
            .map(String.init)
        // Non-narrow view hashes.
        if parts.count == 1 {
            switch parts[0] {
            case "recent", "recent_topics": return .recent
            case "inbox": return .inbox
            case "all_messages", "feed": return .combinedFeed
            case "drafts": return .drafts
            default: return nil
            }
        }
        guard parts.first == "narrow", parts.count >= 3, (parts.count - 1).isMultiple(of: 2)
        else { return nil }

        var streamId: Int?
        var topic: String?
        var dmIds: [Int]?
        var searchText: String?
        var senderId: Int?
        var view: InternalLink?
        var near: Int?
        var index = 1
        while index + 1 < parts.count {
            let operatorName = parts[index]
            let operand = parts[index + 1]
            switch operatorName {
            case "channel", "stream":
                // Operand is "{id}-{slugified-name}" (or bare "{id}").
                guard let id = Int(operand.prefix(while: \.isNumber)), !operand.isEmpty else {
                    return nil
                }
                streamId = id
            case "topic", "subject":
                guard let decoded = decodeHashComponent(operand) else { return nil }
                topic = decoded
            case "dm", "pm-with":
                // Operand is "{ids,joined,by,commas}-dm" ("-pm" from old
                // links; "{id}-{name}" for a single person).
                let ids = operand
                    .prefix { $0.isNumber || $0 == "," }
                    .split(separator: ",")
                    .compactMap { Int($0) }
                guard !ids.isEmpty else { return nil }
                dmIds = ids
            case "is":
                switch operand {
                case "starred": view = .starred
                case "mentioned": view = .mentions
                default: return nil
                }
            case "search":
                guard let decoded = decodeHashComponent(operand) else { return nil }
                searchText = decoded
            case "sender":
                // Operand is "{id}-{slugified-name}" like channels.
                guard let id = Int(operand.prefix(while: \.isNumber)) else { return nil }
                senderId = id
            case "near", "with":
                near = Int(operand)
            default:
                return nil
            }
            index += 2
        }
        if let view, streamId == nil, dmIds == nil, searchText == nil, senderId == nil {
            return view
        }
        if searchText != nil || senderId != nil {
            // A search narrow, optionally scoped by channel/topic.
            guard dmIds == nil, view == nil else { return nil }
            return .search(text: searchText, senderId: senderId, streamId: streamId, topic: topic)
        }
        if let dmIds {
            return .dm(userIds: dmIds, nearMessageId: near)
        }
        guard let streamId else { return nil }
        if let topic {
            return .topic(streamId: streamId, topic: topic, nearMessageId: near)
        }
        return .channel(streamId: streamId)
    }

    /// Zulip hash encoding: percent-encoding with `%` swapped for `.`
    /// ("hi there" → "hi.20there").
    static func decodeHashComponent(_ component: String) -> String? {
        component
            .replacingOccurrences(of: ".", with: "%")
            .removingPercentEncoding
    }
}

/// Zulip marks resolved topics by prefixing "✔ " to the topic name; clients
/// render that as a state, not text.
public enum TopicName {
    public static let resolvedPrefix = "✔ "

    public static func isResolved(_ topic: String) -> Bool {
        topic.hasPrefix(resolvedPrefix)
    }

    public static func displayName(_ topic: String) -> String {
        isResolved(topic) ? String(topic.dropFirst(resolvedPrefix.count)) : topic
    }
}
