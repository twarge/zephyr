import Foundation
import Synchronization
import ZulipAPI

/// A request captured by `FakeTransport`, with helpers for asserting on
/// query/form parameters.
public struct RecordedRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: String?

    public var path: String { url.path }

    public func queryValue(_ name: String) -> String? {
        Self.value(name, in: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
    }

    public func formValue(_ name: String) -> String? {
        Self.value(name, in: body)
    }

    private static func value(_ name: String, in encoded: String?) -> String? {
        guard let encoded else { return nil }
        for pair in encoded.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, String(parts[0]).removingPercentEncoding == name else { continue }
            return String(parts[1]).removingPercentEncoding
        }
        return nil
    }
}

public enum FakeResponse: Sendable {
    case json(String, status: Int = 200)
    /// Never responds (until the request's task is cancelled). Useful as the
    /// default response so a test's event loop parks quietly.
    case hang
    case networkError
}

/// Scripted `ApiTransport`: responses are served in FIFO order, then
/// `defaultResponse` (if set) for any further requests.
public final class FakeTransport: ApiTransport {
    private struct State {
        var script: [FakeResponse]
        var defaultResponse: FakeResponse?
        var recorded: [RecordedRequest] = []
    }

    private let state: Mutex<State>

    public init(script: [FakeResponse] = [], defaultResponse: FakeResponse? = nil) {
        state = Mutex(State(script: script, defaultResponse: defaultResponse))
    }

    public func enqueue(_ response: FakeResponse) {
        state.withLock { $0.script.append(response) }
    }

    public var requests: [RecordedRequest] {
        state.withLock { $0.recorded }
    }

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody.map { String(decoding: $0, as: UTF8.self) })
        let response = state.withLock { state -> FakeResponse? in
            state.recorded.append(recorded)
            if state.script.isEmpty {
                return state.defaultResponse
            }
            return state.script.removeFirst()
        }
        switch response {
        case .json(let body, let status):
            let http = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), http)
        case .networkError:
            throw URLError(.notConnectedToInternet)
        case .hang, nil:
            // Park until this request's task is cancelled.
            typealias Continuation = CheckedContinuation<(Data, HTTPURLResponse), any Error>
            enum HangState {
                case idle
                case waiting(Continuation)
                case cancelled
            }
            let hangState = Mutex<HangState>(.idle)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: Continuation) in
                    let alreadyCancelled = hangState.withLock { state -> Bool in
                        if case .cancelled = state { return true }
                        state = .waiting(continuation)
                        return false
                    }
                    if alreadyCancelled {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                let continuation: Continuation? = hangState.withLock { state in
                    defer { state = .cancelled }
                    if case .waiting(let waiting) = state { return waiting }
                    return nil
                }
                continuation?.resume(throwing: CancellationError())
            }
        }
    }
}
