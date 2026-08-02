import AppKit
import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// Renders a parsed message AST natively: one view per block node, inline
/// runs as a single AttributedString per paragraph (ARCHITECTURE §5).
struct MessageContentView: View {
    let content: MessageContent
    let connection: ApiConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(content.blocks.indices, id: \.self) { index in
                BlockNodeView(block: content.blocks[index], connection: connection)
            }
        }
    }
}

struct BlockNodeView: View {
    let block: BlockNode
    let connection: ApiConnection

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            inlineText(inlines)
        case .heading(let level, let inlines):
            inlineText(inlines)
                .font(.system(size: CGFloat(20 - min(level, 4) * 2), weight: .bold))
        case .codeBlock(let language, let code):
            CodeBlockView(label: language, code: code)
        case .blockquote(let blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(blocks.indices, id: \.self) { index in
                        BlockNodeView(block: blocks[index], connection: connection)
                    }
                }
            }
        case .unorderedList(let items):
            ContentListView(items: items, connection: connection, marker: { _ in "•" })
        case .orderedList(let start, let items):
            ContentListView(items: items, connection: connection, marker: { "\(start + $0)." })
        case .spoiler(let header, let content):
            SpoilerView(header: header, content: content, connection: connection)
        case .image(let node):
            MessageImageView(node: node, connection: connection)
        case .mathBlock(let tex):
            CodeBlockView(label: "TeX", code: tex)
        case .thematicBreak:
            Divider()
        case .unimplemented:
            Label("Unsupported content", systemImage: "questionmark.square.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func inlineText(_ inlines: [InlineNode]) -> Text {
        Text(InlineRenderer.attributed(inlines, realmURL: connection.realmURL))
    }
}

private struct CodeBlockView: View {
    let label: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ContentListView: View {
    let items: [[BlockNode]]
    let connection: ApiConnection
    let marker: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(index))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items[index].indices, id: \.self) { blockIndex in
                            BlockNodeView(block: items[index][blockIndex], connection: connection)
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }
}

private struct SpoilerView: View {
    let header: [InlineNode]
    let content: [BlockNode]
    let connection: ApiConnection
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { revealed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: revealed ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    if header.isEmpty {
                        Text("Spoiler").italic()
                    } else {
                        Text(InlineRenderer.attributed(header, realmURL: connection.realmURL))
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if revealed {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(content.indices, id: \.self) { index in
                        BlockNodeView(block: content[index], connection: connection)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Loads `/user_uploads/…` thumbnails with the connection's auth header
/// (plain URLs load directly).
private struct MessageImageView: View {
    let node: ImageNode
    let connection: ApiConnection
    @State private var image: NSImage?

    private var displaySize: CGSize {
        let maxWidth: CGFloat = 320
        let maxHeight: CGFloat = 240
        guard let w = node.originalWidth, let h = node.originalHeight, w > 0, h > 0 else {
            return CGSize(width: 240, height: 160)
        }
        let scale = min(maxWidth / CGFloat(w), maxHeight / CGFloat(h), 1)
        return CGSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.5))
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: node.src) { await load() }
        .accessibilityLabel(node.alt ?? "Image")
    }

    private func load() async {
        // mediaSession strips the auth header when the server redirects to a
        // CDN (Zulip Cloud serves uploads from S3, which rejects basic auth).
        let src = node.src
        let request: URLRequest?
        if src.hasPrefix("http") {
            request = URL(string: src).map { URLRequest(url: $0) }
        } else {
            request = try? connection.authorizedURLRequest(path: src)
        }
        guard let request,
              let (data, _) = try? await ApiConnection.mediaSession.data(for: request)
        else { return }
        image = NSImage(data: data)
    }
}

/// Builds one AttributedString from an inline run, carrying style state
/// through nesting (bold/italic/strike/code via presentation intents,
/// links, mention tinting).
enum InlineRenderer {
    private struct Style {
        var intents: InlinePresentationIntent = []
        var link: URL?
        var isMention = false
        var isSecondary = false
    }

    static func attributed(_ inlines: [InlineNode], realmURL: URL) -> AttributedString {
        var out = AttributedString()
        append(inlines, style: Style(), realmURL: realmURL, into: &out)
        return out
    }

    private static func append(
        _ inlines: [InlineNode], style: Style, realmURL: URL, into out: inout AttributedString
    ) {
        for inline in inlines {
            switch inline {
            case .text(let text):
                out += styled(text, style)
            case .lineBreak:
                out += styled("\n", style)
            case .strong(let children):
                var nested = style
                nested.intents.insert(.stronglyEmphasized)
                append(children, style: nested, realmURL: realmURL, into: &out)
            case .emphasis(let children):
                var nested = style
                nested.intents.insert(.emphasized)
                append(children, style: nested, realmURL: realmURL, into: &out)
            case .strikethrough(let children):
                var nested = style
                nested.intents.insert(.strikethrough)
                append(children, style: nested, realmURL: realmURL, into: &out)
            case .inlineCode(let code):
                var nested = style
                nested.intents.insert(.code)
                out += styled(code, nested)
            case .link(let link):
                var nested = style
                // Channel/topic/message links navigate in-app when parseable
                // (MainSplitView's OpenURLAction decodes the custom scheme).
                if link.kind != .plain,
                   let internalLink = InternalLink.parse(href: link.href, realmURL: realmURL),
                   let appURL = internalLink.appURL {
                    nested.link = appURL
                } else {
                    nested.link = URL(string: link.href, relativeTo: realmURL)?.absoluteURL
                }
                append(link.text, style: nested, realmURL: realmURL, into: &out)
            case .mention(let mention):
                var nested = style
                nested.isMention = !mention.silent
                out += styled(mention.text, nested)
            case .emoji(.unicode(let character, _)):
                out += styled(character, style)
            case .emoji(.realm(_, let name)):
                out += styled(":\(name):", style)
            case .inlineMath(let tex):
                var nested = style
                nested.intents.insert(.code)
                out += styled(tex, nested)
            case .globalTime(let datetime):
                let display = ISO8601DateFormatter().date(from: datetime)
                    .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? datetime
                var nested = style
                nested.isSecondary = true
                out += styled("🕐\u{202f}\(display)", nested)
            case .unimplemented:
                var nested = style
                nested.isSecondary = true
                out += styled("⟨unsupported⟩", nested)
            }
        }
    }

    private static func styled(_ text: String, _ style: Style) -> AttributedString {
        var attributed = AttributedString(text)
        if !style.intents.isEmpty {
            attributed.inlinePresentationIntent = style.intents
        }
        if let link = style.link {
            attributed.link = link
        }
        if style.isMention {
            attributed.foregroundColor = .accentColor
            attributed.backgroundColor = Color.accentColor.opacity(0.12)
        }
        if style.isSecondary {
            attributed.foregroundColor = .secondary
        }
        return attributed
    }
}
