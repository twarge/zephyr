import Foundation

/// The typed AST for Zulip's server-rendered message HTML.
///
/// The HTML is a closed dialect (one server-side renderer produces it), so the
/// parser matches known structures exactly and folds anything unrecognized
/// into `.unimplemented` — rendered visibly, never silently dropped.
public struct MessageContent: Sendable, Equatable {
    public var blocks: [BlockNode]

    public init(blocks: [BlockNode]) {
        self.blocks = blocks
    }
}

public indirect enum BlockNode: Sendable, Equatable {
    case paragraph([InlineNode])
    case heading(level: Int, [InlineNode])
    /// `div.codehilite` — code kept as plain text for M1 (Pygments token
    /// colors are a later refinement).
    case codeBlock(language: String?, code: String)
    case blockquote([BlockNode])
    case unorderedList(items: [[BlockNode]])
    case orderedList(start: Int, items: [[BlockNode]])
    case spoiler(header: [InlineNode], content: [BlockNode])
    case image(ImageNode)
    case mathBlock(tex: String)
    case thematicBreak
    case unimplemented(html: String)
}

public indirect enum InlineNode: Sendable, Equatable {
    case text(String)
    case lineBreak
    case strong([InlineNode])
    case emphasis([InlineNode])
    case strikethrough([InlineNode])
    case inlineCode(String)
    case link(LinkNode)
    case mention(MentionNode)
    case emoji(EmojiNode)
    case inlineMath(tex: String)
    /// `<time datetime="…">` — rendered as a localized time chip.
    case globalTime(datetime: String)
    /// A search-match run (`span.highlight` in `match_content`).
    case highlight([InlineNode])
    case unimplemented(html: String)
}

public struct LinkNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case plain
        case channel(streamId: Int?)
        case channelTopic(streamId: Int?)
        case messageLink
    }

    public var text: [InlineNode]
    public var href: String
    public var kind: Kind
}

public struct MentionNode: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case user(id: Int?)
        case userGroup(id: Int?)
        case channelWildcard
        case topicWildcard
    }

    public var text: String
    public var target: Target
    public var silent: Bool
}

public enum EmojiNode: Sendable, Equatable {
    /// Resolved to the actual character sequence (from the `emoji-…` class's
    /// hex codepoints), plus the shortcode name for accessibility.
    case unicode(String, name: String)
    /// Realm custom emoji: an image at `src` (realm-relative).
    case realm(src: String, name: String)
}

public struct ImageNode: Sendable, Equatable {
    public var src: String
    public var originalSrc: String?
    public var alt: String?
    public var originalWidth: Int?
    public var originalHeight: Int?
}

extension MessageContent {
    /// Best-effort plain-text flattening, for sidebar snippets and
    /// notifications.
    public var plainText: String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension BlockNode {
    var plainText: String {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            inlines.map(\.plainText).joined()
        case .codeBlock(_, let code):
            code.replacingOccurrences(of: "\n", with: " ")
        case .blockquote(let blocks):
            blocks.map(\.plainText).joined(separator: " ")
        case .unorderedList(let items), .orderedList(_, let items):
            items.map { $0.map(\.plainText).joined(separator: " ") }.joined(separator: " ")
        case .spoiler(let header, _):
            header.map(\.plainText).joined()
        case .image:
            "🖼️"
        case .mathBlock(let tex):
            tex
        case .thematicBreak:
            ""
        case .unimplemented:
            ""
        }
    }
}

extension InlineNode {
    var plainText: String {
        switch self {
        case .text(let text): text
        case .lineBreak: " "
        case .strong(let children), .emphasis(let children), .strikethrough(let children),
             .highlight(let children):
            children.map(\.plainText).joined()
        case .inlineCode(let code): code
        case .link(let link): link.text.map(\.plainText).joined()
        case .mention(let mention): mention.text
        case .emoji(.unicode(let character, _)): character
        case .emoji(.realm(_, let name)): ":\(name):"
        case .inlineMath(let tex): tex
        case .globalTime(let datetime): datetime
        case .unimplemented: ""
        }
    }
}
