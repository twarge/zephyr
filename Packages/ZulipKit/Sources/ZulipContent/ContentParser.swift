import Foundation
import SwiftSoup

/// Parses Zulip's server-rendered message HTML into the typed AST.
///
/// Matching is strict (exact element + class structure, following
/// zulip-flutter's proven approach); anything else becomes `.unimplemented`.
/// A top-level parse failure yields a single unimplemented block — the parser
/// never throws.
public enum ContentParser {
    public static func parse(html: String) -> MessageContent {
        do {
            let document = try SwiftSoup.parseBodyFragment(html)
            guard let body = document.body() else {
                return MessageContent(blocks: [.unimplemented(html: html)])
            }
            return MessageContent(blocks: parseBlocks(body.getChildNodes()))
        } catch {
            return MessageContent(blocks: [.unimplemented(html: html)])
        }
    }

    // MARK: Blocks

    private static func parseBlocks(_ nodes: [Node]) -> [BlockNode] {
        var blocks: [BlockNode] = []
        var danglingInlines: [InlineNode] = []

        func flushInlines() {
            let trimmed = trimInlines(danglingInlines)
            if !trimmed.isEmpty {
                blocks.append(.paragraph(trimmed))
            }
            danglingInlines = []
        }

        for node in nodes {
            if let text = node as? TextNode {
                // Whitespace between blocks is layout noise; real text becomes
                // an implicit paragraph (as inside loose list items).
                if !text.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    danglingInlines.append(.text(text.getWholeText()))
                }
                continue
            }
            guard let element = node as? Element else { continue }
            if let block = parseBlockElement(element) {
                flushInlines()
                blocks.append(block)
            } else {
                danglingInlines.append(parseInlineNode(element))
            }
        }
        flushInlines()
        return blocks
    }

    /// Returns nil when the element is inline-level (to be wrapped in an
    /// implicit paragraph by the caller).
    private static func parseBlockElement(_ element: Element) -> BlockNode? {
        let tag = element.tagName()
        let classes = classList(element)

        switch tag {
        case "p":
            // Block math arrives wrapped in <p><span class="katex-display">.
            if element.children().count == 1,
               let child = element.children().first(),
               child.tagName() == "span", classList(child) == ["katex-display"] {
                if let tex = katexSource(child) {
                    return .mathBlock(tex: tex)
                }
                return .unimplemented(html: outerHTML(element))
            }
            let inlines = trimInlines(parseInlines(element.getChildNodes()))
            return inlines.isEmpty ? nil : .paragraph(inlines)

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.dropFirst())) ?? 1
            return .heading(level: level, trimInlines(parseInlines(element.getChildNodes())))

        case "blockquote":
            return .blockquote(parseBlocks(element.getChildNodes()))

        case "ul":
            return .unorderedList(items: listItems(element))

        case "ol":
            let start = Int(try2 { try element.attr("start") } ?? "") ?? 1
            return .orderedList(start: start, items: listItems(element))

        case "hr":
            return .thematicBreak

        case "div" where classes.contains("codehilite"):
            let language = try2 { try element.attr("data-code-language") }
                .flatMap { $0.isEmpty ? nil : $0 }
            guard let pre = element.children().first(), pre.tagName() == "pre" else {
                return .unimplemented(html: outerHTML(element))
            }
            var code = wholeText(pre)
            if code.hasSuffix("\n") {
                code = String(code.dropLast())
            }
            return .codeBlock(language: language, code: code)

        case "div" where classes.contains("spoiler-block"):
            let children = element.children()
            guard children.count == 2,
                  let header = children.first(), classList(header).contains("spoiler-header")
            else {
                return .unimplemented(html: outerHTML(element))
            }
            let content = children.get(1)
            guard classList(content).contains("spoiler-content") else {
                return .unimplemented(html: outerHTML(element))
            }
            // The header holds inline content (possibly in an implicit <p>).
            let headerBlocks = parseBlocks(header.getChildNodes())
            let headerInlines: [InlineNode] =
                if case .paragraph(let inlines) = headerBlocks.first, headerBlocks.count == 1 {
                    inlines
                } else if headerBlocks.isEmpty {
                    []
                } else {
                    [.text(header.ownText())]
                }
            return .spoiler(header: headerInlines, content: parseBlocks(content.getChildNodes()))

        case "div" where classes.contains("message_inline_image"):
            if classes.contains("message_inline_video") {
                return .unimplemented(html: outerHTML(element))
            }
            guard let anchor = element.children().first(), anchor.tagName() == "a",
                  let img = anchor.children().first(where: { $0.tagName() == "img" })
            else {
                return .unimplemented(html: outerHTML(element))
            }
            let dimensions = (try2 { try img.attr("data-original-dimensions") } ?? "")
                .split(separator: "x").compactMap { Int($0) }
            return .image(
                ImageNode(
                    src: try2 { try img.attr("src") } ?? "",
                    originalSrc: try2 { try anchor.attr("href") },
                    alt: try2 { try img.attr("alt") }.flatMap { $0.isEmpty ? nil : $0 },
                    originalWidth: dimensions.count == 2 ? dimensions[0] : nil,
                    originalHeight: dimensions.count == 2 ? dimensions[1] : nil))

        case "div", "table", "video", "audio", "iframe", "details":
            return .unimplemented(html: outerHTML(element))

        default:
            return nil
        }
    }

    private static func listItems(_ list: Element) -> [[BlockNode]] {
        list.children().compactMap { child -> [BlockNode]? in
            guard child.tagName() == "li" else { return nil }
            return parseBlocks(child.getChildNodes())
        }
    }

    // MARK: Inlines

    private static func parseInlines(_ nodes: [Node]) -> [InlineNode] {
        nodes.map { node in
            if let text = node as? TextNode {
                return .text(text.getWholeText())
            }
            guard let element = node as? Element else {
                return .text("")
            }
            return parseInlineNode(element)
        }
    }

    private static func parseInlineNode(_ element: Element) -> InlineNode {
        let tag = element.tagName()
        let classes = classList(element)

        switch tag {
        case "br":
            return .lineBreak
        case "strong":
            return .strong(parseInlines(element.getChildNodes()))
        case "em":
            return .emphasis(parseInlines(element.getChildNodes()))
        case "del":
            return .strikethrough(parseInlines(element.getChildNodes()))
        case "code":
            return .inlineCode(wholeText(element))
        case "time":
            guard let datetime = try2({ try element.attr("datetime") }), !datetime.isEmpty else {
                return .unimplemented(html: outerHTML(element))
            }
            return .globalTime(datetime: datetime)

        case "a":
            let href = try2 { try element.attr("href") } ?? ""
            let streamId = try2 { try element.attr("data-stream-id") }.flatMap { Int($0) }
            let kind: LinkNode.Kind =
                if classes.contains("stream-topic") {
                    .channelTopic(streamId: streamId)
                } else if classes.contains("stream") {
                    .channel(streamId: streamId)
                } else if classes.contains("message-link") {
                    .messageLink
                } else {
                    .plain
                }
            return .link(
                LinkNode(text: parseInlines(element.getChildNodes()), href: href, kind: kind))

        case "span" where classes.contains("user-mention"):
            let userId = try2 { try element.attr("data-user-id") }
            let target: MentionNode.Target =
                if userId == "*" || classes.contains("channel-wildcard-mention") {
                    .channelWildcard
                } else {
                    .user(id: userId.flatMap { Int($0) })
                }
            return .mention(
                MentionNode(
                    text: element.ownTextTrimmed, target: target,
                    silent: classes.contains("silent")))

        case "span" where classes.contains("user-group-mention"):
            let groupId = try2 { try element.attr("data-user-group-id") }.flatMap { Int($0) }
            return .mention(
                MentionNode(
                    text: element.ownTextTrimmed, target: .userGroup(id: groupId),
                    silent: classes.contains("silent")))

        case "span" where classes.contains("topic-mention"):
            return .mention(
                MentionNode(
                    text: element.ownTextTrimmed, target: .topicWildcard,
                    silent: classes.contains("silent")))

        case "span" where classes.contains("emoji"):
            guard let hexClass = classes.first(where: { $0.hasPrefix("emoji-") }) else {
                return .unimplemented(html: outerHTML(element))
            }
            let scalars = hexClass.dropFirst("emoji-".count)
                .split(separator: "-")
                .compactMap { UInt32($0, radix: 16) }
                .compactMap { Unicode.Scalar($0) }
            guard !scalars.isEmpty else {
                return .unimplemented(html: outerHTML(element))
            }
            let character = String(String.UnicodeScalarView(scalars))
            let name = element.ownTextTrimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return .emoji(.unicode(character, name: name))

        case "span" where classes.contains("katex"):
            guard let tex = katexSource(element) else {
                return .unimplemented(html: outerHTML(element))
            }
            return .inlineMath(tex: tex)

        case "img" where classes.contains("emoji"):
            let name = (try2 { try element.attr("alt") } ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return .emoji(.realm(src: try2 { try element.attr("src") } ?? "", name: name))

        default:
            return .unimplemented(html: outerHTML(element))
        }
    }

    // MARK: Helpers

    /// The KaTeX source, from the `<annotation encoding="application/x-tex">`
    /// element KaTeX embeds in its MathML block.
    private static func katexSource(_ element: Element) -> String? {
        guard let annotation = try? element.select("annotation[encoding=application/x-tex]").first()
        else { return nil }
        let tex = wholeText(annotation).trimmingCharacters(in: .whitespacesAndNewlines)
        return tex.isEmpty ? nil : tex
    }

    // Avoids SwiftSoup's classNames()/OrderedSet, which crashes on the
    // current macOS beta toolchain (segfault in hashing).
    private static func classList(_ element: Element) -> [String] {
        ((try? element.attr("class")) ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }

    /// Text content with whitespace preserved (SwiftSoup's `text()`
    /// normalizes, which would destroy code blocks).
    private static func wholeText(_ node: Node) -> String {
        if let text = node as? TextNode {
            return text.getWholeText()
        }
        return node.getChildNodes().map(wholeText).joined()
    }

    private static func outerHTML(_ element: Element) -> String {
        (try2 { try element.outerHtml() }) ?? "<\(element.tagName())>"
    }

    /// Drops pure-whitespace leading/trailing text runs (the server emits
    /// `\n` between elements).
    private static func trimInlines(_ inlines: [InlineNode]) -> [InlineNode] {
        var result = inlines
        while case .text(let text)? = result.first,
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeFirst()
        }
        while case .text(let text)? = result.last,
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func try2<T>(_ body: () throws -> T) -> T? {
        try? body()
    }
}

extension Element {
    fileprivate var ownTextTrimmed: String {
        (try? text()) ?? ownText()
    }
}
