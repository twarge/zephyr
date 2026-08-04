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
        case .codeBlock(let language, let spans):
            CodeBlockView(label: language, spans: spans)
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
        case .collapsible(let summary, let content):
            SpoilerView(header: summary, content: content, connection: connection)
        case .image(let node):
            MessageImageView(node: node, connection: connection)
        case .imageGallery(let images):
            ImageGalleryView(images: images, connection: connection)
        case .video(let node):
            MessageVideoView(node: node, connection: connection)
        case .audio(let src):
            MediaAttachmentChip(
                path: src, connection: connection, icon: "waveform",
                kind: "Audio")
        case .table(let table):
            MessageTableView(table: table, connection: connection)
        case .linkPreview(let preview):
            LinkPreviewCard(preview: preview, connection: connection)
        case .mathBlock(let tex):
            MathBlockView(tex: tex)
        case .thematicBreak:
            Divider()
        case .unimplemented(let html):
            Label("Unsupported content", systemImage: "questionmark.square.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
                // Diagnosis affordance: the raw HTML names what's missing.
                .contextMenu {
                    Button("Copy Raw HTML", systemImage: "doc.on.doc") {
                        Platform.copyToPasteboard(html)
                    }
                }
        }
    }

    private func inlineText(_ inlines: [InlineNode]) -> Text {
        InlineRenderer.text(inlines, connection: connection, colorScheme: colorScheme)
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
                Image(platform: rendered.image)
                    .padding(.vertical, 4)
            }
        } else {
            CodeBlockView(label: "TeX", code: tex)
        }
    }
}

private struct CodeBlockView: View {
    let label: String?
    let spans: [CodeSpan]

    init(label: String?, spans: [CodeSpan]) {
        self.label = label
        self.spans = spans
    }

    init(label: String?, code: String) {
        self.init(label: label, spans: [CodeSpan(text: code)])
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        for span in spans {
            var run = AttributedString(span.text)
            if let color = Self.tokenColor(span.tokenClass) {
                run.foregroundColor = color
            }
            out += run
        }
        return out
    }

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
                Text(attributed)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Pygments short token classes → semantic colors (Xcode-ish palette;
    /// adaptive system colors work in both appearances).
    static func tokenColor(_ tokenClass: String?) -> Color? {
        guard let tokenClass else { return nil }
        switch tokenClass.first {
        case "k":  // keywords: k, kc, kd, kn, kp, kr, kt
            return .pink
        case "s":  // strings: s, s1, s2, sb, sc, sd, si, sr, ss, …
            return .red
        case "c":  // comments: c, c1, cm, cp, cs, ch
            return .gray
        case "m":  // numbers: m, mi, mf, mh, mo, mb
            return .blue
        case "n":  // names — only the interesting subtypes get color
            switch tokenClass {
            case "nf", "nc", "nn":  // function/class/namespace
                return .teal
            case "nb", "nd", "nt":  // builtin/decorator/tag
                return .indigo
            default:
                return nil
            }
        case "o":  // operators
            return nil
        case "b":  // bp (builtin pseudo: self, True…)
            return tokenClass == "bp" ? .indigo : nil
        case "i":  // il (long int literal)
            return tokenClass == "il" ? .blue : nil
        default:
            return nil
        }
    }
}

/// Consecutive image previews in an adaptive grid.
private struct ImageGalleryView: View {
    let images: [ImageNode]
    let connection: ApiConnection

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 6)],
            alignment: .leading, spacing: 6
        ) {
            ForEach(images.indices, id: \.self) { index in
                MessageImageView(node: images[index], connection: connection, compact: true)
            }
        }
        .frame(maxWidth: 480)
    }
}

/// Markdown tables as a native Grid, honoring per-column alignment.
private struct MessageTableView: View {
    let table: TableNode
    let connection: ApiConnection
    @Environment(\.colorScheme) private var colorScheme

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[safe: column] ?? nil {
        case .center: .center
        case .right: .trailing
        case .left, nil: .leading
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    ForEach(table.headerCells.indices, id: \.self) { column in
                        InlineRenderer.text(
                            table.headerCells[column], connection: connection,
                            colorScheme: colorScheme)
                            .bold()
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(table.rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(table.rows[rowIndex].indices, id: \.self) { column in
                            InlineRenderer.text(
                                table.rows[rowIndex][column], connection: connection,
                                colorScheme: colorScheme)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A website preview card (`message_embed`): thumbnail, linked title,
/// description.
private struct LinkPreviewCard: View {
    let preview: LinkPreviewNode
    let connection: ApiConnection
    @State private var thumbnail: PlatformImage?

    private var destination: URL? {
        URL(string: preview.url, relativeTo: connection.realmURL)?.absoluteURL
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if preview.imageSrc != nil {
                Group {
                    if let thumbnail {
                        Image(platform: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary.opacity(0.5))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 3) {
                if let title = preview.title, let destination {
                    Link(title, destination: destination)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                } else if let title = preview.title {
                    Text(title).font(.callout.weight(.semibold))
                }
                if let description = preview.descriptionText {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .task(id: preview.imageSrc) {
            guard let src = preview.imageSrc else { return }
            guard let (data, _) = await fetchMedia(path: src, connection: connection) else { return }
            thumbnail = PlatformImage(data: data)
        }
    }
}

/// Uploaded videos get an openable chip; embeds (YouTube…) show their
/// preview frame linking out.
private struct MessageVideoView: View {
    let node: VideoNode
    let connection: ApiConnection
    @State private var preview: PlatformImage?

    var body: some View {
        if node.isEmbed {
            embedBody
        } else {
            MediaAttachmentChip(
                path: node.href, connection: connection, icon: "film", kind: "Video")
        }
    }

    private var embedBody: some View {
        Button {
            if let url = URL(string: node.href) {
                Platform.openExternalURL(url)
            }
        } label: {
            ZStack {
                Group {
                    if let preview {
                        Image(platform: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary.opacity(0.5))
                    }
                }
                .frame(width: 280, height: 158)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 4)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(node.href)
        .task(id: node.previewImageSrc) {
            guard let src = node.previewImageSrc else { return }
            guard let (data, _) = await fetchMedia(path: src, connection: connection) else { return }
            preview = PlatformImage(data: data)
        }
    }
}

/// A file-attachment chip (uploaded video/audio): select, Space to Quick
/// Look (which plays media), double-click to open in the default app.
private struct MediaAttachmentChip: View {
    let path: String
    let connection: ApiConnection
    let icon: String
    let kind: String

    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?
    @FocusState private var isSelected: Bool

    private var filename: String {
        (path as NSString).lastPathComponent.removingPercentEncoding ?? kind
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(filename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(kind) — Space to preview, double-click to open")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0))
        .focusable()
        .focused($isSelected)
        .focusEffectDisabled()
        .onTapGesture(count: 2) {
            Task {
                if let url = await download(), !Platform.openFile(url) {
                    quickLookURL = url
                }
            }
        }
        .onTapGesture { isSelected = true }
        .onKeyPress(.space) {
            guard isSelected else { return .ignored }
            Task { quickLookURL = await download() }
            return .handled
        }
        .quickLookPreview($quickLookURL)
    }

    private func download() async -> URL? {
        if let localFileURL {
            return localFileURL
        }
        let url = await downloadMediaFile(path: path, connection: connection)
        localFileURL = url
        return url
    }
}

/// Fetches a media path (realm-relative with auth, or absolute) via the
/// redirect-stripping media session.
func fetchMedia(path: String, connection: ApiConnection) async -> (Data, URLResponse)? {
    let request: URLRequest?
    if path.hasPrefix("http") {
        request = URL(string: path).map { URLRequest(url: $0) }
    } else {
        request = try? connection.authorizedURLRequest(path: path)
    }
    guard let request else { return nil }
    return try? await ApiConnection.mediaSession.data(for: request)
}

/// Downloads media to a temp file with its real filename (so Preview/Quick
/// Look title it sensibly).
func downloadMediaFile(path: String, connection: ApiConnection) async -> URL? {
    guard let (data, _) = await fetchMedia(path: path, connection: connection) else { return nil }
    let filename = (path as NSString).lastPathComponent.removingPercentEncoding
        .flatMap { $0.isEmpty ? nil : $0 } ?? "file"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZephyrPreviews", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    } catch {
        return nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
                            header, connection: connection, colorScheme: colorScheme)
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
    var compact = false

    @State private var image: PlatformImage?
    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?
    @FocusState private var isSelected: Bool

    private var displaySize: CGSize {
        if compact {
            return CGSize(width: 150, height: 110)
        }
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
                Image(platform: image)
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
        // Skip the server's transient thumbnailing placeholder (an SVG
        // loader graphic); go straight to the original below.
        if !node.src.hasPrefix("/static/images/loading"),
           let (data, _) = await fetchMedia(path: node.src, connection: connection),
           let decoded = PlatformImage(data: data) {
            image = decoded
            return
        }
        // Thumbnail missing or undecodable: fall back to the original.
        // ImageIO decodes HEIC/AVIF/TIFF locally even where a browser
        // (and hence the server's preview pipeline) wouldn't.
        if let original = node.originalSrc, original != node.src,
           let (data, _) = await fetchMedia(path: original, connection: connection),
           let decoded = PlatformImage(data: data) {
            image = decoded
        }
    }

    private func openInDefaultViewer() {
        Task {
            if let url = await downloadOriginal(), !Platform.openFile(url) {
                quickLookURL = url
            }
        }
    }

    private func quickLook() {
        Task {
            quickLookURL = await downloadOriginal()
        }
    }

    private func downloadOriginal() async -> URL? {
        if let localFileURL {
            return localFileURL
        }
        let url = await downloadMediaFile(
            path: node.originalSrc ?? node.src, connection: connection)
        localFileURL = url
        return url
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

    static func text(
        _ inlines: [InlineNode], connection: ApiConnection, colorScheme: ColorScheme
    ) -> Text {
        let builder = Builder(connection: connection, mathColor: mathColor(for: colorScheme))
        append(inlines, style: Style(), into: builder)
        return builder.finish()
    }

    /// Approximates the primary label color (math images bake their color at
    /// render time, so it's resolved per scheme and re-rendered on change).
    static func mathColor(for scheme: ColorScheme) -> MathColor {
        MathColor(white: scheme == .dark ? 1.0 : 0.0, alpha: 0.85)
    }

    /// Accumulates styled runs, flushing to `Text` segments whenever an
    /// inline math image interrupts the attributed text.
    final class Builder {
        let connection: ApiConnection
        let mathColor: MathColor
        private var segments: [Text] = []
        private var buffer = AttributedString()

        var realmURL: URL { connection.realmURL }

        init(connection: ApiConnection, mathColor: MathColor) {
            self.connection = connection
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
                    Text(Image(platform: rendered.image))
                        .baselineOffset(-rendered.descent))
            } else {
                buffer += fallback
            }
        }

        func appendEmojiImage(src: String, fallback: AttributedString) {
            if let image = EmojiImageLoader.shared.image(src: src, connection: connection) {
                flush()
                segments.append(Text(Image(platform: image)).baselineOffset(-3))
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
                // Text interpolation is the non-deprecated concatenation.
                result = Text("\(result)\(segment)")
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
            case .emoji(.realm(let src, let name)):
                builder.appendEmojiImage(src: src, fallback: styled(":\(name):", style))
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
