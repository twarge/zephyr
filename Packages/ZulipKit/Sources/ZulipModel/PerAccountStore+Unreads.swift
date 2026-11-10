import Foundation
import ZulipAPI
import os

/// Unread and visibility policy: what counts, what the home view shows,
/// and marking read or unread.
extension PerAccountStore {
    /// Marks a whole conversation read (the Messages-style behavior when a
    /// conversation is opened): optimistic local clear + server flag update;
    /// the resulting event confirms.
    public func markConversationRead(_ key: ConversationKey) {
        guard let ids = unreads.unreadIds[key], !ids.isEmpty else { return }
        markRead(ids: ids.sorted())
    }

    /// Marks every topic in a channel read (used when the channel feed is
    /// opened at the newest messages).
    public func markChannelRead(_ streamId: Int) {
        var ids: [Int] = []
        for (key, set) in unreads.unreadIds {
            if case .topic(let id, _) = key, id == streamId {
                ids.append(contentsOf: set)
            }
        }
        guard !ids.isEmpty else { return }
        markRead(ids: ids.sorted())
    }

    /// Marks specific messages read — visibility-based marking in
    /// cross-conversation feeds (a message scrolled into view counts as
    /// seen). Applies locally (flags + unreads) and syncs like any flag.
    public func markMessagesRead(ids: [Int]) {
        let unreadIds = ids.filter { !(messages[$0]?.flags ?? []).contains("read") }
        guard !unreadIds.isEmpty else { return }
        let changed = setFlagInMemory("read", true, ids: unreadIds)
        unreads.removeMessages(ids: unreadIds)
        notifyFlagsChanged(changed)
        performOrQueue(.updateFlags(messageIds: unreadIds.sorted(), add: true, flag: "read"))
    }

    /// Conversation/channel mark-read: the same path as visibility marking,
    /// so loaded copies and the cache flip too (not just the badges).
    func markRead(ids: [Int]) {
        markMessagesRead(ids: ids)
    }

    /// Sets or clears a flag on the loaded copies; returns the ids that
    /// changed. Callers fan out with `notifyFlagsChanged`.
    @discardableResult
    func setFlagInMemory(_ flag: String, _ isSet: Bool, ids: some Sequence<Int>) -> [Int] {
        var changed: [Int] = []
        for id in ids {
            guard var message = messages[id] else { continue }
            var flags = message.flags ?? []
            if isSet {
                guard !flags.contains(flag) else { continue }
                flags.append(flag)
            } else {
                guard flags.contains(flag) else { continue }
                flags.removeAll { $0 == flag }
            }
            message.flags = flags
            messages[id] = message
            changed.append(id)
        }
        return changed
    }

    func notifyFlagsChanged(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        forEachMessageList { $0.handleChangedMessages(ids: ids) }
        scheduleMessageCacheSave(ids)
    }

    /// Marks a single message unread (the swipe gesture). Optimistic flag
    /// flip plus local unread refile; syncs like any flag change.
    public func markMessageUnread(_ messageId: Int) {
        notifyFlagsChanged(setFlagInMemory("read", false, ids: [messageId]))
        unreads.handleFlagsEvent(
            op: .remove, flag: "read", ids: [messageId], all: false,
            locate: { self.messages[$0] })
        performOrQueue(.updateFlags(messageIds: [messageId], add: false, flag: "read"))
    }

    /// The web app's "Mark as unread from here": clears the read flag on
    /// this message and everything after it in its conversation, across the
    /// full server-side history. Local unreads refile when the resulting
    /// update_message_flags events arrive.
    public func markUnreadFromHere(_ message: Message) {
        guard let key = Unreads.conversationKey(for: message, selfUserId: selfUserId)
        else { return }
        removeReadFlag(
            narrow: key.narrow(selfUserId: selfUserId).apiElements,
            startingAt: .id(message.id))
    }

    /// The web app's "Mark all messages as unread" for a channel.
    public func markChannelUnread(_ streamId: Int) {
        removeReadFlag(
            narrow: [NarrowElement("channel", .int(streamId))], startingAt: .oldest)
    }

    /// The web app's "Mark all messages as read" for a channel: adds the
    /// read flag across the channel's full server-side history. (Unlike
    /// `markChannelRead`, which clears only locally-known unreads, this
    /// sweep also reaches history the register snapshot never carried.)
    public func markChannelAllRead(_ streamId: Int) {
        addReadFlag(narrow: [NarrowElement("channel", .int(streamId))])
    }

    /// "Mark all messages as read" account-wide (the Combined and Recent
    /// sidebar views): an empty narrow spans every message.
    public func markAllRead() {
        addReadFlag(narrow: [])
    }

    /// Adds the read flag over a narrow's full server-side history, oldest
    /// first — the web app's batched mark-all-as-read loop. Local unreads
    /// clear as each batch's update_message_flags event arrives;
    /// `markReadSweep` publishes the running count for the sidebar's
    /// status footer. One sweep runs at a time.
    func addReadFlag(narrow: [NarrowElement]) {
        if case .running = markReadSweep { return }
        markReadSweepGeneration += 1
        let generation = markReadSweepGeneration
        markReadSweep = .running(markedCount: 0)
        let connection = connection
        Task {
            var anchor = MessageAnchor.oldest
            var includeAnchor = true
            var marked = 0
            // Unbounded in principle (a first sweep can cover years of
            // history); the cap is runaway protection only.
            for _ in 0..<1000 {
                do {
                    let result = try await connection.updateMessageFlagsForNarrow(
                        anchor: anchor, includeAnchor: includeAnchor,
                        numBefore: 0, numAfter: 5000,
                        narrow: narrow, op: .add, flag: "read")
                    marked += result.updatedCount
                    guard !result.foundNewest, let last = result.lastProcessedId else { break }
                    markReadSweep = .running(markedCount: marked)
                    anchor = .id(last)
                    includeAnchor = false
                } catch {
                    markReadSweep = .failed
                    await clearMarkReadSweep(after: generation)
                    return
                }
            }
            markReadSweep = .finished(markedCount: marked)
            await clearMarkReadSweep(after: generation)
        }
    }

    /// Clears the lingering sweep outcome unless a newer sweep replaced it.
    func clearMarkReadSweep(after generation: Int) async {
        try? await Task.sleep(for: .seconds(4))
        if markReadSweepGeneration == generation {
            markReadSweep = nil
        }
    }

    /// Clears the read flag from the anchor to the narrow's newest message,
    /// server-side over the full history. Local unreads refile when the
    /// resulting update_message_flags events arrive.
    func removeReadFlag(narrow: [NarrowElement], startingAt start: MessageAnchor) {
        let connection = connection
        Task {
            var anchor = start
            var includeAnchor = true
            // Bounded continuation; each batch covers up to 5000 messages.
            for _ in 0..<20 {
                guard let result = try? await connection.updateMessageFlagsForNarrow(
                    anchor: anchor, includeAnchor: includeAnchor,
                    numBefore: 0, numAfter: 5000,
                    narrow: narrow, op: .remove, flag: "read")
                else { return }
                guard !result.foundNewest, let last = result.lastProcessedId else { return }
                anchor = .id(last)
                includeAnchor = false
            }
        }
    }

    public func topicVisibility(streamId: Int, topic: String) -> TopicVisibilityPolicy {
        topicVisibility[TopicKey(streamId: streamId, topic: topic)] ?? .none
    }

    /// Whether unreads in this conversation are surfaced anywhere in the
    /// UI. Channels the user muted or no longer subscribes to show no
    /// badge in the sidebar, so their unreads must not count toward the
    /// Combined row, the app badge, or the widget — except topics
    /// explicitly unmuted or followed inside a muted channel.
    public func isUnreadVisible(_ key: ConversationKey) -> Bool {
        switch key {
        case .dm:
            return true
        case .topic(let streamId, let topic):
            guard let subscription = subscriptions[streamId] else { return false }
            guard subscription.muted else { return true }
            switch topicVisibility(streamId: streamId, topic: topic) {
            case .unmuted, .followed: return true
            case .none, .muted: return false
            }
        }
    }

    /// Whether the home view (a Combined feed that hides muted
    /// conversations) shows this conversation — the client-side mirror of
    /// the server's `in:home` narrow, for what no fetch filters: live
    /// events and cached transcripts.
    public func isShownInHome(_ key: ConversationKey) -> Bool {
        switch key {
        case .dm:
            return true
        case .topic(let streamId, let topic):
            let policy = topicVisibility(streamId: streamId, topic: topic)
            if policy == .muted { return false }
            guard let subscription = subscriptions[streamId], subscription.muted
            else { return true }
            return policy == .unmuted || policy == .followed
        }
    }

    public func isShownInHome(_ message: Message) -> Bool {
        Unreads.conversationKey(for: message, selfUserId: selfUserId)
            .map(isShownInHome) ?? true
    }

    /// Unreads a Combined feed can resume at, and so the ones its badge
    /// should promise: surfaced in the UI, and actually in the feed.
    public func isCombinedUnread(_ key: ConversationKey, includesMuted: Bool) -> Bool {
        isUnreadVisible(key) && (includesMuted || isShownInHome(key))
    }

    public func combinedUnreadCount(includesMuted: Bool) -> Int {
        unreads.unreadIds.reduce(0) { total, entry in
            isCombinedUnread(entry.key, includesMuted: includesMuted)
                ? total + entry.value.count : total
        }
    }

    /// Mute state moved under the open home views: what became hidden
    /// leaves them, and a reveal refetches (only the server knows what
    /// belongs between the rows already there).
    func homeVisibilityDidChange(revealed: Bool) {
        forEachMessageList { $0.handleHomeVisibilityChange(revealed: revealed) }
    }

    /// Where a catch-up feed (Combined, a channel) opens: the oldest unread
    /// the UI surfaces in that narrow that is still recent enough to catch
    /// up on linearly — the same unreads the narrow's badge counts, so the
    /// badge and the opening position always agree. The server's
    /// `first_unread` can't answer this: across conversations it is nearly
    /// always something muted away or years stale.
    ///
    /// Unread ids carry no dates; the local message cache turns the
    /// staleness cutoff into an id floor (ids ascend with send time). A
    /// cache with nothing that old yields no floor — the caller verifies
    /// the fetched message's date.
    func resumeUnreadId(for narrow: Narrow, staleAfter age: TimeInterval) async -> Int? {
        var candidates: [Int] = []
        for (key, ids) in unreads.unreadIds {
            switch (narrow, key) {
            case (.combinedFeed(let includesMuted), _):
                guard isCombinedUnread(key, includesMuted: includesMuted) else { continue }
            case (.channel(let streamId), .topic(let keyStreamId, _)):
                guard keyStreamId == streamId else { continue }
            default:
                continue
            }
            candidates.append(contentsOf: ids)
        }
        guard !candidates.isEmpty else { return nil }
        let cutoff = Date.now.addingTimeInterval(-age)
        let cutoffTimestamp = Int(cutoff.timeIntervalSince1970)
        var floor = messages.values.lazy
            .filter { $0.timestamp < cutoffTimestamp }
            .map(\.id).max()
        if let database {
            let stored = await Task.detached {
                try? database.newestId(sentBefore: cutoff)
            }.value
            if let stored, stored > floor ?? .min { floor = stored }
        }
        return candidates.lazy.filter { $0 > floor ?? .min }.min()
    }

    /// The unread total the UI presents: `Unreads.totalCount` minus
    /// conversations hidden by muting or a dropped subscription.
    public var visibleUnreadCount: Int {
        unreads.unreadIds.reduce(0) { total, entry in
            isUnreadVisible(entry.key) ? total + entry.value.count : total
        }
    }

    /// Sets a topic's visibility (mute/unmute/follow) optimistically; the
    /// user_topic event confirms.
    public func setTopicVisibility(
        streamId: Int, topic: String, policy: TopicVisibilityPolicy
    ) {
        let previous = self.topicVisibility(streamId: streamId, topic: topic)
        applyTopicVisibility(streamId: streamId, topic: topic, policy: policy)
        let verb = switch policy {
        case .muted: "mute"
        case .followed: "follow"
        case .unmuted, .none: "update"
        }
        runAction("Couldn't \(verb) the topic") { connection in
            try await connection.setTopicVisibility(
                streamId: streamId, topic: topic, policy: policy.rawValue)
        } rollback: { [weak self] in
            guard let self, self.topicVisibility(streamId: streamId, topic: topic) == policy
            else { return }
            self.applyTopicVisibility(streamId: streamId, topic: topic, policy: previous)
        }
    }

    func applyTopicVisibility(
        streamId: Int, topic: String, policy: TopicVisibilityPolicy
    ) {
        let key = TopicKey(streamId: streamId, topic: topic)
        let conversation = ConversationKey.topic(streamId: streamId, topic: topic)
        let wasShown = isShownInHome(conversation)
        if policy == .none {
            topicVisibility.removeValue(forKey: key)
        } else {
            topicVisibility[key] = policy
        }
        if isShownInHome(conversation) != wasShown {
            homeVisibilityDidChange(revealed: !wasShown)
        }
    }

    /// The whole conversation back to unread, across its full server-side
    /// history (the header's "Mark All as Unread").
    public func markConversationUnread(_ key: ConversationKey) {
        removeReadFlag(
            narrow: key.narrow(selfUserId: selfUserId).apiElements, startingAt: .oldest)
    }
}
