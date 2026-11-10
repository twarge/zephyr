import Foundation
import Synchronization
import Testing
@testable import ZulipAPI
import ZulipTestSupport

private let realm = URL(string: "https://chat.example.com")!

private func connection(_ transport: FakeTransport = FakeTransport()) -> ApiConnection {
    ApiConnection(
        realmURL: realm, email: "self@example.com", apiKey: "key", transport: transport)
}

private let ok = FakeResponse.json(#"{"result": "success", "msg": ""}"#)

/// URL building for realm-relative paths: API routes and HTML `src`s.
struct RealmPathTests {
    @Test func routePath() throws {
        let request = try connection().authorizedURLRequest(path: "/api/v1/messages/42/history")
        #expect(request.url?.absoluteString == "https://chat.example.com/api/v1/messages/42/history")
    }

    @Test func percentEncodedPathIsNotDoubleEncoded() throws {
        let request = try connection().authorizedURLRequest(
            path: "/user_uploads/2/ab/%E6%97%A5%20x.png")
        #expect(
            request.url?.absoluteString
                == "https://chat.example.com/user_uploads/2/ab/%E6%97%A5%20x.png")
        #expect(request.url?.path == "/user_uploads/2/ab/日 x.png")
    }

    @Test func unencodedCharactersAreEncoded() throws {
        let request = try connection().authorizedURLRequest(path: "/user_uploads/2/ab/日 100%.png")
        #expect(
            request.url?.absoluteString
                == "https://chat.example.com/user_uploads/2/ab/%E6%97%A5%20100%25.png")
    }

    @Test func pathQueryIsKept() throws {
        let request = try connection().authorizedURLRequest(
            path: "/user_uploads/thumbnail/2/ab/x.png/840x560.webp?v=1&a=%2F#frag")
        let url = try #require(request.url)
        #expect(url.path == "/user_uploads/thumbnail/2/ab/x.png/840x560.webp")
        #expect(url.query(percentEncoded: true) == "v=1&a=%2F")
        #expect(url.fragment == nil)
    }

    @Test func pathQueryMergesWithParams() async throws {
        let transport = FakeTransport(script: [ok])
        _ = try await connection(transport).send(
            ApiRequest(method: .get, path: "/api/v1/x?a=1", params: [Param("b", "2 3")]))
        #expect(transport.requests[0].url.query(percentEncoded: true) == "a=1&b=2%203")
    }

    @Test func relativePathGainsLeadingSlash() throws {
        let request = try connection().authorizedURLRequest(path: "avatar/5")
        #expect(request.url?.absoluteString == "https://chat.example.com/avatar/5")
    }
}

/// Basic auth goes only to the realm's exact origin.
struct AbsoluteURLAuthTests {
    private func authorized(_ string: String, realm: URL = realm) -> Bool {
        ApiConnection(realmURL: realm, email: "a@b.c", apiKey: "k")
            .authorizedURLRequest(url: URL(string: string)!)
            .value(forHTTPHeaderField: "Authorization") != nil
    }

    @Test func sameOrigin() {
        #expect(authorized("https://chat.example.com/user_uploads/1/a.png"))
        #expect(authorized("HTTPS://Chat.Example.com:443/user_uploads/1/a.png"))
    }

    @Test func otherSchemePortOrHost() {
        #expect(!authorized("http://chat.example.com/user_uploads/1/a.png"))
        #expect(!authorized("https://chat.example.com:8443/user_uploads/1/a.png"))
        #expect(!authorized("https://evil.example.com/user_uploads/1/a.png"))
        #expect(!authorized("https://chat.example.com.evil.com/a.png"))
    }

    @Test func explicitRealmPort() {
        let realm = URL(string: "http://localhost:9991")!
        #expect(authorized("http://localhost:9991/a.png", realm: realm))
        #expect(!authorized("http://localhost/a.png", realm: realm))
    }
}

struct ErrorResponseTests {
    @Test func bare429UsesRetryAfterSeconds() async {
        let transport = FakeTransport(script: [
            .http(status: 429, headers: ["Retry-After": "7"], body: "<html>slow down</html>")
        ])
        let error = await #expect(throws: ApiError.self) {
            _ = try await connection(transport).send(ApiRequest(method: .get, path: "/api/v1/x"))
        }
        #expect(error?.retryAfterSeconds == 7)
        #expect(error?.isRateLimited == true)
    }

    @Test func bare503UsesRetryAfterDate() async throws {
        let date = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let transport = FakeTransport(script: [
            .http(status: 503, headers: ["Retry-After": formatter.string(from: date)])
        ])
        let error = await #expect(throws: ApiError.self) {
            _ = try await connection(transport).send(ApiRequest(method: .get, path: "/api/v1/x"))
        }
        let delay = try #require(error?.retryAfterSeconds)
        #expect((110...121).contains(delay))
        #expect(error?.code == "HTTP_ERROR")
    }

    @Test func jsonBodyRetryAfterWinsOverHeader() async {
        let transport = FakeTransport(script: [
            .http(
                status: 429, headers: ["Retry-After": "30"],
                body: #"{"result": "error", "msg": "", "code": "RATE_LIMIT_HIT", "retry-after": 2.5}"#)
        ])
        let error = await #expect(throws: ApiError.self) {
            _ = try await connection(transport).send(ApiRequest(method: .get, path: "/api/v1/x"))
        }
        #expect(error?.retryAfterSeconds == 2.5)
    }

    @Test func retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_445_412_480)  // 2015-10-21 07:28:00 GMT
        #expect(ApiConnection.retryAfter(header: " 12 ", now: now) == 12)
        #expect(ApiConnection.retryAfter(header: "Wed, 21 Oct 2015 07:28:30 GMT", now: now) == 30)
        #expect(ApiConnection.retryAfter(header: "Wed, 21 Oct 2015 07:00:00 GMT", now: now) == 0)
        #expect(ApiConnection.retryAfter(header: "-1", now: now) == nil)
        #expect(ApiConnection.retryAfter(header: "soon", now: now) == nil)
        #expect(ApiConnection.retryAfter(header: nil, now: now) == nil)
    }
}

struct UploadTests {
    private let uploaded = FakeResponse.json(
        #"{"result": "success", "msg": "", "url": "/user_uploads/1/ab/f.bin"}"#)

    @Test func filenameIsEscaped() async throws {
        let transport = FakeTransport(script: [uploaded])
        _ = try await connection(transport).uploadFile(
            Data("x".utf8), filename: "a\"b\r\nX-Injected: 1.txt", mimeType: "text/plain")
        let body = try #require(transport.requests.first?.body)
        #expect(body.contains(#"filename="a%22bX-Injected: 1.txt""#))
        #expect(!body.contains("\r\nX-Injected"))
    }

    @Test func streamsFileFromDisk() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-source-\(UUID().uuidString)")
        let payload = Data((0..<3_000_000).map { UInt8($0 % 253) })
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let transport = FakeTransport(script: [uploaded])
        let path = try await connection(transport).uploadFile(
            fileURL: source, filename: "clip.mov", mimeType: "video/quicktime")
        #expect(path == "/user_uploads/1/ab/f.bin")

        let request = try #require(transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://chat.example.com/api/v1/user_uploads")
        #expect(request.headers["Authorization"]?.hasPrefix("Basic ") == true)
        let contentType = try #require(request.headers["Content-Type"])
        let boundary = try #require(contentType.split(separator: "=").last.map(String.init))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try #require(request.body)
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.contains(#"filename="clip.mov""#))
        #expect(body.contains("Content-Type: video/quicktime\r\n\r\n"))
        #expect(body.hasSuffix("\r\n--\(boundary)--\r\n"))
    }

    @Test func streamedUploadThroughURLSession() async throws {
        let url = URL(string: "https://upload-stream.example.com/api/v1/user_uploads")!
        StubURLProtocol.register(
            .init(
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"result": "success", "msg": "", "url": "/user_uploads/9/x"}"#.utf8)),
            for: url)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-source-\(UUID().uuidString)")
        try Data(repeating: 1, count: 10_000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let connection = ApiConnection(
            realmURL: URL(string: "https://upload-stream.example.com")!,
            email: "a@b.c", apiKey: "k",
            transport: URLSessionTransport(configuration: StubURLProtocol.configuration()))
        let path = try await connection.uploadFile(
            fileURL: source, filename: "f.bin", progress: { _ in })
        #expect(path == "/user_uploads/9/x")
    }

    @Test func missingSourceFileThrows() async {
        let transport = FakeTransport(script: [uploaded])
        await #expect(throws: (any Error).self) {
            _ = try await connection(transport).uploadFile(
                fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"),
                filename: "x")
        }
        #expect(transport.requests.isEmpty)
    }
}

struct TransportCancellationTests {
    @Test func cancelledRequestThrowsCancellationError() async {
        let url = URL(string: "https://hang.example.com/api/v1/events")!
        StubURLProtocol.register(.init(hangs: true), for: url)
        let transport = URLSessionTransport(configuration: StubURLProtocol.configuration())
        let task = Task {
            try await transport.perform(URLRequest(url: url))
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}

struct RouteShapeTests {
    @Test func editDraftOmitsIdFromDraftObject() async throws {
        let transport = FakeTransport(script: [ok])
        try await connection(transport).editDraft(
            id: 17,
            ServerDraft(id: 17, type: "stream", to: [10], topic: "t", content: "c", timestamp: 5))
        let request = try #require(transport.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v1/drafts/17")
        let draft = try #require(request.formValue("draft"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(draft.utf8)) as? [String: Any])
        #expect(object["id"] == nil)
        #expect(Set(object.keys) == ["type", "to", "topic", "content", "timestamp"])
    }

    @Test func messageHistoryAllowsEmptyTopicName() async throws {
        let transport = FakeTransport(script: [
            .json(#"{"result": "success", "msg": "", "message_history": []}"#)
        ])
        _ = try await connection(transport).getMessageHistory(messageId: 3)
        #expect(transport.requests[0].queryValue("allow_empty_topic_name") == "true")
    }

    @Test func subscriptionJSONEscapesControlCharacters() async throws {
        let name = "a\"b\\c\nd\te\u{1}f 日本 🎉"
        let transport = FakeTransport(script: [ok, ok, ok])
        let api = connection(transport)
        try await api.subscribe(toChannel: name)
        try await api.unsubscribe(fromChannel: name)
        try await api.setSubscriptionProperty(streamId: 4, property: "color", value: name)

        struct Named: Decodable { var name: String }
        let subscribe = try #require(transport.requests[0].formValue("subscriptions"))
        #expect(try JSONDecoder().decode([Named].self, from: Data(subscribe.utf8))[0].name == name)
        #expect(!subscribe.contains("\n"))

        let unsubscribe = try #require(transport.requests[1].queryValue("subscriptions"))
        #expect(try JSONDecoder().decode([String].self, from: Data(unsubscribe.utf8)) == [name])

        struct Property: Decodable {
            var stream_id: Int
            var property: String
            var value: String
        }
        let data = try #require(transport.requests[2].formValue("subscription_data"))
        let property = try JSONDecoder().decode([Property].self, from: Data(data.utf8))[0]
        #expect(property.stream_id == 4)
        #expect(property.property == "color")
        #expect(property.value == name)
    }

    @Test func boolSubscriptionPropertyStaysBool() async throws {
        let transport = FakeTransport(script: [ok])
        try await connection(transport).setSubscriptionProperty(
            streamId: 4, property: "is_muted", value: true)
        let data = try #require(transport.requests[0].formValue("subscription_data"))
        #expect(data == #"[{"property":"is_muted","stream_id":4,"value":true}]"#)
    }
}
