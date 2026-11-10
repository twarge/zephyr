import Foundation
import Synchronization

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
        let pump = DownloadPump(url: url, progress: progress)
        let task = session.dataTask(with: authorizedURLRequest(url: url))
        task.delegate = pump
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pump.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Per-task data delegate: decides on the headers, then appends each
/// chunk URLSession delivers straight to the temporary file, so a
/// multi-gigabyte body never sits in memory whole.
private final class DownloadPump: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<MediaDownloadOutcome, any Error>?
        var handle: FileHandle?
        var filename = ""
        var total: Int64?
        var received: Int64 = 0
        var reported: Int64 = 0
        var notAFile = false
        var writeError: (any Error)?
    }

    private static let progressStride: Int64 = 1 << 18  // 256 KB per tick.

    private let url: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("zephyr-download-\(UUID().uuidString)")
    private let state = Mutex(State())

    init(url: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.url = url
        self.progress = progress
    }

    func start(
        _ task: URLSessionDataTask,
        continuation: CheckedContinuation<MediaDownloadOutcome, any Error>
    ) {
        state.withLock { $0.continuation = continuation }
        // Even if already cancelled, resume: a cancelled task still
        // completes (with URLError(.cancelled)), which resumes the caller.
        task.resume()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            return reject()
        }
        if response.mimeType == "text/html",
           !url.pathExtension.lowercased().hasPrefix("htm") {
            return reject()
        }
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporary)
            state.withLock {
                $0.handle = handle
                // -1 when the server doesn't say (chunked transfer).
                $0.total = response.expectedContentLength > 0
                    ? response.expectedContentLength : nil
                // Always set on Apple platforms (Content-Disposition, else
                // the URL's already-decoded last component).
                $0.filename = response.suggestedFilename ?? url.lastPathComponent
            }
            return .allow
        } catch {
            state.withLock { $0.writeError = error }
            return .cancel
        }
    }

    private func reject() -> URLSession.ResponseDisposition {
        state.withLock { $0.notAFile = true }
        return .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tick: (Int64, Int64?)? = state.withLock { state in
            guard let handle = state.handle, state.writeError == nil else { return nil }
            do {
                try handle.write(contentsOf: data)
            } catch {
                state.writeError = error
                dataTask.cancel()
                return nil
            }
            state.received += Int64(data.count)
            guard state.received - state.reported >= Self.progressStride else { return nil }
            state.reported = state.received
            return (state.received, state.total)
        }
        if let tick { progress(tick.0, tick.1) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        let (continuation, outcome, tick) = state.withLock {
            state -> (
                CheckedContinuation<MediaDownloadOutcome, any Error>?,
                Result<MediaDownloadOutcome, any Error>, (Int64, Int64?)?
            ) in
            defer { state.continuation = nil }
            try? state.handle?.close()
            state.handle = nil
            if state.notAFile {
                return (state.continuation, .success(.notAFile), nil)
            }
            if let failure = state.writeError ?? error {
                let cancelled = (failure as? URLError)?.code == .cancelled
                return (state.continuation, .failure(cancelled ? CancellationError() : failure), nil)
            }
            // The remainder since the last stride-sized tick.
            let tick = state.received != state.reported ? (state.received, state.total) : nil
            state.reported = state.received
            return (
                state.continuation,
                .success(.file(temporaryURL: temporary, filename: state.filename)), tick)
        }
        if case .success(.file) = outcome {
            if let tick { progress(tick.0, tick.1) }
        } else {
            try? FileManager.default.removeItem(at: temporary)
        }
        continuation?.resume(with: outcome)
    }

    /// Never forward the media session's credentials to a redirect target
    /// (Zulip Cloud redirects uploads to S3, which rejects basic auth).
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }
}
