import PDFKit
import SwiftUI
import ZulipAPI
import ZulipContent

/// Realm-upload PDF links in an inline run — each gets an inline preview
/// card below its paragraph (Zulip emits PDFs as bare links, no preview
/// markup, so this is client-side value-add).
func pdfAttachmentLinks(_ inlines: [InlineNode]) -> [LinkNode] {
    var out: [LinkNode] = []
    for node in inlines {
        switch node {
        case .link(let link):
            if link.href.lowercased().hasSuffix(".pdf"),
               link.href.contains("/user_uploads/") {
                out.append(link)
            }
        case .strong(let children), .emphasis(let children), .strikethrough(let children):
            out.append(contentsOf: pdfAttachmentLinks(children))
        default:
            break
        }
    }
    return out
}

/// First-page preview of an attached PDF, with the image affordances:
/// click selects, Space Quick Looks, double-click opens the default viewer.
struct PDFAttachmentView: View {
    let href: String
    let connection: ApiConnection

    @Environment(KeyboardRouter.self) private var keys: KeyboardRouter?
    @State private var thumbnail: PlatformImage?
    @State private var pageCount = 0
    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?

    private var filename: String {
        (href as NSString).lastPathComponent.removingPercentEncoding ?? "PDF"
    }

    private var mediaId: String { MessageAttachment.pdf(href: href).mediaId }

    /// The card takes the first page's real aspect ratio (the rendered
    /// thumbnail preserves it), fit within bounds; portrait-ish placeholder
    /// until the page loads.
    private var displaySize: CGSize {
        guard let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else {
            return CGSize(width: 200, height: 260)
        }
        let scale = min(300 / thumbnail.size.width, 300 / thumbnail.size.height)
        return CGSize(
            width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
    }

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
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let thumbnail {
                    Image(platform: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary.opacity(0.5))
                        Image(systemName: "doc.richtext")
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
                        selectionRing ?? Color.secondary.opacity(0.3),
                        lineWidth: selectionRing != nil ? 3 : 1))
            HStack(spacing: 5) {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(filename)
                    .font(.caption)
                    .lineLimit(1)
                if pageCount > 0 {
                    Text("· \(pageCount) page\(pageCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: displaySize.width)
        }
        .onTapGesture(count: 2) { openInDefaultViewer() }
        .simultaneousGesture(TapGesture().onEnded {
            keys?.selectMedia(mediaId) {
                Task { quickLookURL = await download() }
            }
        })
        .quickLookPreview($quickLookURL)
        .task(id: href) { await loadThumbnail() }
        .accessibilityLabel("PDF attachment: \(filename)")
        .help("Click to select, Space for Quick Look, double-click to open")
        // Drag out: the receiver gets the PDF file, real name intact.
        .onDrag { mediaDragProvider(path: href, connection: connection) }
    }

    private func loadThumbnail() async {
        guard let url = await download(), let document = PDFDocument(url: url) else { return }
        pageCount = document.pageCount
        if let page = document.page(at: 0) {
            thumbnail = page.thumbnail(of: CGSize(width: 400, height: 520), for: .cropBox)
        }
    }

    private func download() async -> URL? {
        if let localFileURL {
            return localFileURL
        }
        let url = await downloadMediaFile(path: href, connection: connection)
        localFileURL = url
        return url
    }

    private func openInDefaultViewer() {
        Task {
            if let url = await download(), !Platform.openFile(url) {
                quickLookURL = url
            }
        }
    }
}
