import Foundation
import Synchronization

/// A single name/value parameter for a Zulip API request.
public struct Param: Sendable, Equatable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A transport-agnostic description of one API request.
///
/// Params are sent as the query string for GET/DELETE and as an
/// `application/x-www-form-urlencoded` body for POST/PATCH (Zulip's convention).
public struct ApiRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
        case patch = "PATCH"
    }

    public var method: Method
    public var path: String
    public var params: [Param]
    public var timeout: Double?

    public init(method: Method, path: String, params: [Param] = [], timeout: Double? = nil) {
        self.method = method
        self.path = path
        self.params = params
        self.timeout = timeout
    }
}

/// The lowest network layer, fakeable in tests.
public protocol ApiTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Like `perform`, reporting request-body upload progress (0…1).
    func perform(
        _ request: URLRequest,
        uploadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, HTTPURLResponse)
}

extension ApiTransport {
    /// Default: progress unavailable; behaves like plain `perform`.
    public func perform(
        _ request: URLRequest,
        uploadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        try await perform(request)
    }
}

public struct URLSessionTransport: ApiTransport {
    public static let shared = URLSessionTransport()

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        // Individual requests set tighter timeouts; this is the outer bound,
        // sized for event long-polls.
        config.timeoutIntervalForRequest = 600
        session = URLSession(configuration: config)
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func perform(
        _ request: URLRequest,
        uploadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = UploadProgressDelegate(callback: uploadProgress)
        let (data, response) = try await session.data(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate,
        @unchecked Sendable {
        // @unchecked: the only state is an immutable Sendable closure.
        private let callback: @Sendable (Double) -> Void

        init(callback: @escaping @Sendable (Double) -> Void) {
            self.callback = callback
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64, totalBytesExpectedToSend: Int64
        ) {
            guard totalBytesExpectedToSend > 0 else { return }
            callback(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
    }
}

/// An error response from the Zulip API (or a malformed success response).
public struct ApiError: Error, Sendable {
    public var httpStatus: Int
    public var code: String
    public var message: String
    public var retryAfterSeconds: Double?

    public init(
        httpStatus: Int, code: String, message: String, retryAfterSeconds: Double? = nil
    ) {
        self.httpStatus = httpStatus
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var isBadEventQueueId: Bool { code == "BAD_EVENT_QUEUE_ID" }
    public var isRateLimited: Bool { code == "RATE_LIMIT_HIT" }

    public static let malformedResponseCode = "MALFORMED_RESPONSE"
    public var isMalformedResponse: Bool { code == Self.malformedResponseCode }
}

extension ApiError: LocalizedError {
    public var errorDescription: String? {
        message.isEmpty ? "\(code) (HTTP \(httpStatus))" : "\(code): \(message)"
    }
}

/// Central JSON configuration: the Zulip API is snake_case throughout.
public enum ZulipJSON {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func encodeString(_ value: some Encodable) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// A connection to one Zulip realm as one user (or unauthenticated, for the
/// pre-login endpoints). Holds credentials, the negotiated feature level, and
/// the transport. All route functions live in extensions on this type.
public final class ApiConnection: Sendable {
    public let realmURL: URL
    public let email: String?
    public let userAgent: String

    private let authHeader: String?
    private let transport: any ApiTransport
    private let _featureLevel = Mutex<Int?>(nil)

    /// The server's API feature level, set after /server_settings or /register.
    /// Route functions use this to gate version-dependent parameters.
    public var featureLevel: Int? {
        get { _featureLevel.withLock { $0 } }
        set { _featureLevel.withLock { $0 = newValue } }
    }

    public static var defaultUserAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Zephyr/0.1 (macOS \(v.majorVersion).\(v.minorVersion))"
    }

    public init(
        realmURL: URL,
        email: String? = nil,
        apiKey: String? = nil,
        userAgent: String = ApiConnection.defaultUserAgent,
        transport: any ApiTransport = URLSessionTransport.shared
    ) {
        self.realmURL = realmURL
        self.email = email
        self.userAgent = userAgent
        self.transport = transport
        if let email, let apiKey {
            let credentials = Data("\(email):\(apiKey)".utf8).base64EncodedString()
            authHeader = "Basic \(credentials)"
        } else {
            authHeader = nil
        }
    }

    // MARK: Requests

    /// Sends a request, returning the raw body on 2xx and throwing `ApiError`
    /// (decoded from the standard error envelope) otherwise.
    public func send(_ request: ApiRequest) async throws -> Data {
        let urlRequest = try makeURLRequest(request)
        let (data, response) = try await transport.perform(urlRequest)
        return try processResponse(data, response)
    }

    private func processResponse(_ data: Data, _ response: HTTPURLResponse) throws -> Data {
        if (200..<300).contains(response.statusCode) {
            return data
        }
        if let envelope = try? ZulipJSON.decoder.decode(ErrorEnvelope.self, from: data),
           envelope.result == "error" {
            throw ApiError(
                httpStatus: response.statusCode,
                code: envelope.code ?? "UNKNOWN_ERROR",
                message: envelope.msg ?? "",
                retryAfterSeconds: envelope.retryAfter)
        }
        let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? ""
        throw ApiError(httpStatus: response.statusCode, code: "HTTP_ERROR", message: bodyPreview)
    }

    /// POST /user_uploads (multipart) — returns the upload's realm-relative
    /// URL, for `[filename](url)` message references. `progress` reports the
    /// body upload fraction when the transport supports it.
    public func uploadFile(
        _ fileData: Data, filename: String, mimeType: String = "application/octet-stream",
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard var components = URLComponents(url: realmURL, resolvingAgainstBaseURL: false) else {
            throw ApiError(httpStatus: 0, code: "BAD_REALM_URL", message: realmURL.absoluteString)
        }
        components.path = "/api/v1/user_uploads"
        guard let url = components.url else {
            throw ApiError(httpStatus: 0, code: "BAD_REALM_URL", message: realmURL.absoluteString)
        }

        let boundary = "zephyr-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                    .utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 300
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let authHeader {
            urlRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        struct UploadResult: Decodable {
            var url: String?
            var uri: String?
        }
        let (data, response): (Data, HTTPURLResponse)
        if let progress {
            (data, response) = try await transport.perform(urlRequest, uploadProgress: progress)
        } else {
            (data, response) = try await transport.perform(urlRequest)
        }
        let processed = try processResponse(data, response)
        let result = try ZulipJSON.decoder.decode(UploadResult.self, from: processed)
        guard let path = result.url ?? result.uri else {
            throw ApiError(
                httpStatus: 200, code: ApiError.malformedResponseCode,
                message: "upload response missing url")
        }
        return path
    }

    /// Sends a request and decodes the success response strictly; a decode
    /// failure is surfaced as `ApiError` with `malformedResponseCode`
    /// ("crunchy shell": bad data is rejected here, never passed inward).
    public func request<R: Decodable>(_ request: ApiRequest, as type: R.Type = R.self) async throws -> R {
        let data = try await send(request)
        do {
            return try ZulipJSON.decoder.decode(R.self, from: data)
        } catch {
            throw ApiError(
                httpStatus: 200,
                code: ApiError.malformedResponseCode,
                message: "decoding \(R.self) from \(request.path): \(error)")
        }
    }

    private struct ErrorEnvelope: Decodable {
        var result: String
        var msg: String?
        var code: String?
        var retryAfter: Double?

        enum CodingKeys: String, CodingKey {
            case result, msg, code
            case retryAfter = "retry-after"
        }
    }

    /// An authenticated URLRequest for fetching media (avatars, uploads) with
    /// `mediaSession`. Not for API endpoints — use `request(_:)`.
    public func authorizedURLRequest(path: String, timeout: Double = 60) throws -> URLRequest {
        try makeURLRequest(ApiRequest(method: .get, path: path, timeout: timeout))
    }

    /// Session for media fetches: follows redirects but strips the
    /// Authorization header when redirected — Zulip Cloud redirects
    /// `/user_uploads/…` and `/avatar/…` to S3-backed CDNs, which reject
    /// requests that still carry basic auth.
    public static let mediaSession: URLSession = URLSession(
        configuration: .ephemeral,
        delegate: AuthRedirectStripper(),
        delegateQueue: nil)

    private final class AuthRedirectStripper: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            var stripped = request
            stripped.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(stripped)
        }
    }

    private func makeURLRequest(_ request: ApiRequest) throws -> URLRequest {
        guard var components = URLComponents(url: realmURL, resolvingAgainstBaseURL: false) else {
            throw ApiError(httpStatus: 0, code: "BAD_REALM_URL", message: realmURL.absoluteString)
        }
        components.path = request.path

        var urlRequest: URLRequest
        switch request.method {
        case .get, .delete:
            if !request.params.isEmpty {
                components.percentEncodedQuery = Self.encodeForm(request.params)
            }
            guard let url = components.url else {
                throw ApiError(httpStatus: 0, code: "BAD_REALM_URL", message: realmURL.absoluteString)
            }
            urlRequest = URLRequest(url: url)
        case .post, .patch:
            guard let url = components.url else {
                throw ApiError(httpStatus: 0, code: "BAD_REALM_URL", message: realmURL.absoluteString)
            }
            urlRequest = URLRequest(url: url)
            urlRequest.httpBody = Data(Self.encodeForm(request.params).utf8)
            urlRequest.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type")
        }
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout ?? 60
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let authHeader {
            urlRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    // Strict percent-encoding (RFC 3986 unreserved only), used for both query
    // strings and form bodies so values like JSON-encoded narrows survive.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encodeForm(_ params: [Param]) -> String {
        params
            .map { param in
                let name = param.name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? param.name
                let value = param.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? param.value
                return "\(name)=\(value)"
            }
            .joined(separator: "&")
    }
}
