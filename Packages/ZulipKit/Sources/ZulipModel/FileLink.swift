import Foundation
import UniformTypeIdentifiers

/// Classifies a clicked link by what the browser would do with it: render
/// it as a page, or merely save it as a file — in which case Zephyr should
/// download it in-app instead of bouncing through the browser.
public enum FileLink: Sendable {
    /// Plainly a file the browser would only save (archive, disk image,
    /// office document, CSV…) — download it in-app.
    case download
    /// The browser renders it (page, prose/source text, image,
    /// audio/video, PDF) — open it there.
    case page
    /// A file-looking extension the type system doesn't know (.dat,
    /// .npz…) — only the server can say which it is.
    case ambiguous

    /// Types the browser shows in place rather than saves. `.text` covers
    /// prose and source code; its data-file members (CSV/TSV) are carved
    /// back out in `classify`.
    private static let rendered: [UTType] = [.html, .text, .image, .audiovisualContent, .pdf]

    /// Server-side page generators: unknown to the type system, but their
    /// URLs are always pages.
    private static let pageGenerators: Set<String> = ["asp", "aspx", "jsp", "jspx", "cgi", "cfm", "do"]

    public static func classify(_ url: URL) -> FileLink {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return .page }
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .page }
        if let type = UTType(filenameExtension: ext), !type.isDynamic {
            if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText) {
                return .download
            }
            return rendered.contains { type.conforms(to: $0) } ? .page : .download
        }
        // Unknown extension. A digit-leading "extension" is a version
        // number in the path (…/v1.2), not a file.
        guard ext.first?.isLetter == true, !pageGenerators.contains(ext) else { return .page }
        return .ambiguous
    }
}
