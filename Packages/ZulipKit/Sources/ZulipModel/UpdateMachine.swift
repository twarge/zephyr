import Foundation
import ZulipAPI
import os

@MainActor
public protocol UpdateMachineDelegate: AnyObject {
    /// The queue died or produced undecodable events: discard the store and
    /// rebuild from a fresh /register. The machine has already stopped.
    func updateMachineNeedsRebuild(_ machine: UpdateMachine, reason: UpdateMachine.RebuildReason)
}

/// The event-polling loop for one `PerAccountStore`: long-poll GET /events,
/// apply each event to the store, advance `lastEventId`; back off on transient
/// errors; hand queue death to the delegate (the store itself never polls).
@MainActor
public final class UpdateMachine {
    public enum RebuildReason: Sendable {
        case badEventQueueId
        case malformedEvents(String)
    }

    public typealias SleepFunction = @Sendable (Duration) async throws -> Void

    public let store: PerAccountStore
    public weak var delegate: (any UpdateMachineDelegate)?
    /// Debug/harness hook, called after each event is applied.
    public var eventObserver: ((Event) -> Void)?

    private let sleep: SleepFunction
    private var pollTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var backoffSleepTask: Task<Void, any Error>?
    private let logger = Logger(subsystem: "com.twarge.zephyr", category: "sync")

    private let enablePresence: Bool

    public init(
        store: PerAccountStore,
        delegate: (any UpdateMachineDelegate)? = nil,
        enablePresence: Bool = true,
        sleep: @escaping SleepFunction = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.delegate = delegate
        self.enablePresence = enablePresence
        self.sleep = sleep
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { await poll() }
        if enablePresence {
            presenceTask = Task { await presenceLoop() }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        presenceTask?.cancel()
        presenceTask = nil
    }

    /// Interrupts a pending retry backoff so the next poll happens NOW —
    /// called when the network path comes back, instead of sleeping out up
    /// to the full backoff (10s) before reconnecting and flushing.
    public func kick() {
        backoffSleepTask?.cancel()
    }

    private func presenceLoop() async {
        let interval = Duration.seconds(store.presencePingIntervalSeconds)
        while !Task.isCancelled {
            await store.pingPresence()
            do {
                try await sleep(interval)
            } catch {
                return
            }
        }
    }

    private func poll() async {
        var backoff = BackoffMachine()
        var consecutiveFailures = 0
        // Flush offline work on the first successful poll (queues restored
        // from disk) and again whenever the connection recovers.
        var needsOfflineFlush = true
        let timeout = Double(store.eventQueueLongpollTimeoutSeconds) + 10

        while !Task.isCancelled {
            do {
                let events = try await store.connection.getEvents(
                    queueId: store.queueId,
                    lastEventId: store.lastEventId,
                    dontBlock: consecutiveFailures > 0,
                    timeoutSeconds: timeout)
                consecutiveFailures = 0
                backoff.reset()
                store.isRecoveringEventStream = false
                if needsOfflineFlush {
                    needsOfflineFlush = false
                    store.flushPending()
                }
                for event in events {
                    store.handleEvent(event)
                    eventObserver?(event)
                    store.lastEventId = max(store.lastEventId, event.id)
                }
            } catch is CancellationError {
                return
            } catch let error as ApiError where error.isBadEventQueueId {
                logger.info("event queue expired; requesting store rebuild")
                stop()
                delegate?.updateMachineNeedsRebuild(self, reason: .badEventQueueId)
                return
            } catch let error as ApiError where error.isMalformedResponse {
                logger.error("undecodable events; requesting store rebuild: \(error.message, privacy: .public)")
                stop()
                delegate?.updateMachineNeedsRebuild(self, reason: .malformedEvents(error.message))
                return
            } catch {
                consecutiveFailures += 1
                needsOfflineFlush = true
                if consecutiveFailures >= 2 {
                    store.isRecoveringEventStream = true
                }
                var delay = backoff.next()
                if let apiError = error as? ApiError, let retryAfter = apiError.retryAfterSeconds {
                    delay = .seconds(retryAfter)
                }
                logger.debug("event poll failed (attempt \(consecutiveFailures)); retrying")
                // Interruptible: kick() cancels just the inner sleep (retry
                // now, fresh backoff); stopping the machine cancels the
                // poll task, which cancels the sleep through the handler.
                let sleepFunction = sleep
                let sleepTask = Task { try await sleepFunction(delay) }
                backoffSleepTask = sleepTask
                do {
                    try await withTaskCancellationHandler {
                        try await sleepTask.value
                    } onCancel: {
                        sleepTask.cancel()
                    }
                } catch {
                    if Task.isCancelled { return }
                    backoff.reset()
                }
                backoffSleepTask = nil
            }
        }
    }
}
