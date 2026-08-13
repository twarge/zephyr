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

    /// Writes PNG data into a fresh staging directory. No spaces in the
    /// filename: it ends up inside a markdown link URL, and raw spaces
    /// break Zulip's link parsing (and the server preview).
    static func stagePNG(_ pngData: Data, prefix: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        guard let directory = freshDirectory() else { return nil }
        let fileURL = directory
            .appendingPathComponent("\(prefix)-\(formatter.string(from: .now)).png")
        do {
            try pngData.write(to: fileURL)
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
    /// Accepts media dragged in from other apps, funneled to file URLs
    /// for the upload path. Drags arrive in three shapes: real file URLs
    /// (Finder), file *promises* (Photos, Safari, Mail — the source
    /// writes the file only once someone accepts), and raw image data
    /// with no file behind it (rendered-image drags). SwiftUI's
    /// `dropDestination` can express only the first, so macOS uses an
    /// AppKit catcher; the other platforms take files and image data
    /// through a Transferable.
    func mediaDropTarget(
        isTargeted: Binding<Bool>? = nil,
        canAccept: @escaping () -> Bool = { true },
        onFiles: @escaping ([URL]) -> Void
    ) -> some View {
        #if canImport(AppKit)
        overlay {
            MediaDropCatcher(
                canAccept: canAccept, isTargeted: isTargeted, onFiles: onFiles)
            .allowsHitTesting(false)
        }
        #else
        dropDestination(for: DroppedMedia.self) { items, _ in
            guard canAccept() else { return false }
            var files: [URL] = []
            for item in items {
                switch item {
                case .file(let url):
                    files.append(url)
                case .image(let data):
                    if let png = MediaStaging.pngData(fromImage: data),
                       let staged = MediaStaging.stagePNG(png, prefix: "Dropped") {
                        files.append(staged)
                    }
                }
            }
            guard !files.isEmpty else { return false }
            onFiles(files)
            return true
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
    var onFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes
                .map { NSPasteboard.PasteboardType($0) }
                + [.fileURL, .png, .tiff])
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.canAccept = canAccept
        view.onFiles = onFiles
        let isTargeted = isTargeted
        view.onTargeted = { isTargeted?.wrappedValue = $0 }
    }

    final class CatcherView: NSView {
        var canAccept: () -> Bool = { true }
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
            // its own name); raw image data last, staged into a PNG.
            if let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                onFiles(urls)
                return true
            }
            if let receivers = pasteboard.readObjects(
                forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver],
               !receivers.isEmpty {
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
                return receiving
            }
            if let png = MediaStaging.pngData(from: pasteboard),
               let staged = MediaStaging.stagePNG(png, prefix: "Dropped") {
                onFiles([staged])
                return true
            }
            return false
        }

        private func readable(_ pasteboard: NSPasteboard) -> Bool {
            pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true])
                || pasteboard.canReadObject(
                    forClasses: [NSFilePromiseReceiver.self], options: nil)
                || pasteboard.availableType(from: [.png, .tiff]) != nil
        }
    }
}
#else
/// What a drop can carry on the UIKit platforms: a file on disk, or
/// image bytes with no file behind them.
private enum DroppedMedia: Transferable {
    case file(URL)
    case image(Data)

    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return DroppedMedia.file(url)
        }
        DataRepresentation(importedContentType: .image) { DroppedMedia.image($0) }
    }
}
#endif
