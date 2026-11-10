import SwiftUI
import ZulipAPI
import ZulipModel

/// Files in and out of the window: authenticated attachment downloads,
/// sharing the selection, and (macOS) File → Export Selected….
extension MainSplitView {
    /// Downloads an attachment through the account's authenticated session:
    /// macOS saves into Downloads and reveals it; iOS presents Quick Look
    /// (whose share sheet covers "Save to Files"). The body streams to disk
    /// with the toolbar ring tracking it (and cancelling it).
    func downloadAttachment(url: URL, connection: ApiConnection) {
        guard !downloads.contains(where: { $0.url == url }) else { return }
        let download = AttachmentDownload(url: url)
        downloads.append(download)
        download.task = Task {
            defer { downloads.removeAll { $0 === download } }
            do {
                let outcome = try await connection.downloadFile(at: url) { received, total in
                    Task { @MainActor in
                        download.received = received
                        download.total = total
                    }
                }
                // A failed fetch, or an HTML answer to a file link (the
                // login wall of a realm we're not signed into), isn't the
                // file — hand those to the browser, which can sign in.
                guard case .file(let temporary, let filename) = outcome else {
                    Platform.openExternalURL(url)
                    return
                }
                placeDownloadedFile(temporary, filename: filename)
            } catch {
                // The ring's cancel already cleaned up its partial file;
                // real failures get the browser fallback.
                if !(error is CancellationError),
                   (error as? URLError)?.code != .cancelled {
                    Platform.openExternalURL(url)
                }
            }
        }
        // The ring appears only for downloads still running after a beat —
        // the common small attachment comes and goes without toolbar churn.
        Task {
            try? await Task.sleep(for: .seconds(1))
            download.revealed = true
        }
    }

    /// Puts a finished download where the platform wants it: Downloads plus
    /// a Finder reveal on macOS, Quick Look's temp directory on iOS.
    func placeDownloadedFile(_ temporary: URL, filename: String) {
        #if os(macOS)
        guard let downloadsDir = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first else { return }
        var destination = downloadsDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            let base = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            destination = downloadsDir.appendingPathComponent(
                "\(base)-\(Int(Date.now.timeIntervalSince1970))"
                    + (ext.isEmpty ? "" : ".\(ext)"))
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            // Sandbox without the Downloads entitlement, disk full…
            try? FileManager.default.removeItem(at: temporary)
        }
        #else
        let preview = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: preview)
        do {
            try FileManager.default.moveItem(at: temporary, to: preview)
            downloadPreviewURL = preview
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
        #endif
    }

    /// Only the server can classify an unknown extension: a quick HEAD —
    /// HTML (or nothing) means a page for the browser, anything else is a
    /// file worth downloading.
    static func sniffIsFile(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await ApiConnection.mediaSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let mime = response.mimeType?.lowercased()
        else { return false }
        return mime != "text/html" && mime != "application/xhtml+xml"
    }

    /// Stages the current selection for sharing: the selected attachments'
    /// downloaded files when any are selected, else the selected
    /// message(s) as attributed plain text, transcript order. iOS presents
    /// the share sheet; macOS the sharing picker off the toolbar button.
    func shareSelection() {
        Task {
            let items: [Any]
            let attachments = keys.selectedAttachments()
            if !attachments.isEmpty {
                var urls: [URL] = []
                for attachment in attachments {
                    if let url = await downloadMediaFile(
                        path: attachment.path, connection: store.connection) {
                        urls.append(mediaHandoffCopy(of: url))
                    }
                }
                guard !urls.isEmpty else { return }
                items = urls
            } else {
                let messages = keys.selectedMessages()
                guard !messages.isEmpty else { return }
                items = [messages.map { messageShareText($0) }.joined(separator: "\n\n")]
            }
            #if os(macOS)
            macShareItems = items
            #else
            sharePayload = SharePayload(items: items)
            #endif
        }
    }

    #if os(macOS)
    /// File → Export Selected…: the selected attachment(s) — a save panel
    /// for one, a folder chooser for several — or the selected message(s)
    /// as one text file, transcript order.
    func exportSelected() {
        let attachments = keys.selectedAttachments()
        if attachments.count > 1 {
            exportFolderPanel { folder in
                Task {
                    var failures: [String] = []
                    for attachment in attachments {
                        guard let url = await downloadMediaFile(
                            path: attachment.path, connection: store.connection)
                        else {
                            failures.append((attachment.path as NSString).lastPathComponent)
                            continue
                        }
                        // Collision-safe: "name-2.ext" rather than a
                        // silent overwrite in a folder the panel never
                        // confirmed replacements for.
                        let destination = Self.uniqueDestination(
                            for: url.lastPathComponent, in: folder)
                        do {
                            try FileManager.default.copyItem(at: url, to: destination)
                            unlockMediaFile(destination)
                        } catch {
                            failures.append(url.lastPathComponent)
                        }
                    }
                    if !failures.isEmpty {
                        exportError = "Couldn’t export \(failures.joined(separator: ", "))."
                    }
                }
            }
        } else if let attachment = attachments.first {
            Task {
                guard let url = await downloadMediaFile(
                    path: attachment.path, connection: store.connection)
                else {
                    exportError = "The attachment couldn’t be downloaded."
                    return
                }
                savePanel(suggestedName: url.lastPathComponent) { destination in
                    // The panel already confirmed any replacement.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                    unlockMediaFile(destination)
                }
            }
        } else {
            let messages = keys.selectedMessages()
            guard !messages.isEmpty else { return }
            let text = messages.map { messageShareText($0) }.joined(separator: "\n\n")
            let name = messages.count == 1
                ? "Message from \(messages[0].senderFullName).txt"
                : "Messages.txt"
            savePanel(suggestedName: name) { destination in
                try text.write(to: destination, atomically: true, encoding: .utf8)
            }
        }
    }

    func savePanel(suggestedName: String, write: @escaping (URL) throws -> Void) {
        guard let window = keys.hostWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    /// Multi-attachment export: one folder choice, every file into it.
    func exportFolderPanel(_ handler: @escaping (URL) -> Void) {
        guard let window = keys.hostWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder for the exported attachments"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            handler(url)
        }
    }

    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            url = folder.appendingPathComponent(candidate)
            counter += 1
        }
        return url
    }
    #endif
}
