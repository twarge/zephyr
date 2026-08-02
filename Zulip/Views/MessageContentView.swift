import AppKit
import QuickLook
import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipMath
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
    @Environment(\.colorScheme) private var colorScheme

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
            MathBlockView(tex: tex)
        case .thematicBreak:
            Divider()
        case .unimplemented:
            Label("Unsupported content", systemImage: "questionmark.square.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func inlineText(_ inlines: [InlineNode]) -> Text {
        InlineRenderer.text(inlines, realmURL: connection.realmURL, colorScheme: colorScheme)
    }
}

/// Display math, natively typeset from the TeX source; falls back to showing
/// the source when SwiftMath can't parse the expression.
private struct MathBlockView: View {
    let tex: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let rendered = ZulipMath.render(
            tex: tex, fontSize: 18,
            color: InlineRenderer.mathColor(for: colorScheme), display: true) {
            ScrollView(.horizontal) {
                Image(nsImage: rendered.image)
                    .padding(.vertical, 4)
            }
        } else {
            CodeBlockView(label: "TeX", code: tex)
        }
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
    @Environment(\.colorScheme) private var colorScheme

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
                        InlineRenderer.text(
                            header, realmURL: connection.realmURL, colorScheme: colorScheme)
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

/// An inline image: thumbnail loaded with the connection's auth header.
/// Single click selects (accent ring); Space quick-looks the full-size
/// original; double-click opens it in the default viewer (Preview).
private struct MessageImageView: View {
    let node: ImageNode
    let connection: ApiConnection

    @State private var image: NSImage?
    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?
    @FocusState private var isSelected: Bool

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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0))
        .focusable()
        .focused($isSelected)
        .focusEffectDisabled()
        .onTapGesture(count: 2) { openInDefaultViewer() }
        .onTapGesture { isSelected = true }
        .onKeyPress(.space) {
            guard isSelected else { return .ignored }
            quickLook()
            return .handled
        }
        .quickLookPreview($quickLookURL)
        .task(id: node.src) { await load() }
        .accessibilityLabel(node.alt ?? "Image")
        .help("Click to select, Space for Quick Look, double-click to open")
    }

    private func load() async {
        guard let (data, _) = await fetch(path: node.src) else { return }
        image = NSImage(data: data)
    }

    private func openInDefaultViewer() {
        Task {
            if let url = await downloadOriginal() {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func quickLook() {
        Task {
            quickLookURL = await downloadOriginal()
        }
    }

    /// Downloads the full-size original to a temp file (real filename, so
    /// Preview/Quick Look title it sensibly); cached per view.
    private func downloadOriginal() async -> URL? {
        if let localFileURL {
            return localFileURL
        }
        let path = node.originalSrc ?? node.src
        guard let (data, _) = await fetch(path: path) else { return nil }
        let filename = (path as NSString).lastPathComponent.removingPercentEncoding
            .flatMap { $0.isEmpty ? nil : $0 } ?? "image"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZulipPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(filename)
            try data.write(to: fileURL)
            localFileURL = fileURL
            return fileURL
        } catch {
            return nil
        }
    }

    /// mediaSession strips the auth header when the server redirects to a
    /// CDN (Zulip Cloud serves uploads from S3, which rejects basic auth).
    private func fetch(path: String) async -> (Data, URLResponse)? {
        let request: URLRequest?
        if path.hasPrefix("http") {
            request = URL(string: path).map { URLRequest(url: $0) }
        } else {
            request = try? connection.authorizedURLRequest(path: path)
        }
        guard let request else { return nil }
        return try? await ApiConnection.mediaSession.data(for: request)
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
        var isHighlight = false
    }

    static func text(_ inlines: [InlineNode], realmURL: URL, colorScheme: ColorScheme) -> Text {
        let builder = Builder(realmURL: realmURL, mathColor: mathColor(for: colorScheme))
        append(inlines, style: Style(), into: builder)
        return builder.finish()
    }

    /// Approximates the primary label color (math images bake their color at
    /// render time, so it's resolved per scheme and re-rendered on change).
    static func mathColor(for scheme: ColorScheme) -> NSColor {
        NSColor(white: scheme == .dark ? 1.0 : 0.0, alpha: 0.85)
    }

    /// Accumulates styled runs, flushing to `Text` segments whenever an
    /// inline math image interrupts the attributed text.
    final class Builder {
        let realmURL: URL
        let mathColor: NSColor
        private var segments: [Text] = []
        private var buffer = AttributedString()

        init(realmURL: URL, mathColor: NSColor) {
            self.realmURL = realmURL
            self.mathColor = mathColor
        }

        static func += (builder: Builder, attributed: AttributedString) {
            builder.buffer += attributed
        }

        func appendMath(_ tex: String, fallback: AttributedString) {
            if let rendered = ZulipMath.render(
                tex: tex, fontSize: 14, color: mathColor, display: false) {
                flush()
                segments.append(
                    Text(Image(nsImage: rendered.image))
                        .baselineOffset(-rendered.descent))
            } else {
                buffer += fallback
            }
        }

        private func flush() {
            if !buffer.characters.isEmpty {
                segments.append(Text(buffer))
                buffer = AttributedString()
            }
        }

        func finish() -> Text {
            flush()
            guard var result = segments.first else { return Text(verbatim: "") }
            for segment in segments.dropFirst() {
                result = result + segment
            }
            return result
        }
    }

    private static func append(
        _ inlines: [InlineNode], style: Style, into builder: Builder
    ) {
        for inline in inlines {
            switch inline {
            case .text(let text):
                builder += styled(text, style)
            case .lineBreak:
                builder += styled("\n", style)
            case .strong(let children):
                var nested = style
                nested.intents.insert(.stronglyEmphasized)
                append(children, style: nested, into: builder)
            case .emphasis(let children):
                var nested = style
                nested.intents.insert(.emphasized)
                append(children, style: nested, into: builder)
            case .strikethrough(let children):
                var nested = style
                nested.intents.insert(.strikethrough)
                append(children, style: nested, into: builder)
            case .inlineCode(let code):
                var nested = style
                nested.intents.insert(.code)
                builder += styled(code, nested)
            case .link(let link):
                var nested = style
                // Channel/topic/message links navigate in-app when parseable
                // (MainSplitView's OpenURLAction decodes the custom scheme).
                if link.kind != .plain,
                   let internalLink = InternalLink.parse(href: link.href, realmURL: builder.realmURL),
                   let appURL = internalLink.appURL {
                    nested.link = appURL
                } else {
                    nested.link = URL(string: link.href, relativeTo: builder.realmURL)?.absoluteURL
                }
                append(link.text, style: nested, into: builder)
            case .mention(let mention):
                var nested = style
                nested.isMention = !mention.silent
                builder += styled(mention.text, nested)
            case .emoji(.unicode(let character, _)):
                builder += styled(character, style)
            case .emoji(.realm(_, let name)):
                builder += styled(":\(name):", style)
            case .inlineMath(let tex):
                var nested = style
                nested.intents.insert(.code)
                builder.appendMath(tex, fallback: styled(tex, nested))
            case .highlight(let children):
                var nested = style
                nested.isHighlight = true
                append(children, style: nested, into: builder)
            case .globalTime(let datetime):
                let display = ISO8601DateFormatter().date(from: datetime)
                    .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? datetime
                var nested = style
                nested.isSecondary = true
                builder += styled("🕐\u{202f}\(display)", nested)
            case .unimplemented:
                var nested = style
                nested.isSecondary = true
                builder += styled("⟨unsupported⟩", nested)
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
        if style.isHighlight {
            attributed.backgroundColor = Color.yellow.opacity(0.4)
        }
        return attributed
    }
}
