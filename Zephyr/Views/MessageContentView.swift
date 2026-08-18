#if canImport(AppKit)
import AppKit
#endif
import os
import QuickLook
import SwiftUI
import Synchronization
import UniformTypeIdentifiers
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
        // Message text is selectable/copyable (propagates to every Text in
        // the content tree; row click-to-select still works — that's a tap,
        // selection is a drag).
        .textSelection(.enabled)
    }
}

struct BlockNodeView: View {
    let block: BlockNode
    let connection: ApiConnection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            let pdfs = pdfAttachmentLinks(inlines)
            if pdfs.isEmpty {
                inlineText(inlines)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    inlineText(inlines)
                    ForEach(pdfs, id: \.href) { link in
                        PDFAttachmentView(href: link.href, connection: connection)
                    }
                }
            }
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
                .onAppear {
                    ContentDiagnostics.logUnimplemented(html)
                }
        }
    }

    private func inlineText(_ inlines: [InlineNode]) -> Text {
        InlineRenderer.text(inlines, connection: connection, colorScheme: colorScheme)
    }
}

#if os(macOS)
/// Shows the given SwiftUI menu for right-clicks anywhere over the view it
/// overlays. Selectable Text's AppKit backing consumes right-clicks and
/// substitutes the system edit menu for any ancestor `.contextMenu`; this
/// sits above it and claims only right-clicks (and control-clicks) — left
/// clicks, selection drags, link clicks, and scrolling pass through.
struct RightClickMenu<MenuItems: View>: NSViewRepresentable {
    @ViewBuilder var items: () -> MenuItems

    func makeNSView(context: Context) -> InterceptView {
        InterceptView()
    }

    func updateNSView(_ view: InterceptView, context: Context) {
        let items = items
        view.menuProvider = { NSHostingMenu(rootView: Group(content: items)) }
    }

    final class InterceptView: NSView {
        var menuProvider: (() -> NSMenu)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard super.hitTest(point) === self,
                  let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return self
            case .leftMouseDown, .leftMouseUp:
                return event.modifierFlags.contains(.control) ? self : nil
            default:
                return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuProvider?()
        }

        // Control-click: AppKit's default mouseDown shows no menu.
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = menuProvider?() {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}
#endif

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

    @Environment(KeyboardRouter.self) private var keys: KeyboardRouter?
    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?

    private var filename: String {
        (path as NSString).lastPathComponent.removingPercentEncoding ?? kind
    }

    private var mediaId: String { MessageAttachment.chip(path: path).mediaId }

    /// Full accent for the anchor, lighter for extended members.
    private var selectionRing: Color? {
        guard let keys else { return nil }
        if keys.selectedMediaId == mediaId { return .accentColor }
        if keys.selectedMediaIds.contains(mediaId) {
            return Color.accentColor.opacity(0.45)
        }
        return nil
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
                .strokeBorder(
                    selectionRing ?? .clear, lineWidth: selectionRing != nil ? 3 : 0))
        .onTapGesture(count: 2) {
            Task {
                if let url = await download(), !Platform.openFile(url) {
                    quickLookURL = url
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            keys?.selectMedia(mediaId) {
                Task { quickLookURL = await download() }
            }
        })
        .quickLookPreview($quickLookURL)
        // Drag out: the receiver gets the file, real name intact.
        .onDrag { mediaDragProvider(path: path, connection: connection) }
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

/// One selectable/previewable attachment of a message. The id builders are
/// the single source of truth shared by the rendering views (which draw the
/// selection ring for a matching `KeyboardRouter.selectedMediaId`) and the
/// keyboard-traversal list below.
struct MessageAttachment: Equatable {
    let mediaId: String
    /// Server path of the previewable file (the original for images).
    let path: String

    static func image(_ node: ImageNode) -> MessageAttachment {
        MessageAttachment(
            mediaId: "img:\(node.src)|\(node.originalSrc ?? "")",
            path: node.originalSrc ?? node.src)
    }

    static func pdf(href: String) -> MessageAttachment {
        MessageAttachment(mediaId: "pdf:\(href)", path: href)
    }

    static func chip(path: String) -> MessageAttachment {
        MessageAttachment(mediaId: "chip:\(path)", path: path)
    }

    /// A message's attachments in render order — the ←/→ traversal and
    /// whole-message Quick Look set. Mirrors BlockNodeView's cases.
    /// Spoiler/collapsible content stays out: it's hidden until revealed,
    /// and neither traversal nor preview should leak it.
    static func list(in content: MessageContent) -> [MessageAttachment] {
        list(in: content.blocks)
    }

    private static func list(in blocks: [BlockNode]) -> [MessageAttachment] {
        var out: [MessageAttachment] = []
        for block in blocks {
            switch block {
            case .paragraph(let inlines):
                out.append(contentsOf: pdfAttachmentLinks(inlines).map { .pdf(href: $0.href) })
            case .image(let node):
                out.append(.image(node))
            case .imageGallery(let images):
                out.append(contentsOf: images.map { .image($0) })
            case .video(let node) where !node.isEmbed:
                out.append(.chip(path: node.href))
            case .audio(let src):
                out.append(.chip(path: src))
            case .blockquote(let nested):
                out.append(contentsOf: list(in: nested))
            case .unorderedList(let items), .orderedList(_, let items):
                for item in items {
                    out.append(contentsOf: list(in: item))
                }
            default:
                break
            }
        }
        return out
    }
}

/// Fetches a media path (realm-relative with auth, or absolute) via the
/// redirect-stripping media session. Absolute URLs on the connection's own
/// realm are authenticated too — attachment links arrive fully resolved,
/// and their downloads need auth just like relative paths do.
func fetchMedia(path: String, connection: ApiConnection) async -> (Data, URLResponse)? {
    let request: URLRequest?
    if path.hasPrefix("http") {
        request = URL(string: path).map { connection.authorizedURLRequest(url: $0) }
    } else {
        request = try? connection.authorizedURLRequest(path: path)
    }
    guard let request else { return nil }
    return try? await ApiConnection.mediaSession.data(for: request)
}

/// A drag payload for message attachments: an item provider promising the
/// downloaded file under its real filename and content type. (Transferable's
/// FileRepresentation names drops after the exported content type — a
/// dragged image landed in Finder as "data".)
@MainActor
func mediaDragProvider(path: String, connection: ApiConnection) -> NSItemProvider {
    let filename = (path as NSString).lastPathComponent.removingPercentEncoding
        .flatMap { $0.isEmpty ? nil : $0 } ?? "file"
    let contentType = UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    let provider = NSItemProvider()
    // The receiver appends the content type's extension to suggestedName
    // itself — suggesting the full "image.png" landed as "image.png.png".
    // Only when the type is a known one, though: bare .data appends
    // nothing, so unknown extensions keep the full name.
    provider.suggestedName = contentType == .data
        ? filename : (filename as NSString).deletingPathExtension
    provider.registerFileRepresentation(
        for: contentType, visibility: .all
    ) { completion in
        // NSItemProvider completion blocks are callable from any thread.
        nonisolated(unsafe) let complete = completion
        Task.detached {
            if let url = await downloadMediaFile(path: path, connection: connection) {
                complete(url, false, nil)
            } else {
                complete(nil, false, CocoaError(.fileNoSuchFile))
            }
        }
        return nil
    }
    return provider
}

/// Downloaded media files by source path, so gallery navigation and repeat
/// previews don't re-fetch.
private let mediaFileCache = Mutex<[String: URL]>([:])

/// Downloads media to a temp file with its real filename (so Preview/Quick
/// Look title it sensibly). Cached per source path.
func downloadMediaFile(path: String, connection: ApiConnection) async -> URL? {
    if let cached = mediaFileCache.withLock({ $0[path] }),
       FileManager.default.fileExists(atPath: cached.path) {
        return cached
    }
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
        mediaFileCache.withLock { $0[path] = fileURL }
        return fileURL
    } catch {
        return nil
    }
}

/// Feed-wide Quick Look: one preview session per transcript, holding every
/// nearby image so the panel's arrow keys navigate between them.
@MainActor
@Observable
final class FeedQuickLook {
    var items: [URL] = []
    var selection: URL?
    /// Supplied by the feed: all image nodes in transcript order.
    @ObservationIgnored var orderedNodes: () -> [ImageNode] = { [] }

    /// Downloads the focused image plus up to 20 neighbors on each side,
    /// then presents with the panel focused on the requested image.
    func present(_ node: ImageNode, connection: ApiConnection) async {
        let all = orderedNodes()
        let focusIndex = all.firstIndex {
            $0.src == node.src && $0.originalSrc == node.originalSrc
        }
        let window: [ImageNode]
        if let focusIndex {
            window = Array(all[max(0, focusIndex - 20)...min(all.count - 1, focusIndex + 20)])
        } else {
            window = [node]
        }
        let paths = window.map { $0.originalSrc ?? $0.src }
        let focusPathIndex = paths.firstIndex(of: node.originalSrc ?? node.src) ?? 0
        await present(paths: paths, focusIndex: focusPathIndex, connection: connection)
    }

    /// Downloads and presents an explicit attachment set (one message's),
    /// panel focused at `focusIndex`.
    func present(paths: [String], focusIndex: Int, connection: ApiConnection) async {
        var downloaded: [Int: URL] = [:]
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, path) in paths.enumerated() {
                group.addTask {
                    (index, await downloadMediaFile(path: path, connection: connection))
                }
            }
            for await (index, url) in group {
                downloaded[index] = url
            }
        }
        let ordered = paths.indices.compactMap { downloaded[$0] }
        guard !ordered.isEmpty else { return }
        items = ordered
        selection = downloaded[focusIndex] ?? ordered.first
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
/// Multi-frame image (GIF, animated WebP/PNG) decoded for native playback.
struct AnimatedFrames {
    let images: [CGImage]
    let delays: [Double]
    let totalDuration: Double

    static func load(_ data: Data) -> AnimatedFrames? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1 else { return nil }
        var images: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil)
            else { continue }
            images.append(cgImage)
            delays.append(Self.delay(source, index))
        }
        guard images.count > 1 else { return nil }
        return AnimatedFrames(
            images: images, delays: delays,
            totalDuration: max(delays.reduce(0, +), 0.1))
    }

    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        else { return 0.1 }
        for dictionaryKey in [
            kCGImagePropertyGIFDictionary, kCGImagePropertyWebPDictionary,
            kCGImagePropertyPNGDictionary,
        ] {
            guard let sub = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let value = sub[kCGImagePropertyGIFUnclampedDelayTime]
                ?? sub[kCGImagePropertyWebPUnclampedDelayTime]
                ?? sub[kCGImagePropertyAPNGUnclampedDelayTime]
                ?? sub[kCGImagePropertyGIFDelayTime]
                ?? sub[kCGImagePropertyWebPDelayTime]
                ?? sub[kCGImagePropertyAPNGDelayTime]
            if let delay = value as? Double, delay > 0.011 {
                return delay
            }
            return 0.1
        }
        return 0.1
    }

    func frame(at time: Double) -> CGImage {
        var remaining = time.truncatingRemainder(dividingBy: totalDuration)
        for (index, delay) in delays.enumerated() {
            if remaining < delay {
                return images[index]
            }
            remaining -= delay
        }
        return images[0]
    }
}

/// Plays an AnimatedFrames sequence, honoring per-frame delays.
struct AnimatedImageView: View {
    let frames: AnimatedFrames
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            Image(
                decorative: frames.frame(at: context.date.timeIntervalSince(start)),
                scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}

private struct MessageImageView: View {
    let node: ImageNode
    let connection: ApiConnection
    var compact = false

    @Environment(FeedQuickLook.self) private var feedQuickLook: FeedQuickLook?
    @Environment(KeyboardRouter.self) private var keys: KeyboardRouter?
    @State private var image: PlatformImage?
    @State private var animation: AnimatedFrames?
    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?

    private var mediaId: String { MessageAttachment.image(node).mediaId }

    /// Selection lives in the router on both platforms (it survives row
    /// re-renders, which were killing FocusState a beat after each click).
    /// Full accent for the anchor, lighter for extended members.
    private var selectionRing: Color? {
        guard let keys else { return nil }
        if keys.selectedMediaId == mediaId { return .accentColor }
        if keys.selectedMediaIds.contains(mediaId) {
            return Color.accentColor.opacity(0.45)
        }
        return nil
    }

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
            if let animation {
                AnimatedImageView(frames: animation)
            } else if let image {
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
                .strokeBorder(
                    selectionRing ?? .clear, lineWidth: selectionRing != nil ? 3 : 0))
        .onTapGesture(count: 2) { openInDefaultViewer() }
        // Simultaneous: fires on the first click immediately — a plain tap
        // gesture would wait out the double-click window.
        .simultaneousGesture(TapGesture().onEnded {
            keys?.selectMedia(mediaId) { quickLook() }
        })
        .quickLookPreview($quickLookURL)
        .task(id: node.src) { await load() }
        .accessibilityLabel(node.alt ?? "Image")
        .help("Click to select, Space for Quick Look, double-click to open")
        // Drag out: the receiver gets the original file, real name intact.
        .onDrag { mediaDragProvider(path: node.originalSrc ?? node.src, connection: connection) }
    }

    private func load() async {
        // Skip the server's transient thumbnailing placeholder (an SVG
        // loader graphic); go straight to the original below.
        if !node.src.hasPrefix("/static/images/loading"),
           let (data, _) = await fetchMedia(path: node.src, connection: connection),
           let decoded = PlatformImage(data: data) {
            image = decoded
            animation = AnimatedFrames.load(data)
            return
        }
        // Thumbnail missing or undecodable: fall back to the original.
        // ImageIO decodes HEIC/AVIF/TIFF locally even where a browser
        // (and hence the server's preview pipeline) wouldn't.
        if let original = node.originalSrc, original != node.src,
           let (data, _) = await fetchMedia(path: original, connection: connection),
           let decoded = PlatformImage(data: data) {
            image = decoded
            animation = AnimatedFrames.load(data)
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
        // Feed-provided session: the panel gets neighbors too, so its
        // arrow keys move between the view's images.
        if let feedQuickLook {
            Task { await feedQuickLook.present(node, connection: connection) }
            return
        }
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

/// Rendering unsupported content logs the offending HTML, so a report of
/// "⟨unsupported⟩" is diagnosable from `log show --predicate
/// 'subsystem == "com.twarge.zephyr"'` without needing the message itself.
enum ContentDiagnostics {
    private static let logger = Logger(subsystem: "com.twarge.zephyr", category: "content")
    @MainActor private static var logged: Set<String> = []

    @MainActor static func logUnimplemented(_ html: String) {
        // Once per distinct markup per session.
        guard logged.insert(html).inserted else { return }
        logger.error("unimplemented content: \(html, privacy: .public)")
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
            case .unimplemented(let html):
                ContentDiagnostics.logUnimplemented(html)
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
