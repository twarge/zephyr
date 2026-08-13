import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Staging

/// Media that arrives by paste or drag without a file behind it — raw
/// image data from screenshots, browser images, and apps that drag a
/// rendered image rather than a file (Instruments, chart tools). Staged
/// into a temp PNG so it rides the same upload-and-link path as a real
/// file.
enum MediaStaging {
    #if canImport(AppKit)
    /// PNG from a general or dragging pasteboard (image sources favor
    /// PNG or TIFF).
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
    }
    #else
    /// PNG from dropped image bytes of whatever format the source sent.
    static func pngData(fromImage data: Data) -> Data? {
        UIImage(data: data)?.pngData()
    }
    #endif

    /// Writes raw data into a fresh staging directory. No spaces in the
    /// filename: it ends up inside a markdown link URL, and raw spaces
    /// break Zulip's link parsing (and the server preview).
    static func stage(_ data: Data, extension ext: String, prefix: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        guard let directory = freshDirectory() else { return nil }
        let fileURL = directory
            .appendingPathComponent("\(prefix)-\(formatter.string(from: .now)).\(ext)")
        do {
            try data.write(to: fileURL)
        } catch {
            return nil
        }
        return fileURL
    }

    /// A unique temp directory per staged item or promise batch, so
    /// same-second stagings and same-named promised files never collide.
    static func freshDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZephyrMedia", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }
}

// MARK: - Drop target

extension View {
    /// Accepts media dragged in from other apps. Drags arrive in four
    /// shapes: real file URLs (Finder), file *promises* (Photos, Safari,
    /// Mail — the source writes the file only once someone accepts), raw
    /// image or PDF data with no file behind it (rendered-image drags),
    /// and bare web links (a page link or address bar — these insert
    /// into the draft via `onText` rather than uploading a .webloc).
    /// SwiftUI's `dropDestination` can express only the first, so macOS
    /// uses an AppKit catcher; the other platforms go through a
    /// Transferable.
    ///
    /// Plain-*text* drags are deliberately not taken: this layer sits in
    /// front of the compose editor, so claiming them would break native
    /// caret-position drops into the editor and turn an intra-editor
    /// drag-to-move into delete-and-append. Text dropped directly on the
    /// editor already inserts natively.
    func mediaDropTarget(
        isTargeted: Binding<Bool>? = nil,
        canAccept: @escaping () -> Bool = { true },
        onText: ((String) -> Void)? = nil,
        onFiles: @escaping ([URL]) -> Void
    ) -> some View {
        #if canImport(AppKit)
        overlay {
            MediaDropCatcher(
                canAccept: canAccept, isTargeted: isTargeted,
                onText: onText, onFiles: onFiles)
            .allowsHitTesting(false)
        }
        #else
        dropDestination(for: DroppedMedia.self) { items, _ in
            guard canAccept() else { return false }
            var files: [URL] = []
            var links: [String] = []
            for item in items {
                switch item {
                case .file(let url):
                    files.append(url)
                case .image(let data):
                    if let png = MediaStaging.pngData(fromImage: data),
                       let staged = MediaStaging.stage(
                        png, extension: "png", prefix: "Dropped") {
                        files.append(staged)
                    }
                case .pdf(let data):
                    if let staged = MediaStaging.stage(
                        data, extension: "pdf", prefix: "Dropped") {
                        files.append(staged)
                    }
                case .link(let url):
                    if !url.isFileURL { links.append(url.absoluteString) }
                }
            }
            if !files.isEmpty { onFiles(files) }
            if let onText, !links.isEmpty { onText(links.joined(separator: "\n")) }
            return !files.isEmpty || (onText != nil && !links.isEmpty)
        } isTargeted: { targeted in
            isTargeted?.wrappedValue = targeted
        }
        #endif
    }
}

#if canImport(AppKit)
/// Invisible AppKit layer receiving the drops `dropDestination` can't.
/// Drops route here through AppKit's registered-types walk, which
/// ignores `hitTest` — returning nil keeps every click, drag, and
/// scroll passing through to the SwiftUI content beneath.
private struct MediaDropCatcher: NSViewRepresentable {
    var canAccept: () -> Bool
    var isTargeted: Binding<Bool>?
    var onText: ((String) -> Void)?
    var onFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes
                .map { NSPasteboard.PasteboardType($0) }
                + [.fileURL, .png, .tiff, .pdf, .URL])
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.canAccept = canAccept
        view.onText = onText
        view.onFiles = onFiles
        let isTargeted = isTargeted
        view.onTargeted = { isTargeted?.wrappedValue = $0 }
    }

    final class CatcherView: NSView {
        var canAccept: () -> Bool = { true }
        var onText: ((String) -> Void)?
        var onFiles: ([URL]) -> Void = { _ in }
        var onTargeted: (Bool) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard canAccept(), readable(sender.draggingPasteboard) else { return [] }
            onTargeted(true)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargeted(false)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargeted(false)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onTargeted(false)
            let pasteboard = sender.draggingPasteboard
            // Real files first; then promises (the promised file keeps
            // its own name); then raw image/PDF data staged into a temp
            // file; bare web links last, inserted as draft text.
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                onFiles(urls)
                return true
            }
            // Link drags (Safari page links, address bars) also promise a
            // .webloc; those fall through to the link path below instead
            // of uploading a bookmark file.
            let receivers = ((pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver]) ?? [])
                .filter { receiver in
                    let types = receiver.fileTypes.compactMap { UTType($0) }
                    return types.isEmpty
                        || types.contains { !$0.conforms(to: .internetLocation) }
                }
            if !receivers.isEmpty {
                let onFiles = onFiles
                var receiving = false
                for receiver in receivers {
                    guard let destination = MediaStaging.freshDirectory() else { continue }
                    receiving = true
                    // The reader fires on the main queue once the source
                    // app has written the file; assumeIsolated re-enters
                    // the actor (same pattern as the key monitor).
                    receiver.receivePromisedFiles(
                        atDestination: destination, operationQueue: .main
                    ) { url, error in
                        guard error == nil else { return }
                        MainActor.assumeIsolated { onFiles([url]) }
                    }
                }
                if receiving { return true }
            }
            if let png = MediaStaging.pngData(from: pasteboard),
               let staged = MediaStaging.stage(png, extension: "png", prefix: "Dropped") {
                onFiles([staged])
                return true
            }
            if let pdf = pasteboard.data(forType: .pdf),
               let staged = MediaStaging.stage(pdf, extension: "pdf", prefix: "Dropped") {
                onFiles([staged])
                return true
            }
            if let onText,
               let urls = pasteboard.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL] {
                let links = urls.filter { !$0.isFileURL }
                if !links.isEmpty {
                    onText(links.map(\.absoluteString).joined(separator: "\n"))
                    return true
                }
            }
            return false
        }

        private func readable(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true])
                || pasteboard.canReadObject(
                    forClasses: [NSFilePromiseReceiver.self], options: nil)
                || pasteboard.availableType(from: [.png, .tiff, .pdf]) != nil
                || (onText != nil
                    && pasteboard.canReadObject(forClasses: [NSURL.self], options: nil))
        }
    }
}
#else
/// What a drop can carry on the UIKit platforms: a file on disk, image
/// or PDF bytes with no file behind them, or a bare web link.
/// Declaration order is match priority: an image drag that also carries
/// the image's remote URL must land as the image, not the link.
private enum DroppedMedia: Transferable {
    case file(URL)
    case image(Data)
    case pdf(Data)
    case link(URL)

    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return DroppedMedia.file(url)
        }
        DataRepresentation(importedContentType: .image) { DroppedMedia.image($0) }
        DataRepresentation(importedContentType: .pdf) { DroppedMedia.pdf($0) }
        DataRepresentation(importedContentType: .url) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return DroppedMedia.link(url)
        }
    }
}
#endif
