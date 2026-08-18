import Foundation

/// What came back when a file link was fetched for download.
public enum MediaDownloadOutcome: Sendable, Equatable {
    /// The body, streamed to a temporary file, with the filename the
    /// server suggested (or the URL implied).
    case file(temporaryURL: URL, filename: String)
    /// A non-2xx status, or an HTML answer to a link that isn't an HTML
    /// file — a login wall or error page, not the file.
    case notAFile
}

extension ApiConnection {
    /// Streams `url` to a temporary file through the authenticated media
    /// session, reporting cumulative bytes (and the total, when the server
    /// declares one) as the body arrives. The response headers are checked
    /// before any of the body is consumed, so a login wall costs nothing;
    /// a throw — including cancellation — leaves no temporary file behind.
    public func downloadFile(
        at url: URL,
        via session: URLSession? = nil,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64?) -> Void = { _, _ in }
    ) async throws -> MediaDownloadOutcome {
        let session = session ?? Self.mediaSession
        let (bytes, response) = try await session.bytes(for: authorizedURLRequest(url: url))
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            return .notAFile
        }
        if response.mimeType == "text/html",
           !url.pathExtension.lowercased().hasPrefix("htm") {
            return .notAFile
        }
        // -1 when the server doesn't say (chunked transfer).
        let total = response.expectedContentLength > 0
            ? response.expectedContentLength : nil
        let filename = response.suggestedFilename
            ?? url.lastPathComponent.removingPercentEncoding
            ?? "attachment"
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("zephyr-download-\(UUID().uuidString)")
        do {
            try await Self.write(bytes, to: temporary, total: total, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return .file(temporaryURL: temporary, filename: filename)
    }

    /// The byte pump: appends to `destination` a buffer at a time, so a
    /// multi-gigabyte body never sits in memory whole.
    private static func write(
        _ bytes: URLSession.AsyncBytes, to destination: URL, total: Int64?,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let chunkSize = 1 << 18  // 256 KB per write and progress tick.
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data(capacity: chunkSize)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(received, total)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            progress(received, total)
        }
        try handle.close()
    }
}
