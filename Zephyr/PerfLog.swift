import Foundation

/// Debug performance probes. Enable with `make perf`, which launches the
/// app with the `-perfLog YES` argument (UserDefaults' argument domain —
/// the sandbox container blocks `defaults write` from outside) and keeps
/// stdout in the terminal. Render counts flush every 2 seconds; the store
/// prints event summaries every 5.
@MainActor
enum PerfLog {
    static let enabled = UserDefaults.standard.bool(forKey: "perfLog")

    private static var renderCounts: [String: Int] = [:]
    private static var flushScheduled = false

    /// Call at the top of a View body: counts evaluations per label.
    static func render(_ label: String) {
        guard enabled else { return }
        renderCounts[label, default: 0] += 1
        scheduleFlush()
    }

    private static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let summary = renderCounts
                .sorted { $0.value > $1.value }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            print("perf renders/2s: \(summary)")
            renderCounts = [:]
            flushScheduled = false
        }
    }

    /// Prints whenever the main thread stalls: a 100ms heartbeat whose
    /// oversleep is, to within a tick, how long the main thread was busy
    /// or blocked. Correlate the timestamps with what you were doing.
    static func startWatchdogIfEnabled() {
        guard enabled else { return }
        Task { @MainActor in
            let clock = ContinuousClock()
            var last = clock.now
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                let elapsed = clock.now - last
                let ms = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
                if ms > 200 {
                    print(String(format: "perf hitch: main thread stalled ~%.0f ms", ms - 100))
                }
                last = clock.now
            }
        }
    }

    /// Times a closure, printing when it exceeds the threshold.
    static func time<T>(
        _ label: String, over thresholdMs: Double = 8, _ body: () -> T
    ) -> T {
        guard enabled else { return body() }
        let start = ContinuousClock.now
        let result = body()
        let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
        if ms >= thresholdMs {
            print(String(format: "perf %@: %.1f ms", label, ms))
        }
        return result
    }
}
