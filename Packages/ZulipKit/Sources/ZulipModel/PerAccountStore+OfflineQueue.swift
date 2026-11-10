import Foundation
import ZulipAPI
import os

/// The offline queue, the outbox and store handover: optimistic sends
/// and idempotent actions recorded while offline, replayed in order.
extension PerAccountStore {
    // MARK: Offline queue

    /// Re-applies recorded offline actions to freshly-built local state. Any
    /// snapshot — the disk cache at an offline relaunch, or a fresh register
    /// after an event-queue rebuild — predates the queued mutations, so
    /// without this, unreads cleared (and stars set) offline resurrect until
    /// the replay's confirming events arrive. Idempotent; runs again after
    /// cache hydration, when mark-unread refiles can locate their messages.
    /// (Reactions need no pass: the message cache saved them optimistically.)
    func reapplyPendingActionsLocally() {
        for case .updateSettings(let enterSends) in pendingActions {
            serverEnterSends = enterSends
        }
        for case .updateFlags(let ids, let add, let flag) in pendingActions {
            switch flag {
            case "read":
                unreads.handleFlagsEvent(
                    op: add ? .add : .remove, flag: flag, ids: ids, all: false,
                    locate: { self.messages[$0] })
            case "starred":
                if add {
                    starredMessageIds.formUnion(ids)
                } else {
                    starredMessageIds.subtract(ids)
                }
            default:
                break
            }
        }
    }

    /// Changes the server's Enter-sends setting, queued for replay when
    /// offline. Applied locally at once; the server's echo confirms it.
    public func setEnterSends(_ enterSends: Bool) {
        guard serverEnterSends != enterSends else { return }
        serverEnterSends = enterSends
        // Queued changes replay in order, so the last one stands.
        performOrQueue(.updateSettings(enterSends: enterSends))
    }

    /// Runs one idempotent server mutation, or records it for replay when the
    /// network is down. Order is preserved: actions run one at a time, and
    /// while a backlog exists new ones join it instead of racing ahead of
    /// the replay.
    func performOrQueue(_ action: PendingAction) {
        guard pendingActions.isEmpty else {
            enqueuePendingAction(action)
            return
        }
        let previous = actionChain
        actionChain = Task {
            await previous?.value
            // An earlier action failed into the backlog (or this store was
            // replaced) while this one waited its turn.
            guard !isRetired, pendingActions.isEmpty else {
                enqueuePendingAction(action)
                return
            }
            let endActivity = BackgroundActivity.begin("action")
            defer { endActivity() }
            do {
                try await perform(action)
            } catch where isTransientNetworkError(error) {
                enqueuePendingAction(action)
                // The long-poll may be healthy (one dropped request), so
                // no recovery flush is coming: retry on the ladder.
                (successor ?? self).scheduleFlushRetry()
            } catch {
                if let delay = rateLimitRetryDelay(error) {
                    // Rate-limited: nothing executed. Queue for replay, and
                    // schedule the flush ourselves — the connectivity
                    // triggers won't fire, since the network is fine.
                    enqueuePendingAction(action)
                    (successor ?? self).scheduleFlushRetry(after: delay)
                }
                // Otherwise the server rejected it; the confirming event
                // (or its absence) corrects our optimistic local state.
            }
        }
    }

    /// Appends to the replay backlog — the successor's, once retired.
    func enqueuePendingAction(_ action: PendingAction) {
        if isRetired, let successor {
            successor.enqueuePendingAction(action)
            return
        }
        pendingActions.append(action)
        persistPendingActions()
    }

    func perform(_ action: PendingAction) async throws {
        switch action {
        case .updateFlags(let ids, let add, let flag):
            try await connection.updateMessageFlags(
                messages: ids, op: add ? .add : .remove, flag: flag)
        case .reaction(let messageId, let add, let emojiName, let emojiCode, let reactionType):
            try await connection.updateReaction(
                messageId: messageId, add: add,
                emojiName: emojiName, emojiCode: emojiCode, reactionType: reactionType)
        case .updateSettings(let enterSends):
            try await connection.updateSettings(enterSends: enterSends)
        }
    }

    /// Resends queued outbox messages and replays recorded actions, in order.
    /// Called when connectivity returns (event-poll recovery or the app's
    /// path monitor); a no-op when there's nothing waiting.
    public func flushPending() {
        guard !isRetired else { return }
        // An external trigger implies real connectivity: restart the
        // self-retry ladder from the top.
        flushRetryAttempt = 0
        flushRetryTask?.cancel()
        flushRetryTask = nil
        flush()
    }

    func flush() {
        guard !isFlushing, !isRetired else { return }
        isFlushing = true
        Task {
            let endActivity = BackgroundActivity.begin("offline-flush")
            defer { endActivity() }
            defer { isFlushing = false }
            // Give the recovering event stream a beat to deliver echoes
            // for sends that actually landed (their entries clear) before
            // resending ambiguous timed-out entries.
            for _ in 0..<6 where isRecoveringEventStream && !isRetired {
                try? await Task.sleep(for: .milliseconds(500))
            }
            for entry in outbox where entry.state == .queued {
                guard !isRetired else { return }
                guard let index = outbox.firstIndex(where: { $0.id == entry.id }),
                      outbox[index].state == .queued
                else { continue }
                outbox[index].state = .sending
                await performSend(localId: entry.id)
            }
            var rateLimitDelay: Duration?
            var stillOffline = false
            // Behind any live action still in flight, so replay keeps order.
            await actionChain?.value
            while !isRetired, let action = pendingActions.first {
                do {
                    try await perform(action)
                    if pendingActions.first == action { pendingActions.removeFirst() }
                } catch where isTransientNetworkError(error) {
                    stillOffline = true
                    break  // Still offline; keep the backlog for next time.
                } catch {
                    if let delay = rateLimitRetryDelay(error) {
                        rateLimitDelay = delay
                        break  // Keep the backlog; resume after the delay.
                    }
                    // Rejected (e.g. duplicate): drop.
                    if pendingActions.first == action { pendingActions.removeFirst() }
                }
            }
            guard !isRetired else { return }
            persistPendingActions()
            // Transcripts rendered from the offline cache may be stale.
            forEachMessageList { $0.refetchIfOfflineFallback() }
            // A send whose echo landed in a mid-history window (its
            // send-time jump failed) stays invisible until a fetch reaches
            // the newest messages again — re-run that jump now.
            forEachMessageList { $0.recoverBuriedOwnSends() }
            // The path monitor often fires before sockets are actually
            // usable; if work still failed, retry on a short ladder
            // instead of waiting out the event loop's next recovery.
            if let rateLimitDelay {
                scheduleFlushRetry(after: rateLimitDelay)
            } else if stillOffline || outbox.contains(where: { $0.state == .queued })
                        || !pendingActions.isEmpty {
                scheduleFlushRetry()
            } else {
                flushRetryAttempt = 0
            }
        }
    }

    /// Schedules the next flush attempt: a short escalating ladder for
    /// network-path flapping, or — when the server rate-limited us — its
    /// advertised retry-after delay, which doesn't consume the ladder
    /// (each such attempt is server-sanctioned).
    func scheduleFlushRetry(after override: Duration? = nil) {
        guard flushRetryTask == nil, !isRetired else { return }
        let delay: Duration
        if let override {
            delay = override
        } else {
            guard flushRetryAttempt < 5 else { return }
            flushRetryAttempt += 1
            delay = .seconds(Double(flushRetryAttempt) * 2)
        }
        flushRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushRetryTask = nil
            self.flush()
        }
    }

    // A replaced store's files belong to its successor.

    func persistOutbox() {
        guard ownsFiles else { return }
        offline?.saveOutbox(outbox)
    }

    func persistPendingActions() {
        guard ownsFiles else { return }
        offline?.savePendingActions(pendingActions)
    }

    // MARK: Store handover

    /// Takes over a replaced instance's unsent work in memory (a rebuild
    /// or provisional → live swap): the outbox with its in-flight states,
    /// the replay backlog, and sends already accepted. The old instance
    /// retires — no more flushing or file writes — so nothing is sent
    /// twice and the two never overwrite each other's files.
    public func adoptPendingWork(from previous: PerAccountStore) {
        guard previous !== self, !previous.isRetired else { return }
        previous.retire(handingOverTo: self)
        let delivered = previous.deliveredSends
        // Accepted by the server, but the echo died with the old queue:
        // the message itself arrives through fetches, not the outbox.
        outbox = previous.outbox.filter { delivered[$0.id] == nil }
        pendingActions = previous.pendingActions
        persistOutbox()
        persistPendingActions()
        reapplyPendingActionsLocally()
    }

    /// Stops this instance's background work. With a successor, results of
    /// requests still in flight forward to it and the files are its alone.
    public func retire(handingOverTo successor: PerAccountStore? = nil) {
        guard !isRetired else { return }
        persistMessageCache()
        isRetired = true
        // Disabled or removed (no successor): still the files' owner, so a
        // late send result lands on disk for the next session.
        ownsFiles = successor == nil
        self.successor = successor
        flushRetryTask?.cancel()
        flushRetryTask = nil
        evictionTask?.cancel()
        for state in typingSendState.values { state.stopTask.cancel() }
        typingSendState = [:]
    }

    // MARK: Sending

    /// Sends optimistically: an outbox entry appears in matching lists
    /// immediately; the server's echo event (local_message_id) replaces it.
    public func send(_ content: String, to destination: SendDestination) {
        let localId = UUID().uuidString
        outbox.append(
            OutboxMessage(
                id: localId, destination: destination, content: content,
                timestamp: Int(Date.now.timeIntervalSince1970), state: .sending))
        persistOutbox()
        Task { await performSend(localId: localId) }
    }

    public func retrySend(_ localId: String) {
        guard let index = outbox.firstIndex(where: { $0.id == localId }) else { return }
        outbox[index].state = .sending
        persistOutbox()
        Task { await performSend(localId: localId) }
    }

    public func discardSend(_ localId: String) {
        deliveredSends[localId] = nil
        outbox.removeAll { $0.id == localId }
        persistOutbox()
    }

    func performSend(localId: String) async {
        guard let message = outbox.first(where: { $0.id == localId }) else { return }
        let endActivity = BackgroundActivity.begin("send")
        defer { endActivity() }
        do {
            let messageId: Int
            switch message.destination {
            case .topic(let streamId, let topic):
                messageId = try await connection.sendChannelMessage(
                    streamId: streamId, topic: topic, content: message.content,
                    queueId: queueId, localId: localId)
            case .dm(let userIds):
                messageId = try await connection.sendDirectMessage(
                    userIds: userIds, content: message.content,
                    queueId: queueId, localId: localId)
            }
            // Leave the entry in place: the echo event clears it (and may
            // already have, if it raced the response).
            if isRetired {
                // Our queue is gone, so its echo never comes.
                successor?.sendWasAccepted(localId: localId, messageId: messageId, echoLost: true)
            } else {
                sendWasAccepted(localId: localId, messageId: messageId, echoLost: false)
            }
        } catch {
            // Network failures (including timeouts and dropped
            // connections) queue for automatic resend. A timed-out send
            // *may* have reached the server; the flush narrows the
            // duplicate window by letting the recovering event stream
            // deliver the echo (which clears the entry) before resending.
            // Server rejections stay failed and need a manual retry.
            let state: OutboxMessage.State
            var retryDelay: Duration??
            if let delay = rateLimitRetryDelay(error) {
                // Rate-limited: the send never executed, so a resend
                // can't duplicate. Connectivity triggers won't fire (the
                // network is fine) — schedule the flush ourselves.
                state = .queued
                retryDelay = .some(delay)
            } else if isTransientNetworkError(error) {
                state = .queued
                // The long-poll can stay healthy through one failed
                // request, so no recovery flush would come: retry.
                retryDelay = .some(nil)
            } else {
                state = .failed(error.localizedDescription)
            }
            let owner = isRetired ? successor : self
            owner?.sendDidFail(localId: localId, state: state, retryAfter: retryDelay)
        }
    }

    func sendWasAccepted(localId: String, messageId: Int, echoLost: Bool) {
        // The echo may already have cleared it.
        guard outbox.contains(where: { $0.id == localId }) else { return }
        if echoLost || messages[messageId] != nil {
            // Delivered, and no echo will clear it (or the message already
            // arrived without our local id): the entry is done — fetches
            // bring the message itself.
            outbox.removeAll { $0.id == localId }
            persistOutbox()
        } else {
            deliveredSends[localId] = messageId
        }
    }

    func sendDidFail(localId: String, state: OutboxMessage.State, retryAfter: Duration??) {
        if let index = outbox.firstIndex(where: { $0.id == localId }) {
            outbox[index].state = state
        }
        persistOutbox()
        if let retryAfter { scheduleFlushRetry(after: retryAfter) }
    }

    /// Clears outbox entries a message event (or fetch) proves delivered.
    func clearDeliveredSends(messageIds: some Sequence<Int>) {
        guard !deliveredSends.isEmpty else { return }
        let ids = Set(messageIds)
        let done = deliveredSends.filter { ids.contains($0.value) }.map(\.key)
        guard !done.isEmpty else { return }
        for localId in done { deliveredSends[localId] = nil }
        outbox.removeAll { done.contains($0.id) }
        persistOutbox()
    }
}
