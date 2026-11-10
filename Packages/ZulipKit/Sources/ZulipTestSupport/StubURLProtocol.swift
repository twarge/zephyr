import Foundation
import Synchronization

/// Serves canned responses to a URLSession, for exercising the paths that
/// bypass ApiTransport (the media session's streaming download). Register
/// a response per URL, then fetch through `session()`.
public final class StubURLProtocol: URLProtocol {
    public struct Stub: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        /// Bodies are delivered in pieces this large, so consumers see a
        /// stream rather than one lump.
        public var chunkSize: Int
        /// Never answers, until the client cancels.
        public var hangs: Bool

        public init(
            status: Int = 200, headers: [String: String] = [:],
            body: Data = Data(), chunkSize: Int = 1 << 14, hangs: Bool = false
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.chunkSize = chunkSize
            self.hangs = hangs
        }
    }

    /// Shared across parallel tests — register distinct URLs per test.
    private static let stubs = Mutex<[URL: Stub]>([:])

    public static func register(_ stub: Stub, for url: URL) {
        stubs.withLock { $0[url] = stub }
    }

    /// An ephemeral session that resolves every request against the
    /// registered stubs (an unregistered URL fails the request).
    public static func session() -> URLSession {
        URLSession(configuration: configuration())
    }

    /// The stubbed configuration, for clients that build their own session.
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        guard let url = request.url,
              let stub = Self.stubs.withLock({ $0[url] }),
              let response = HTTPURLResponse(
                url: url, statusCode: stub.status,
                httpVersion: "HTTP/1.1", headerFields: stub.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if stub.hangs { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var rest = stub.body[...]
        while !rest.isEmpty {
            client?.urlProtocol(self, didLoad: Data(rest.prefix(stub.chunkSize)))
            rest = rest.dropFirst(stub.chunkSize)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}
}
