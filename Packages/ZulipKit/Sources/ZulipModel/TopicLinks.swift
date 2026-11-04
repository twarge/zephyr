import Foundation

/// A link from a channel message to a conversation — the web app's
/// cross-conversation link, behind the topic menu's View Links. Topic
/// links (`a.stream-topic`, `#**channel>topic**`) and message links
/// (`a.message-link`, `/near/` URLs) count, as do pasted narrow URLs to
/// either; links to a whole channel, and anything in or to a DM, don't.
public struct TopicLink: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case topic
        case message
    }

    public var streamId: Int
    public var topic: String
    /// The linked message for a message link. A topic link can carry one
    /// too: a topic permalink (`/with/{id}`, what the server renders
    /// `#**channel>topic**` as) is anchored on a message in the topic, and
    /// goes wherever that message is now — so it survives the topic being
    /// renamed or moved.
    public var messageId: Int?
    public var kind: Kind

    public init(streamId: Int, topic: String, messageId: Int?, kind: Kind) {
        self.streamId = streamId
        self.topic = topic
        self.messageId = messageId
        self.kind = kind
    }

    /// The links in a message's rendered HTML, in document order,
    /// duplicates kept. Server-rendered hrefs to the realm itself are
    /// relative; an absolute one counts only when its host is `realmURL`'s
    /// (nil accepts relative links only).
    public static func links(inHTML html: String, realmURL: URL?) -> [TopicLink] {
        // Most messages have no narrow links; skip the scan for them.
        guard mentionsNarrow(html) else { return [] }
        var links: [TopicLink] = []
        for href in anchorHrefs(in: html) where href.contains("#narrow/") {
            if let link = link(fromHref: href, realmURL: realmURL) {
                links.append(link)
            }
        }
        return links
    }

    /// One href, parsed: nil for anything but a topic or message link.
    public static func link(fromHref href: String, realmURL: URL?) -> TopicLink? {
        if href.hasPrefix("http"), realmURL == nil { return nil }
        guard case .topic(let streamId, let topic, let near)? = InternalLink.parse(
            href: href, realmURL: realmURL ?? relativeOnly)
        else { return nil }
        guard let near else {
            return TopicLink(streamId: streamId, topic: topic, messageId: nil, kind: .topic)
        }
        // `with` anchors a topic link; `near` names the message itself.
        // Topic names are hash-encoded ("/" is ".2F"), so a literal
        // "/with/" can only be the operator.
        let anchored = href.contains("/with/")
        return TopicLink(
            streamId: streamId, topic: topic, messageId: near,
            kind: anchored ? .topic : .message)
    }

    /// Whether the HTML has a narrow URL anywhere: a byte search, about a
    /// tenth the cost of `String.contains` — every message written to the
    /// store passes through it.
    public static func mentionsNarrow(_ html: String) -> Bool {
        var html = html
        return html.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return false }
            return memmem(base, bytes.count, narrowMarker, narrowMarker.count) != nil
        }
    }

    private static let narrowMarker = Array("#narrow/".utf8)

    /// Stands in for the realm when only relative links are accepted —
    /// absolute ones are turned away before parsing, so it's never read.
    private static let relativeOnly = URL(string: "https://relative.invalid")!

    /// Every `<a href="…">` value, entity-decoded. A scan rather than a
    /// DOM parse: server HTML always double-quotes attributes and escapes
    /// `<` in text, so a tag can't hide inside code or prose — and the
    /// message store indexes every message it writes through this.
    static func anchorHrefs(in html: String) -> [String] {
        var hrefs: [String] = []
        var searchStart = html.startIndex
        while let open = html.range(of: "<a ", range: searchStart..<html.endIndex) {
            guard let close = html.range(of: ">", range: open.upperBound..<html.endIndex)
            else { break }
            searchStart = close.upperBound
            let tag = open.upperBound..<close.lowerBound
            guard let attribute = html.range(of: "href=\"", range: tag),
                  let end = html.range(
                    of: "\"", range: attribute.upperBound..<close.lowerBound)
            else { continue }
            hrefs.append(decodeEntities(String(html[attribute.upperBound..<end.lowerBound])))
        }
        return hrefs
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// A stored link, with where its source message is now and where its
/// target resolved to — the input `TopicLinkLists` groups.
public struct TopicLinkRecord: Hashable, Sendable {
    public var fromMessageId: Int
    public var fromStreamId: Int
    public var fromTopic: String
    /// The target as it stands: a message link, or a topic link anchored
    /// on a message, follows that message to its current topic when it's
    /// stored; otherwise it's where the URL says.
    public var target: TopicLink
    /// The message a row lands on — the linking message for "Linked from",
    /// the linked one for a message link — when it's stored.
    public var sender: String?
    public var timestamp: Int?

    public init(
        fromMessageId: Int, fromStreamId: Int, fromTopic: String, target: TopicLink,
        sender: String? = nil, timestamp: Int? = nil
    ) {
        self.fromMessageId = fromMessageId
        self.fromStreamId = fromStreamId
        self.fromTopic = fromTopic
        self.target = target
        self.sender = sender
        self.timestamp = timestamp
    }
}

/// One conversation's View Links: what it links to, and what links to it.
/// Grouped as the web app groups them, oldest linking message first.
public struct TopicLinkLists: Equatable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public var streamId: Int
        public var topic: String
        /// The message the row lands on (nil opens the conversation).
        public var messageId: Int?
        /// True for a row that is a link to one message — every "Linked
        /// from" row is (it lands on the linking message).
        public var isMessageLink: Bool
        public var sender: String?
        public var timestamp: Int?

        public var id: String { TopicLinkLists.key(streamId, topic, messageId) }
    }

    /// "Links to": conversations this one's messages link to.
    public var linksTo: [Row]
    /// "Linked from": conversations whose messages link to this one.
    public var linkedFrom: [Row]

    public var isEmpty: Bool { linksTo.isEmpty && linkedFrom.isEmpty }

    public static let empty = TopicLinkLists(linksTo: [], linkedFrom: [])

    public init(linksTo: [Row], linkedFrom: [Row]) {
        self.linksTo = linksTo
        self.linkedFrom = linkedFrom
    }

    /// `outgoing` holds links from the conversation's messages, `incoming`
    /// links to it (either may carry extras; each list keeps only what
    /// applies). Links within the conversation itself are left out, as
    /// are channels `isVisible` rejects (no longer accessible).
    ///
    /// "Links to" keeps one row per topic, and one per linked message —
    /// two links to a topic are one row even when anchored differently.
    /// "Linked from" keeps one row per linking conversation, landing on
    /// its oldest linking message.
    public init(
        streamId: Int, topic: String,
        outgoing: [TopicLinkRecord], incoming: [TopicLinkRecord],
        isVisible: (Int) -> Bool = { _ in true }
    ) {
        func isHere(_ otherStreamId: Int, _ otherTopic: String) -> Bool {
            otherStreamId == streamId && TopicName.matches(otherTopic, topic)
        }

        var linksTo: [Row] = []
        var seenTargets: Set<String> = []
        for record in Self.oldestFirst(outgoing) {
            guard isHere(record.fromStreamId, record.fromTopic) else { continue }
            let target = record.target
            guard !isHere(target.streamId, target.topic), isVisible(target.streamId)
            else { continue }
            let isMessage = target.kind == .message
            let key = Self.key(
                target.streamId, target.topic, isMessage ? target.messageId : nil)
            guard seenTargets.insert(key).inserted else { continue }
            linksTo.append(Row(
                streamId: target.streamId, topic: target.topic,
                messageId: isMessage ? target.messageId : nil, isMessageLink: isMessage,
                sender: isMessage ? record.sender : nil,
                timestamp: isMessage ? record.timestamp : nil))
        }

        var linkedFrom: [Row] = []
        var seenSources: Set<String> = []
        for record in Self.oldestFirst(incoming) {
            guard isHere(record.target.streamId, record.target.topic),
                  !isHere(record.fromStreamId, record.fromTopic),
                  isVisible(record.fromStreamId)
            else { continue }
            let key = Self.key(record.fromStreamId, record.fromTopic, nil)
            guard seenSources.insert(key).inserted else { continue }
            linkedFrom.append(Row(
                streamId: record.fromStreamId, topic: record.fromTopic,
                messageId: record.fromMessageId, isMessageLink: true,
                sender: record.sender, timestamp: record.timestamp))
        }
        self.init(linksTo: linksTo, linkedFrom: linkedFrom)
    }

    /// By linking message, a message's own links staying in the order
    /// given (document order, from the database).
    private static func oldestFirst(_ records: [TopicLinkRecord]) -> [TopicLinkRecord] {
        records.enumerated()
            .sorted {
                ($0.element.fromMessageId, $0.offset) < ($1.element.fromMessageId, $1.offset)
            }
            .map(\.element)
    }

    fileprivate static func key(_ streamId: Int, _ topic: String, _ messageId: Int?) -> String {
        "\(streamId)\u{1}\(TopicName.canonical(topic).lowercased())\u{1}\(messageId ?? 0)"
    }
}
