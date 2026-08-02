import Foundation

/// A Zulip internal narrow link (`/#narrow/…` from rendered message HTML),
/// parsed into an in-app destination. Unsupported narrows (dm, is, search…)
/// parse as nil and should fall through to the web app.
public enum InternalLink: Equatable, Sendable {
    case channel(streamId: Int)
    case topic(streamId: Int, topic: String, nearMessageId: Int?)

    public static func parse(href: String, realmURL: URL) -> InternalLink? {
        guard let hashIndex = href.firstIndex(of: "#") else { return nil }
        if href.hasPrefix("http") {
            guard let url = URL(string: href), url.host() == realmURL.host() else { return nil }
        }
        let parts = href[href.index(after: hashIndex)...]
            .split(separator: "/")
            .map(String.init)
        guard parts.first == "narrow", parts.count >= 3, (parts.count - 1).isMultiple(of: 2)
        else { return nil }

        var streamId: Int?
        var topic: String?
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
            case "near", "with":
                near = Int(operand)
            default:
                return nil
            }
            index += 2
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
