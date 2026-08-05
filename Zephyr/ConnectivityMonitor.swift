import Foundation
import Network

/// Watches the system network path and fires once each time connectivity
/// returns, so reconnects and offline-queue flushes happen immediately
/// instead of waiting out a retry backoff.
@MainActor
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true

    init(onRestore: @escaping @MainActor () -> Void) {
        // weak at the outer closure too: the monitor retains this handler,
        // so a strong capture would cycle (self → monitor → handler → self).
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                if satisfied && !self.wasSatisfied {
                    onRestore()
                }
                self.wasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.twarge.zephyr.connectivity"))
    }

    deinit {
        monitor.cancel()
    }
}
