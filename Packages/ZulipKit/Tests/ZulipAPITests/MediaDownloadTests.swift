import Foundation
import Synchronization
import Testing
import ZulipAPI
import ZulipTestSupport

/// The streaming attachment download: body fidelity, progress ticks, and
/// the header-only checks that hand login walls back to the browser.
struct MediaDownloadTests {
    private func connection() -> ApiConnection {
        ApiConnection(
            realmURL: URL(string: "https://chat.example.com")!,
            email: "self@example.com", apiKey: "key")
    }

    @Test func streamsBodyWithMonotonicProgress() async throws {
        let url = URL(string: "https://chat.example.com/user_uploads/2/ab/data.zip")!
        // Patterned, not zeros, so reordered or dropped chunks would show.
        let body = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
        StubURLProtocol.register(
            .init(
                status: 200,
                headers: [
                    "Content-Type": "application/zip",
                    "Content-Length": "\(body.count)",
                ],
                body: body),
            for: url)
        let ticks = Mutex<[(received: Int64, total: Int64?)]>([])
        let outcome = try await connection().downloadFile(
            at: url, via: StubURLProtocol.session()
        ) { received, total in
            ticks.withLock { $0.append((received, total)) }
        }
        guard case .file(let temporaryURL, let filename) = outcome else {
            Issue.record("expected a file, got \(outcome)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        #expect(filename == "data.zip")
        #expect(try Data(contentsOf: temporaryURL) == body)
        let recorded = ticks.withLock { $0 }
        #expect(recorded.last?.received == Int64(body.count))
        #expect(recorded.allSatisfy { $0.total == Int64(body.count) })
        #expect(recorded.map(\.received) == recorded.map(\.received).sorted())
    }

    @Test func missingContentLengthReportsUnknownTotal() async throws {
        let url = URL(string: "https://chat.example.com/user_uploads/2/cd/blob.bin")!
        let body = Data(repeating: 7, count: 100_000)
        StubURLProtocol.register(
            .init(headers: ["Content-Type": "application/octet-stream"], body: body),
            for: url)
        let ticks = Mutex<[Int64?]>([])
        let outcome = try await connection().downloadFile(
            at: url, via: StubURLProtocol.session()
        ) { _, total in
            ticks.withLock { $0.append(total) }
        }
        guard case .file(let temporaryURL, _) = outcome else {
            Issue.record("expected a file, got \(outcome)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        #expect(try Data(contentsOf: temporaryURL) == body)
        #expect(ticks.withLock { $0 }.allSatisfy { $0 == nil })
    }

    @Test func htmlAnswerToFileLinkIsNotAFile() async throws {
        // A login wall answering an attachment link: headers alone decide,
        // and the browser (which can sign in) gets the URL instead.
        let url = URL(string: "https://chat.example.com/user_uploads/2/ef/report.zip")!
        StubURLProtocol.register(
            .init(headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)),
            for: url)
        let outcome = try await connection().downloadFile(
            at: url, via: StubURLProtocol.session())
        #expect(outcome == .notAFile)
    }

    @Test func htmlFileLinkStillDownloads() async throws {
        // An actual .html file is the one HTML answer that IS the file.
        let url = URL(string: "https://files.example.com/page.html")!
        let body = Data("<html>doc</html>".utf8)
        StubURLProtocol.register(
            .init(headers: ["Content-Type": "text/html"], body: body), for: url)
        let outcome = try await connection().downloadFile(
            at: url, via: StubURLProtocol.session())
        guard case .file(let temporaryURL, let filename) = outcome else {
            Issue.record("expected a file, got \(outcome)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        #expect(filename == "page.html")
        #expect(try Data(contentsOf: temporaryURL) == body)
    }

    @Test func errorStatusIsNotAFile() async throws {
        let url = URL(string: "https://chat.example.com/user_uploads/2/gh/gone.zip")!
        StubURLProtocol.register(
            .init(status: 404, headers: ["Content-Type": "application/zip"]),
            for: url)
        let outcome = try await connection().downloadFile(
            at: url, via: StubURLProtocol.session())
        #expect(outcome == .notAFile)
    }

    @Test func contentDispositionNamesTheFile() async throws {
        let url = URL(string: "https://chat.example.com/user_uploads/2/ij/x")!
        StubURLProtocol.register(
            .init(
                headers: [
                    "Content-Type": "application/zip",
                    "Content-Disposition": #"attachment; filename="Q3 Report.zip""#,
                ],
                body: Data([1, 2, 3])),
            for: url)
        let outcome = try await connection().downloadFile(
            at: url, via: StubURLProtocol.session())
        guard case .file(let temporaryURL, let filename) = outcome else {
            Issue.record("expected a file, got \(outcome)")
            return
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        #expect(filename == "Q3 Report.zip")
    }
}
