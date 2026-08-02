import Foundation

/// Exponential backoff with full jitter (delay uniform in [0, bound], bound
/// doubling per attempt up to a cap). One instance per retrying operation;
/// `reset()` after a success.
public struct BackoffMachine: Sendable {
    public var firstBound: Duration
    public var maxBound: Duration
    private var currentBound: Duration?

    public init(firstBound: Duration = .milliseconds(100), maxBound: Duration = .seconds(10)) {
        self.firstBound = firstBound
        self.maxBound = maxBound
    }

    public mutating func next() -> Duration {
        let bound = currentBound.map { min($0 * 2, maxBound) } ?? firstBound
        currentBound = bound
        return .seconds(Double.random(in: 0...bound.asSeconds))
    }

    public mutating func reset() {
        currentBound = nil
    }
}

extension Duration {
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
