import Foundation
import ZulipAPI
import os

/// Persistence: the offline restore, the SQLite message cache (through
/// its serial writer), offline reads and the in-memory bound.
extension PerAccountStore {
    /// Carries a replaced store instance's cached-message hydration across
    /// a store swap — no second database read, no contention with first
    /// render.
    public func adoptCachedMessages(from previous: PerAccountStore) {
        for (id, message) in previous.messages where messages[id] == nil {
            messages[id] = message
            cachedMessageIds.insert(id)
        }
        conversations.seed(
            messages: Array(previous.messages.values), selfUserId: selfUserId)
        topicActivity.seedMissing(Array(previous.messages.values))
        channelTopics.adopt(from: previous.channelTopics)
        topicLinks.adopt(from: previous.topicLinks)
        topicLinks.start()
        // Mark-unread refiles skipped at init (no messages yet) land now.
        reapplyPendingActionsLocally()
    }

    /// Hydrates recent transcripts from the SQLite store (also seeding
    /// sidebar recency). The read + payload decode (~130 ms for a few
    /// hundred cached conversations) runs off the main actor; only the
    /// dictionary merge happens here.
    public func restoreOfflineCache() async {
        await restoreOfflineCache(reading: startOfflineRead())
    }

    /// `restoreOfflineCache()` with its disk read under way at once rather
    /// than at the main actor's next turn — at launch that turn waits on
    /// AppKit building the first window.
    public func beginOfflineRestore() {
        let read = startOfflineRead()
        Task { await restoreOfflineCache(reading: read) }
    }

    /// The restore, its read already started elsewhere (at app init, off
    /// the main actor, beside the snapshot decode).
    public func beginOfflineRestore(reading read: Task<[Message], Never>) {
        Task { await restoreOfflineCache(reading: read) }
    }

    /// The restore's merge, for messages already read — at app init, so
    /// the window's first frame has its sidebar and feed.
    public func restoreOfflineCache(from cached: [Message]) {
        Task { await channelTopics.restore() }
        applyOfflineRestore(cached, deferringTopicActivity: true)
    }

    /// What the launch restore reads: the newest messages of each cached
    /// conversation (after a one-time import of the pre-SQLite cache).
    public nonisolated static func readOfflineCache(
        offline: OfflineStore, database: MessageDatabase, selfUserId: Int
    ) -> [Message] {
        let legacy = offline.loadLegacyMessages()
        if !legacy.isEmpty {
            try? database.upsert(legacy, selfUserId: selfUserId)
            offline.removeLegacyMessages()
        }
        return (try? database.recentPerConversation(OfflineStore.messagesPerConversation)) ?? []
    }

    func startOfflineRead() -> Task<[Message], Never>? {
        guard let offline, let database else { return nil }
        let selfId = selfUserId
        // Utility priority: at launch this runs alongside the live-snapshot
        // apply and first render — competing at high priority starved the
        // UI (354 ms cold vs 4.4 s measured mid-launch).
        return Task.detached(priority: .utility) {
            Self.readOfflineCache(offline: offline, database: database, selfUserId: selfId)
        }
    }

    func restoreOfflineCache(reading read: Task<[Message], Never>?) async {
        // Topic lists restore alongside, not after: a small file the
        // sidebar's expanded channels are waiting on.
        Task { await channelTopics.restore() }
        guard let read else { return }
        let clock = ContinuousClock()
        let start = clock.now
        let cached = await read.value
        applyOfflineRestore(cached)
        if Self.perfLogEnabled {
            logger.info("offline restore: \(cached.count) messages in \((clock.now - start).ms, privacy: .public) ms")
        }
    }

    /// `deferringTopicActivity` leaves Summary's seeding (tens of ms on
    /// thousands of messages, and debounced into its rebuild anyway) for
    /// the main actor's next turn, out of the first frame's way.
    func applyOfflineRestore(_ cached: [Message], deferringTopicActivity: Bool = false) {
        // Live data may have landed while we read; never clobber it.
        for message in cached where messages[message.id] == nil {
            messages[message.id] = message
            cachedMessageIds.insert(message.id)
        }
        conversations.seed(messages: cached, selfUserId: selfUserId)
        if deferringTopicActivity {
            Task { topicActivity.seedMissing(cached) }
        } else {
            topicActivity.seedMissing(cached)
        }
        // Mark-unread actions recorded offline refile now that their
        // messages are loadable (the init pass couldn't locate them).
        reapplyPendingActionsLocally()
        // Lists that opened before this restore landed (the launch-selected
        // view) found an empty map and may still be waiting on their fetch:
        // hand them the now-hydrated cache.
        forEachMessageList { $0.cacheDidRestore() }
        // After the restore read, so the backfill doesn't compete with it.
        topicLinks.start()
    }

    // MARK: Memory bound

    /// The canonical map's soft cap. Past it, the oldest messages nothing
    /// needs leave memory (the database keeps them; fetches bring them
    /// back).
    static let messageMemoryLimit = 20_000

    static let messageEvictionTarget = 15_000

    func scheduleEviction() {
        guard messages.count > Self.messageMemoryLimit, evictionTask == nil, !isRetired
        else { return }
        evictionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            self.evictionTask = nil
            self.evictMessages()
        }
    }

    /// Drops the oldest messages down to `target`, never one an open or
    /// parked list shows, an unread (mark-unread and resume bookkeeping
    /// locate them), or a send awaiting confirmation.
    func evictMessages(downTo target: Int = messageEvictionTarget) {
        guard messages.count > target else { return }
        // Pending edits reach the database before their copies go.
        persistMessageCache()
        var keep = Set(deliveredSends.values)
        forEachMessageList { keep.formUnion($0.retainedMessageIds) }
        for ids in unreads.unreadIds.values { keep.formUnion(ids) }
        let excess = messages.count - target
        let evicted = messages.keys.lazy.filter { !keep.contains($0) }.sorted().prefix(excess)
        for id in evicted {
            messages.removeValue(forKey: id)
            cachedMessageIds.remove(id)
        }
        if Self.perfLogEnabled {
            logger.info("evicted \(evicted.count) messages; \(self.messages.count) remain")
        }
    }

    /// Marks messages dirty and schedules a debounced incremental upsert.
    func scheduleMessageCacheSave(_ ids: some Sequence<Int>) {
        guard database != nil else { return }
        dirtyMessageIds.formUnion(ids)
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.persistMessageCache()
        }
    }

    /// Flushes dirty messages to the database now. Asynchronous (write off
    /// the main actor) by default; synchronous at shutdown so the write
    /// completes before exit.
    public func persistMessageCache(synchronously: Bool = false) {
        guard let database else { return }
        cacheSaveTask?.cancel()
        guard !dirtyMessageIds.isEmpty else { return }
        let batch = dirtyMessageIds.compactMap { messages[$0] }
        dirtyMessageIds = []
        let selfId = selfUserId
        if synchronously {
            try? database.upsert(batch, selfUserId: selfId)
        } else {
            let touchedLinks = batch.contains {
                $0.streamId != nil && TopicLink.mentionsNarrow($0.content)
            }
            // Through the serial writer: a delete enqueued after this
            // can't be overtaken (and the row resurrected).
            let write = database.enqueueWrite { try? $0.upsert(batch, selfUserId: selfId) }
            cacheWriteTask = Task { [weak self] in
                await write.value
                self?.topicLinks.databaseDidChange(touchedLinks: touchedLinks)
            }
        }
    }

    /// Queues a write of stored copies the in-memory map doesn't hold, in
    /// order with every other write, then refreshes the link index.
    func writeUnloaded(
        touchedLinks: Bool, _ work: @escaping @Sendable (MessageDatabase, Int) -> Void
    ) {
        guard let database else { return }
        let selfId = selfUserId
        let write = database.enqueueWrite { work($0, selfId) }
        Task { [weak self] in
            await write.value
            self?.topicLinks.databaseDidChange(touchedLinks: touchedLinks)
        }
    }

    /// Writes dirty messages now and waits for the write to land — for a
    /// database read that must see them.
    func flushMessageCache() async {
        persistMessageCache()
        await cacheWriteTask?.value
    }

    /// Prunes on-disk history past the retention window (starred messages
    /// are kept). Disk-level only — this session's in-memory map is
    /// untouched. Runs at store creation and when the setting changes.
    public func pruneMessageHistory() {
        guard let database, let days = messageRetentionDays else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        database.enqueueWrite { _ = try? $0.prune(olderThan: cutoff) }
    }

    // MARK: Offline reads (transcript paging + search)

    /// Older messages for a narrow from the local database, for scrollback
    /// when the network fetch fails.
    func olderFromCache(than id: Int, narrow: Narrow, limit: Int = 100) async -> [Message] {
        guard let database,
              let filter = MessageDatabase.Filter(narrow: narrow, selfUserId: selfUserId)
        else { return [] }
        return await Task.detached {
            (try? database.older(than: id, matching: filter, limit: limit)) ?? []
        }.value
    }

    /// Full-text search against the local index, for offline search.
    func searchOffline(_ text: String) async -> [Message] {
        guard let database else { return [] }
        return await Task.detached {
            (try? database.search(text)) ?? []
        }.value
    }

    /// Installs database-restored copies into the canonical map the same
    /// way the launch restore does: marked cached, so any fetched copy
    /// replaces them (the server is fresher than last session). Copies
    /// already in memory win — events applied to them can't be replayed.
    func installCachedMessages(_ batch: [Message]) {
        for message in batch where messages[message.id] == nil {
            messages[message.id] = message
            cachedMessageIds.insert(message.id)
        }
        conversations.seed(messages: batch, selfUserId: selfUserId)
        scheduleEviction()
    }

    /// Realm branding (logo/icon) bytes persisted for offline launches.
    /// Nonisolated: callers read them off the main actor before the first
    /// toolbar render.
    public nonisolated func cachedBrandImageData(key: String) -> Data? {
        offline?.loadBrandImage(key: key)
    }

    public nonisolated func saveBrandImageData(_ data: Data, key: String) {
        offline?.saveBrandImage(data, key: key)
    }
}
