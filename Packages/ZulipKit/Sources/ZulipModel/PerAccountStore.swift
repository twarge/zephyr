import Foundation
import Observation
import ZulipAPI
import os

/// The consistent snapshot of one account's server state.
///
/// Invariant (the heart of the architecture): a `PerAccountStore` is only ever
/// (a) constructed from a `/register` initial snapshot, and (b) mutated by
/// `handleEvent` applying events from that snapshot's queue, in order, on the
/// main actor. On queue expiry or malformed events, the whole store is
/// discarded and rebuilt from a fresh snapshot (see `GlobalStore.rebuild`).
@MainActor
@Observable
public final class PerAccountStore {
    public let accountId: Account.ID
    public let selfUserId: Int
    public nonisolated let connection: ApiConnection
    public let queueId: String
    public var lastEventId: Int
    public let zulipFeatureLevel: Int
    public let eventQueueLongpollTimeoutSeconds: Int

    public private(set) var realmName: String?
    /// The realm's square icon (absolute, or relative to the realm URL).
    public private(set) var realmIconUrl: String?
    private var realmLogoUrl: String?
    private var realmLogoSource: String?
    private var realmNightLogoUrl: String?
    private var realmNightLogoSource: String?
    /// Pending reminders by reminder id (refetched, never event-decoded).
    public private(set) var reminders: [Int: Reminder] = [:]
    /// Every starred message id, server-wide (the sidebar count) — the
    /// cached message window only holds a slice of them.
    public private(set) var starredMessageIds: Set<Int> = []
    public private(set) var users: [Int: User] = [:]
    public private(set) var channels: [Int: ZulipStream] = [:]
    public private(set) var subscriptions: [Int: Subscription] = [:]
    /// Sidebar channel groupings (Zulip 12+), in display order.
    public private(set) var channelFolders: [ChannelFolder] = []
    /// Per-topic visibility overrides (muted/unmuted/followed), keyed by
    /// (streamId, case-folded topic).
    public private(set) var topicVisibility: [TopicKey: TopicVisibilityPolicy] = [:]

    public struct TopicKey: Hashable, Sendable {
        public var streamId: Int
        public var topic: String

        public init(streamId: Int, topic: String) {
            self.streamId = streamId
            self.topic = topic.lowercased()
        }
    }
    /// Custom emoji by id (reaction `emoji_code`).
    public private(set) var realmEmoji: [String: RealmEmojiItem] = [:]
    /// Canonical map of every message we've seen (fetched or via events).
    public private(set) var messages: [Int: Message] = [:]
    public let unreads: Unreads
    /// The unified sidebar model.
    public let conversations: ConversationList

    private struct WeakMessageList {
        weak var value: MessageListModel?
    }
    private var messageLists: [UUID: WeakMessageList] = [:]

    /// Server-synced drafts by id (the /drafts API); the app-layer sync
    /// engine reconciles these with the local draft store.
    public private(set) var serverDrafts: [Int: ServerDraft] = [:]
    /// Draft change notifications for the sync engine.
    public enum DraftChange: Sendable {
        case added([ServerDraft])
        case updated(ServerDraft)
        case removed(Int)
    }
    @ObservationIgnored public var draftEventObserver: ((DraftChange) -> Void)?

    /// Optimistically-sent messages awaiting their server echo event.
    public private(set) var outbox: [OutboxMessage] = []
    /// Idempotent mutations recorded while offline, replayed on reconnect.
    public private(set) var pendingActions: [PendingAction] = []
    /// Ids installed from the offline cache: a *fetched* copy replaces these
    /// (the usual reconcile rule is reversed — the server is fresher than
    /// last session's cache).
    private(set) var cachedMessageIds: Set<Int> = []
    @ObservationIgnored private let offline: OfflineStore?
    /// Full retained message history + FTS index (see `MessageDatabase`).
    @ObservationIgnored public private(set) var database: MessageDatabase?
    /// Days of on-disk message history to retain (nil = forever). Set by
    /// `GlobalStore` from app preferences.
    @ObservationIgnored public var messageRetentionDays: Int?
    @ObservationIgnored private var dirtyMessageIds: Set<Int> = []
    @ObservationIgnored private var cacheSaveTask: Task<Void, Never>?
    @ObservationIgnored private var isFlushing = false
    @ObservationIgnored private var flushRetryTask: Task<Void, Never>?
    @ObservationIgnored private var flushRetryAttempt = 0
    /// Who's typing where (from typing events).
    public let typing = TypingStatus()
    /// User presence (maintained by the ping loop).
    public let presence = Presence()
    public let presencePingIntervalSeconds: Int
    private let presenceOfflineThresholdSeconds: Int
    /// Unicode emoji (from server_emoji_data_url) + realm custom emoji, for
    /// pickers and :shortcode: autocomplete. Loaded lazily.
    public private(set) var emojiEntries: [EmojiEntry] = []

    private let serverEmojiDataUrl: String?
    private let typingStartedWaitMs: Int
    private let typingStoppedWaitMs: Int
    private let typingStartedExpiryMs: Int
    @ObservationIgnored private var emojiCatalogLoadStarted = false
    @ObservationIgnored private var typingSendState:
        [SendDestination: (lastStart: Date, stopTask: Task<Void, Never>)] = [:]

    /// True while the event stream is failing and being retried; UI shows a
    /// "connecting" banner.
    public var isRecoveringEventStream = false

    /// A bulk "mark all messages as read" sweep: non-nil while one runs,
    /// or while its outcome lingers for the sidebar's status footer.
    public enum MarkReadSweep: Equatable, Sendable {
        /// Batches are still processing; the count is messages marked so far.
        case running(markedCount: Int)
        /// The sweep reached the newest message; lingers briefly, then clears.
        case finished(markedCount: Int)
        /// A batch failed (usually offline); lingers briefly, then clears.
        case failed
    }
    public private(set) var markReadSweep: MarkReadSweep?
    @ObservationIgnored private var markReadSweepGeneration = 0

    private let logger = Logger(subsystem: "com.twarge.zephyr", category: "store")

    public init(
        account: Account, connection: ApiConnection, snapshot: InitialSnapshot,
        offline: OfflineStore? = nil
    ) {
        accountId = account.id
        selfUserId = account.userId
        self.connection = connection
        self.offline = offline
        queueId = snapshot.queueId
        lastEventId = snapshot.lastEventId
        zulipFeatureLevel = snapshot.zulipFeatureLevel
        eventQueueLongpollTimeoutSeconds = snapshot.eventQueueLongpollTimeoutSeconds ?? 90
        realmName = snapshot.realmName
        realmIconUrl = snapshot.realmIconUrl
        starredMessageIds = Set(snapshot.starredMessages ?? [])
        realmLogoUrl = snapshot.realmLogoUrl
        realmLogoSource = snapshot.realmLogoSource
        realmNightLogoUrl = snapshot.realmNightLogoUrl
        realmNightLogoSource = snapshot.realmNightLogoSource
        serverEmojiDataUrl = snapshot.serverEmojiDataUrl
        typingStartedWaitMs = snapshot.serverTypingStartedWaitPeriodMilliseconds ?? 10000
        typingStoppedWaitMs = snapshot.serverTypingStoppedWaitPeriodMilliseconds ?? 5000
        typingStartedExpiryMs = snapshot.serverTypingStartedExpiryPeriodMilliseconds ?? 15000
        presencePingIntervalSeconds = snapshot.serverPresencePingIntervalSeconds ?? 60
        presenceOfflineThresholdSeconds = snapshot.serverPresenceOfflineThresholdSeconds ?? 140

        let allUsers = (snapshot.realmUsers ?? [])
            + (snapshot.realmNonActiveUsers ?? [])
            + (snapshot.crossRealmBots ?? [])
        users = Dictionary(allUsers.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        channels = Dictionary(
            (snapshot.streams ?? []).map { ($0.streamId, $0) },
            uniquingKeysWith: { first, _ in first })
        subscriptions = Dictionary(
            (snapshot.subscriptions ?? []).map { ($0.streamId, $0) },
            uniquingKeysWith: { first, _ in first })
        unreads = Unreads(snapshot: snapshot.unreadMsgs, selfUserId: account.userId)
        conversations = ConversationList(snapshot: snapshot, selfUserId: account.userId)
        channelFolders = (snapshot.channelFolders ?? []).sorted { $0.order < $1.order }
        realmEmoji = snapshot.realmEmoji ?? [:]
        for draft in snapshot.drafts ?? [] {
            if let id = draft.id {
                serverDrafts[id] = draft
            }
        }
        for item in snapshot.userTopics ?? [] {
            let policy = TopicVisibilityPolicy(rawValue: item.visibilityPolicy) ?? .none
            if policy != .none {
                topicVisibility[TopicKey(streamId: item.streamId, topic: item.topicName)] = policy
            }
        }

        // Offline restore: the unsent outbox and actions recorded offline
        // last session load here (small files); the SQLite transcript
        // hydration is `restoreOfflineCache()`, kicked by the GlobalStore
        // after install — it decodes thousands of payloads and must not
        // block the main actor.
        if let offline {
            database = offline.openDatabase()
            outbox = offline.loadOutbox().map { entry in
                var restored = entry
                restored.state = entry.restoredState
                return restored
            }
            pendingActions = offline.loadPendingActions()
        }
    }

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
    }

    /// Hydrates recent transcripts from the SQLite store (also seeding
    /// sidebar recency). The read + payload decode (~130 ms for a few
    /// hundred cached conversations) runs off the main actor; only the
    /// dictionary merge happens here.
    public func restoreOfflineCache() async {
        guard let offline, let database else { return }
        let selfId = selfUserId
        let clock = ContinuousClock()
        let start = clock.now
        // Utility priority: at launch this runs alongside the live-snapshot
        // apply and first render — competing at high priority starved the
        // UI (354 ms cold vs 4.4 s measured mid-launch).
        let cached = await Task.detached(priority: .utility) { () -> [Message] in
            // One-time import of the pre-SQLite JSON cache.
            let legacy = offline.loadLegacyMessages()
            if !legacy.isEmpty {
                try? database.upsert(legacy, selfUserId: selfId)
                offline.removeLegacyMessages()
            }
            return (try? database.recentPerConversation(
                OfflineStore.messagesPerConversation)) ?? []
        }.value
        // Live data may have landed while we read; never clobber it.
        for message in cached where messages[message.id] == nil {
            messages[message.id] = message
            cachedMessageIds.insert(message.id)
        }
        conversations.seed(messages: cached, selfUserId: selfId)
        // Lists that opened before this restore landed (the launch-selected
        // view) found an empty map and may still be waiting on their fetch:
        // hand them the now-hydrated cache.
        forEachMessageList { $0.cacheDidRestore() }
        if Self.perfLogEnabled {
            logger.info("offline restore: \(cached.count) messages in \((clock.now - start).ms, privacy: .public) ms")
        }
    }

    // MARK: Message-list fan-out

    /// Events are applied to the canonical message map once, then fanned out
    /// to each registered (open) message list.
    public func register(_ list: MessageListModel) {
        messageLists[list.id] = WeakMessageList(value: list)
    }

    public func unregister(_ listId: UUID) {
        messageLists.removeValue(forKey: listId)
    }

    private func forEachMessageList(_ body: (MessageListModel) -> Void) {
        for (key, ref) in messageLists {
            if let list = ref.value {
                body(list)
            } else {
                messageLists.removeValue(forKey: key)
            }
        }
    }

    /// Seeds the sidebar's topic recency from a combined-feed fetch (DM
    /// recency comes from the register snapshot).
    public func seedConversations(count: Int = 100) async {
        guard let result = try? await connection.getMessages(
            anchor: .newest, numBefore: count, numAfter: 0)
        else { return }
        reconcileFetchedMessages(result.messages)
        conversations.seed(messages: result.messages, selfUserId: selfUserId)
    }

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
        for id in unreadIds {
            guard var message = messages[id] else { continue }
            var flags = Set(message.flags ?? [])
            flags.insert("read")
            message.flags = Array(flags)
            messages[id] = message
        }
        unreads.removeMessages(ids: unreadIds)
        forEachMessageList { $0.handleChangedMessages(ids: unreadIds) }
        scheduleMessageCacheSave(unreadIds)
        performOrQueue(.updateFlags(messageIds: unreadIds.sorted(), add: true, flag: "read"))
    }

    private func markRead(ids: [Int]) {
        unreads.removeMessages(ids: ids)
        performOrQueue(.updateFlags(messageIds: ids, add: true, flag: "read"))
    }

    /// Marks a single message unread (the swipe gesture). Optimistic flag
    /// flip plus local unread refile; syncs like any flag change.
    public func markMessageUnread(_ messageId: Int) {
        if var message = messages[messageId] {
            var flags = Set(message.flags ?? [])
            flags.remove("read")
            message.flags = Array(flags)
            messages[messageId] = message
            forEachMessageList { $0.handleChangedMessages(ids: [messageId]) }
            scheduleMessageCacheSave([messageId])
        }
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
    private func addReadFlag(narrow: [NarrowElement]) {
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
    private func clearMarkReadSweep(after generation: Int) async {
        try? await Task.sleep(for: .seconds(4))
        if markReadSweepGeneration == generation {
            markReadSweep = nil
        }
    }

    /// Clears the read flag from the anchor to the narrow's newest message,
    /// server-side over the full history. Local unreads refile when the
    /// resulting update_message_flags events arrive.
    private func removeReadFlag(narrow: [NarrowElement], startingAt start: MessageAnchor) {
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

    // MARK: Reminders

    /// Whether this realm's server has the reminders API (Zulip 11+).
    public var supportsReminders: Bool {
        zulipFeatureLevel >= ApiConnection.remindersFeatureLevel
    }

    /// Schedules a server-side reminder about a message, delivered as a DM
    /// from the reminders bot at the given time. The refetch that follows
    /// is the creation feedback — the message's clock icon appears.
    public func remindAboutMessage(_ messageId: Int, at date: Date) {
        let connection = connection
        Task {
            try? await connection.createReminder(
                messageId: messageId, deliveryTimestamp: Int(date.timeIntervalSince1970))
            await refreshReminders()
        }
    }

    public func cancelReminder(_ reminderId: Int) {
        // Optimistic; the refetch confirms.
        reminders.removeValue(forKey: reminderId)
        let connection = connection
        Task {
            try? await connection.deleteReminder(reminderId: reminderId)
            await refreshReminders()
        }
    }

    /// Refetches pending reminders — the register snapshot doesn't carry
    /// them, so launch, creation, cancellation, and reminder events all
    /// funnel through here.
    public func refreshReminders() async {
        guard supportsReminders,
              let fetched = try? await connection.getReminders() else { return }
        reminders = Dictionary(uniqueKeysWithValues: fetched.map { ($0.reminderId, $0) })
    }

    public func reminderForMessage(_ messageId: Int) -> Reminder? {
        reminders.values.first { $0.reminderTargetMessageId == messageId }
    }

    // MARK: Offline queue

    /// Runs one idempotent server mutation, or records it for replay when the
    /// network is down. Order is preserved: while a backlog exists, new
    /// actions join it instead of racing ahead of the replay.
    private func performOrQueue(_ action: PendingAction) {
        guard pendingActions.isEmpty else {
            pendingActions.append(action)
            persistPendingActions()
            return
        }
        Task {
            let endActivity = BackgroundActivity.begin("action")
            defer { endActivity() }
            do {
                try await perform(action)
            } catch where isTransientNetworkError(error) {
                pendingActions.append(action)
                persistPendingActions()
            } catch {
                // Server rejected it; the confirming event (or its absence)
                // corrects our optimistic local state.
            }
        }
    }

    private func perform(_ action: PendingAction) async throws {
        switch action {
        case .updateFlags(let ids, let add, let flag):
            try await connection.updateMessageFlags(
                messages: ids, op: add ? .add : .remove, flag: flag)
        case .reaction(let messageId, let add, let emojiName, let emojiCode, let reactionType):
            try await connection.updateReaction(
                messageId: messageId, add: add,
                emojiName: emojiName, emojiCode: emojiCode, reactionType: reactionType)
        }
    }

    /// Resends queued outbox messages and replays recorded actions, in order.
    /// Called when connectivity returns (event-poll recovery or the app's
    /// path monitor); a no-op when there's nothing waiting.
    public func flushPending() {
        // An external trigger implies real connectivity: restart the
        // self-retry ladder from the top.
        flushRetryAttempt = 0
        flushRetryTask?.cancel()
        flushRetryTask = nil
        flush()
    }

    private func flush() {
        guard !isFlushing else { return }
        isFlushing = true
        Task {
            let endActivity = BackgroundActivity.begin("offline-flush")
            defer { endActivity() }
            defer { isFlushing = false }
            // Give the recovering event stream a beat to deliver echoes
            // for sends that actually landed (their entries clear) before
            // resending ambiguous timed-out entries.
            for _ in 0..<6 where isRecoveringEventStream {
                try? await Task.sleep(for: .milliseconds(500))
            }
            for entry in outbox where entry.state == .queued {
                if let index = outbox.firstIndex(where: { $0.id == entry.id }) {
                    outbox[index].state = .sending
                }
                await performSend(localId: entry.id)
            }
            while let action = pendingActions.first {
                do {
                    try await perform(action)
                    pendingActions.removeFirst()
                } catch where isTransientNetworkError(error) {
                    break  // Still offline; keep the backlog for next time.
                } catch {
                    pendingActions.removeFirst()  // Rejected (e.g. duplicate): drop.
                }
            }
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
            if outbox.contains(where: { $0.state == .queued }) || !pendingActions.isEmpty {
                scheduleFlushRetry()
            }
        }
    }

    private func scheduleFlushRetry() {
        guard flushRetryTask == nil, flushRetryAttempt < 5 else { return }
        flushRetryAttempt += 1
        let delay = Duration.seconds(Double(flushRetryAttempt) * 2)
        flushRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushRetryTask = nil
            self.flush()
        }
    }

    private func persistOutbox() {
        offline?.saveOutbox(outbox)
    }

    private func persistPendingActions() {
        offline?.savePendingActions(pendingActions)
    }

    /// Marks messages dirty and schedules a debounced incremental upsert.
    private func scheduleMessageCacheSave(_ ids: some Sequence<Int>) {
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
            Task.detached(priority: .utility) {
                try? await database.upsertAsync(batch, selfUserId: selfId)
            }
        }
    }

    /// Prunes on-disk history past the retention window (starred messages
    /// are kept). Disk-level only — this session's in-memory map is
    /// untouched. Runs at store creation and when the setting changes.
    public func pruneMessageHistory() {
        guard let database, let days = messageRetentionDays else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        Task.detached(priority: .utility) {
            _ = try? database.prune(olderThan: cutoff)
        }
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

    /// A channel's recent topics from the local database — the offline
    /// seed the topics view renders while GET /topics is in flight.
    public func recentTopicsFromCache(streamId: Int) async -> [ChannelTopic] {
        guard let database else { return [] }
        return await Task.detached {
            (try? database.recentTopics(streamId: streamId)) ?? []
        }.value
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
        outbox.removeAll { $0.id == localId }
        persistOutbox()
    }

    private func performSend(localId: String) async {
        guard let message = outbox.first(where: { $0.id == localId }) else { return }
        let endActivity = BackgroundActivity.begin("send")
        defer { endActivity() }
        do {
            switch message.destination {
            case .topic(let streamId, let topic):
                _ = try await connection.sendChannelMessage(
                    streamId: streamId, topic: topic, content: message.content,
                    queueId: queueId, localId: localId)
            case .dm(let userIds):
                _ = try await connection.sendDirectMessage(
                    userIds: userIds, content: message.content,
                    queueId: queueId, localId: localId)
            }
            // Leave the entry in place: the echo event clears it (and may
            // already have, if it raced the response).
        } catch {
            if let index = outbox.firstIndex(where: { $0.id == localId }) {
                // Network failures (including timeouts and dropped
                // connections) queue for automatic resend on reconnect.
                // A timed-out send *may* have reached the server;
                // flushPending narrows the duplicate window by letting the
                // recovering event stream deliver the echo (which clears
                // the entry) before resending. Server rejections stay
                // failed and need a manual retry.
                outbox[index].state = isTransientNetworkError(error)
                    ? .queued
                    : .failed(error.localizedDescription)
            }
            persistOutbox()
        }
    }

    // MARK: Typing (send side)

    /// Call on every keystroke with content present: sends `start` throttled
    /// to the server's cadence and schedules an automatic `stop` on idle.
    public func typingActivity(in destination: SendDestination) {
        let now = Date.now
        let previous = typingSendState[destination]
        previous?.stopTask.cancel()
        var lastStart = previous?.lastStart
        if lastStart == nil
            || now.timeIntervalSince(lastStart!) * 1000 >= Double(typingStartedWaitMs) {
            sendTypingRequest(op: "start", destination: destination)
            lastStart = now
        }
        let stopTask = Task { [weak self, typingStoppedWaitMs] in
            try? await Task.sleep(for: .milliseconds(typingStoppedWaitMs))
            guard !Task.isCancelled else { return }
            self?.typingStopped(in: destination)
        }
        typingSendState[destination] = (lastStart ?? now, stopTask)
    }

    /// Call when composing ends (sent, cleared, or idle).
    public func typingStopped(in destination: SendDestination) {
        guard let state = typingSendState.removeValue(forKey: destination) else { return }
        state.stopTask.cancel()
        sendTypingRequest(op: "stop", destination: destination)
    }

    private func sendTypingRequest(op: String, destination: SendDestination) {
        let connection = connection
        Task {
            switch destination {
            case .topic(let streamId, let topic):
                try? await connection.setTyping(op: op, streamId: streamId, topic: topic)
            case .dm(let userIds):
                try? await connection.setTyping(op: op, userIds: userIds)
            }
        }
    }

    // MARK: Emoji catalog

    public func loadEmojiCatalogIfNeeded() {
        guard !emojiCatalogLoadStarted else { return }
        emojiCatalogLoadStarted = true
        let realmEntries = realmEmoji
            .filter { !$0.value.deactivated }
            .map { id, item in
                EmojiEntry(name: item.name, code: id, character: nil, realmSrc: item.sourceUrl)
            }
            .sorted { $0.name < $1.name }
        guard let urlString = serverEmojiDataUrl,
              let url = URL(string: urlString, relativeTo: connection.realmURL)?.absoluteURL
        else {
            emojiEntries = realmEntries
            return
        }
        Task { [weak self] in
            let unicodeEntries: [EmojiEntry]
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let parsed = try? EmojiCatalog.parse(data) {
                unicodeEntries = parsed
            } else {
                unicodeEntries = []
            }
            self?.emojiEntries = realmEntries + unicodeEntries
        }
    }

    /// Presence dot state for a user, using the server's offline threshold.
    public func presenceState(of userId: Int) -> PresenceState {
        presence.state(of: userId, offlineThresholdSeconds: presenceOfflineThresholdSeconds)
    }

    /// One presence ping: reports us active and merges everyone's deltas.
    func pingPresence() async {
        guard let result = try? await connection.updatePresence(
            status: "active", lastUpdateId: presence.lastUpdateId, newUserInput: false)
        else { return }
        presence.apply(result)
    }

    // MARK: Message actions

    public func toggleReaction(message: Message, emojiName: String, emojiCode: String, reactionType: String) {
        let mine = message.reactions.contains {
            $0.userId == selfUserId && $0.emojiCode == emojiCode
                && $0.reactionType == reactionType
        }
        // Optimistic local apply; the server's reaction event confirms
        // idempotently (its add/remove handlers tolerate the echo).
        if var current = messages[message.id] {
            if mine {
                current.reactions.removeAll {
                    $0.userId == selfUserId && $0.emojiCode == emojiCode
                        && $0.reactionType == reactionType
                }
            } else {
                current.reactions.append(
                    Reaction(
                        emojiName: emojiName, emojiCode: emojiCode,
                        reactionType: reactionType, userId: selfUserId))
            }
            messages[message.id] = current
            forEachMessageList { $0.handleChangedMessages(ids: [message.id]) }
            scheduleMessageCacheSave([message.id])
        }
        performOrQueue(
            .reaction(
                messageId: message.id, add: !mine,
                emojiName: emojiName, emojiCode: emojiCode, reactionType: reactionType))
    }

    public func setStarred(_ starred: Bool, messageId: Int) {
        // Optimistic; the flags event confirms.
        if starred {
            starredMessageIds.insert(messageId)
        } else {
            starredMessageIds.remove(messageId)
        }
        if var message = messages[messageId] {
            var flags = Set(message.flags ?? [])
            if starred { flags.insert("starred") } else { flags.remove("starred") }
            message.flags = Array(flags)
            messages[messageId] = message
            forEachMessageList { $0.handleChangedMessages(ids: [messageId]) }
            scheduleMessageCacheSave([messageId])
        }
        performOrQueue(.updateFlags(messageIds: [messageId], add: starred, flag: "starred"))
    }

    public func deleteMessage(_ messageId: Int) {
        let connection = connection
        Task {
            try? await connection.deleteMessage(messageId: messageId)
        }
    }

    public func setChannelMuted(_ streamId: Int, muted: Bool) {
        // Optimistic; the subscription/update event confirms.
        if var subscription = subscriptions[streamId] {
            subscription.isMuted = muted
            subscriptions[streamId] = subscription
        }
        let connection = connection
        Task {
            try? await connection.setSubscriptionProperty(
                streamId: streamId, property: "is_muted", value: muted)
        }
    }

    /// The wide organization logo to show, if the realm uploaded one — the
    /// generic default ("D") is Zulip's own logo, so it's skipped in favor
    /// of the realm icon. Dark appearance prefers an uploaded night
    /// variant.
    public func realmLogoPath(dark: Bool) -> String? {
        if dark, realmNightLogoSource == "U", let url = realmNightLogoUrl {
            return url
        }
        if realmLogoSource == "U" {
            return realmLogoUrl
        }
        return nil
    }

    /// Per-user pin: pinned channels sort to the top of their section.
    public func setChannelPinned(_ streamId: Int, pinned: Bool) {
        // Optimistic; the subscription/update event confirms.
        if var subscription = subscriptions[streamId] {
            subscription.pinToTop = pinned
            subscriptions[streamId] = subscription
        }
        let connection = connection
        Task {
            try? await connection.setSubscriptionProperty(
                streamId: streamId, property: "pin_to_top", value: pinned)
        }
    }

    /// Per-user "notify on all messages" in a channel.
    public func setChannelNotifies(_ streamId: Int, notifies: Bool) {
        if var subscription = subscriptions[streamId] {
            subscription.desktopNotifications = notifies
            subscriptions[streamId] = subscription
        }
        let connection = connection
        Task {
            try? await connection.setSubscriptionProperty(
                streamId: streamId, property: "desktop_notifications", value: notifies)
        }
    }

    /// Per-user channel color ("#rrggbb").
    public func setChannelColor(_ streamId: Int, hex: String) {
        if var subscription = subscriptions[streamId] {
            subscription.color = hex
            subscriptions[streamId] = subscription
        }
        let connection = connection
        Task {
            try? await connection.setSubscriptionProperty(
                streamId: streamId, property: "color", value: hex)
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
        let key = TopicKey(streamId: streamId, topic: topic)
        if policy == .none {
            topicVisibility.removeValue(forKey: key)
        } else {
            topicVisibility[key] = policy
        }
        let connection = connection
        Task {
            try? await connection.setTopicVisibility(
                streamId: streamId, topic: topic, policy: policy.rawValue)
        }
    }

    /// Toggle a poll vote (vote true adds, false retracts).
    public func voteInPoll(messageId: Int, optionKey: String, vote: Bool) {
        sendWidgetEvent(
            messageId: messageId,
            content: #"{"type":"vote","key":"\#(optionKey)","vote":\#(vote ? 1 : -1)}"#)
    }

    /// Appends an option to a poll (anyone may). The event's idx is this
    /// user's per-poll counter — replayed from the existing submessages so
    /// the option key ("\(selfUserId),\(idx)") never collides.
    public func addPollOption(messageId: Int, option: String) {
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var nextIdx = 1
        for submessage in messages[messageId]?.submessages?.dropFirst() ?? [] {
            guard submessage.senderId == selfUserId,
                  let data = submessage.content.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  event["type"] as? String == "new_option" else { continue }
            nextIdx = max(nextIdx, (event["idx"] as? Int ?? 0) + 1)
        }
        sendWidgetEventJSON(
            messageId: messageId,
            ["type": "new_option", "option": trimmed, "idx": nextIdx])
    }

    /// Sets a poll's question (the web app allows only the poll's author).
    public func setPollQuestion(messageId: Int, question: String) {
        sendWidgetEventJSON(
            messageId: messageId,
            ["type": "question", "question": question])
    }

    private func sendWidgetEventJSON(messageId: Int, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let content = String(data: data, encoding: .utf8) else { return }
        sendWidgetEvent(messageId: messageId, content: content)
    }

    /// Appends a task to a to-do list (anyone may); keys are per-sender
    /// counters like poll options.
    public func addTodoTask(messageId: Int, task: String, detail: String? = nil) {
        let trimmed = task.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var nextKey = 1
        for submessage in messages[messageId]?.submessages?.dropFirst() ?? [] {
            guard submessage.senderId == selfUserId,
                  let data = submessage.content.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  event["type"] as? String == "new_task" else { continue }
            nextKey = max(nextKey, (event["key"] as? Int ?? 0) + 1)
        }
        sendWidgetEventJSON(
            messageId: messageId,
            [
                "type": "new_task", "key": nextKey, "task": trimmed,
                "desc": detail?.trimmingCharacters(in: .whitespaces) ?? "",
                "completed": false,
            ])
    }

    /// Sets a to-do list's title (the web app allows only the author).
    public func setTodoListTitle(messageId: Int, title: String) {
        sendWidgetEventJSON(
            messageId: messageId,
            ["type": "new_task_list_title", "title": title])
    }

    /// Toggle a todo task's completion.
    public func strikeTodoTask(messageId: Int, taskKey: String) {
        sendWidgetEvent(
            messageId: messageId, content: #"{"type":"strike","key":"\#(taskKey)"}"#)
    }

    private func sendWidgetEvent(messageId: Int, content: String) {
        let connection = connection
        Task {
            try? await connection.sendSubmessage(messageId: messageId, content: content)
        }
    }

    public func subscribe(toChannel name: String) {
        let connection = connection
        Task {
            try? await connection.subscribe(toChannel: name)
        }
    }

    public func unsubscribe(fromChannel name: String) {
        let connection = connection
        Task {
            try? await connection.unsubscribe(fromChannel: name)
        }
    }

    /// Creates a channel and subscribes to it. Throws so creation UI can
    /// surface refusals (name taken, no permission); the subscription
    /// event delivers the new channel to the sidebar.
    public func createChannel(
        name: String, description: String, inviteOnly: Bool, announce: Bool
    ) async throws {
        try await connection.createChannel(
            name: name, description: description, inviteOnly: inviteOnly,
            announce: announce)
    }

    /// Archives a channel for everyone (admin-gated server-side; history
    /// is preserved). The stream delete/archived event removes it locally.
    public func archiveChannel(_ streamId: Int) {
        let connection = connection
        Task {
            try? await connection.archiveStream(streamId: streamId)
        }
    }

    // MARK: Subscriber management (throws so sheets can surface refusals)

    public func fetchSubscribers(streamId: Int) async throws -> [Int] {
        try await connection.getSubscribers(streamId: streamId)
    }

    public func addSubscriber(userId: Int, toChannel streamId: Int) async throws {
        guard let name = channels[streamId]?.name ?? subscriptions[streamId]?.name
        else { return }
        try await connection.subscribe(userIds: [userId], toChannel: name)
    }

    public func removeSubscriber(userId: Int, fromChannel streamId: Int) async throws {
        guard let name = channels[streamId]?.name ?? subscriptions[streamId]?.name
        else { return }
        try await connection.unsubscribe(userIds: [userId], fromChannel: name)
    }

    /// Restores an archived channel (admin-gated; feature level 388).
    /// Throws so the channel browser can surface refusals.
    public func unarchiveChannel(_ streamId: Int) async throws {
        try await connection.updateStream(streamId: streamId, isArchived: false)
    }

    /// Edits a channel's description for everyone. Optimistic; the
    /// stream/update event confirms.
    public func setChannelDescription(_ streamId: Int, description: String) {
        channels[streamId]?.description = description
        if var subscription = subscriptions[streamId] {
            subscription.description = description
            subscriptions[streamId] = subscription
        }
        let connection = connection
        Task {
            try? await connection.updateStream(streamId: streamId, description: description)
        }
    }

    /// Renames a channel for everyone. Optimistic; the stream/update event
    /// confirms (or, if the server refuses — permissions are server-side —
    /// the next register snapshot restores the real name).
    public func renameChannel(_ streamId: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        channels[streamId]?.name = trimmed
        if var subscription = subscriptions[streamId] {
            subscription.name = trimmed
            subscriptions[streamId] = subscription
        }
        let connection = connection
        Task {
            try? await connection.updateStream(streamId: streamId, newName: trimmed)
        }
    }

    public func editMessage(_ messageId: Int, content: String) {
        let connection = connection
        Task {
            try? await connection.editMessage(messageId: messageId, content: content)
        }
    }

    /// The raw Zulip markdown of a message (to prefill an edit).
    public func fetchRawContent(_ messageId: Int) async -> String? {
        try? await connection.getRawMessageContent(messageId: messageId)
    }

    /// Moves a message (and, per `propagateMode`, its topic neighbors) to
    /// another topic — and optionally another channel. Moving onto a topic
    /// that already exists merges into it.
    public func moveMessage(
        _ messageId: Int, toTopic topic: String, toChannel newStreamId: Int? = nil,
        propagateMode: String
    ) {
        let connection = connection
        Task {
            try? await connection.moveMessage(
                messageId: messageId, newTopic: topic, newStreamId: newStreamId,
                propagateMode: propagateMode)
        }
    }

    private func newestCachedMessageId(streamId: Int, topic: String) -> Int? {
        messages.values
            .filter { $0.streamId == streamId && $0.subject == topic }
            .map(\.id).max()
    }

    /// Resolves or unresolves a topic (web parity: a whole-topic move that
    /// adds or strips the ✔ prefix), anchored at its newest cached message.
    public func setTopicResolved(streamId: Int, topic: String, resolved: Bool) {
        guard TopicName.isResolved(topic) != resolved,
              let anchor = newestCachedMessageId(streamId: streamId, topic: topic)
        else { return }
        let newName = resolved
            ? TopicName.resolvedPrefix + TopicName.displayName(topic)
            : TopicName.displayName(topic)
        moveMessage(anchor, toTopic: newName, propagateMode: "change_all")
    }

    /// Renames a topic wholesale, anchored at its newest cached message; a
    /// resolved topic stays resolved under its new name.
    public func renameTopic(streamId: Int, topic: String, to newDisplayName: String) {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != TopicName.displayName(topic),
              let anchor = newestCachedMessageId(streamId: streamId, topic: topic)
        else { return }
        let newName = TopicName.isResolved(topic)
            ? TopicName.resolvedPrefix + trimmed : trimmed
        moveMessage(anchor, toTopic: newName, propagateMode: "change_all")
    }

    /// The whole conversation back to unread, across its full server-side
    /// history (the header's "Mark All as Unread").
    public func markConversationUnread(_ key: ConversationKey) {
        removeReadFlag(
            narrow: key.narrow(selfUserId: selfUserId).apiElements, startingAt: .oldest)
    }

    public func fetchReadReceipts(_ messageId: Int) async -> [Int]? {
        try? await connection.getReadReceipts(messageId: messageId)
    }

    public func fetchEditHistory(_ messageId: Int) async -> [EditHistoryEntry]? {
        try? await connection.getMessageHistory(messageId: messageId)
    }

    /// Adds fetched messages to the canonical map, applying zulip-flutter's
    /// reconcile rule: a message we already have wins over a fetched copy
    /// (events applied to it can't be replayed; the fetch may predate them).
    /// Exception: copies installed from the offline cache lose to a fetch —
    /// the server is fresher than last session.
    public func reconcileFetchedMessages(_ fetched: [Message]) {
        var written: [Int] = []
        for message in fetched {
            if var existing = messages[message.id], !cachedMessageIds.contains(message.id) {
                // A fetch can be NEWER than memory (strikes/votes/edits
                // made in a missed-event window) or OLDER (a fetch that
                // raced a live event) — adopt only what's provably newer.
                var changed = false
                // Submessages only ever grow: longer is newer.
                if (message.submessages?.count ?? 0) > (existing.submessages?.count ?? 0) {
                    existing.submessages = message.submessages
                    changed = true
                }
                // Content follows the edit clock; ties keep the live copy.
                if (message.lastEditTimestamp ?? 0) > (existing.lastEditTimestamp ?? 0) {
                    existing.content = message.content
                    existing.subject = message.subject
                    existing.lastEditTimestamp = message.lastEditTimestamp
                    changed = true
                }
                if changed {
                    messages[message.id] = existing
                    written.append(message.id)
                }
            } else {
                messages[message.id] = message
                cachedMessageIds.remove(message.id)
                written.append(message.id)
            }
        }
        guard !written.isEmpty else { return }
        // Other open lists showing these messages refresh too.
        forEachMessageList { $0.handleChangedMessages(ids: written) }
        scheduleMessageCacheSave(written)
    }

    public func handleEvent(_ event: Event) {
        guard Self.perfLogEnabled else {
            apply(event)
            return
        }
        let start = ContinuousClock.now
        apply(event)
        let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
        let name = Mirror(reflecting: event.kind).children.first?.label
            ?? String(describing: event.kind)
        recordEventPerf(name, ms: ms)
    }

    // MARK: Event perf probes (defaults write com.twarge.zephyr perfLog -bool YES)

    private static let perfLogEnabled = UserDefaults.standard.bool(forKey: "perfLog")
    private var perfEventCounts: [String: Int] = [:]
    private var perfEventMs: [String: Double] = [:]
    private var perfFlushScheduled = false

    private func recordEventPerf(_ name: String, ms: Double) {
        perfEventCounts[name, default: 0] += 1
        perfEventMs[name, default: 0] += ms
        guard !perfFlushScheduled else { return }
        perfFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            let summary = self.perfEventCounts
                .sorted { $0.value > $1.value }
                .map { name, count in
                    String(
                        format: "%@=%d (%.0fms)", name, count,
                        self.perfEventMs[name] ?? 0)
                }
                .joined(separator: " ")
            print(
                "perf events/5s [\(self.connection.realmURL.host() ?? "?")]: \(summary)")
            self.perfEventCounts = [:]
            self.perfEventMs = [:]
            self.perfFlushScheduled = false
        }
    }

    private func apply(_ event: Event) {
        switch event.kind {
        case .heartbeat:
            break

        case .message(let e):
            var message = e.message
            message.flags = e.flags
            messages[message.id] = message
            cachedMessageIds.remove(message.id)
            unreads.handleMessage(message, flags: e.flags)
            conversations.noteMessage(message, selfUserId: selfUserId)
            forEachMessageList { $0.handleNewMessage(message, selfUserId: selfUserId) }
            if let localId = e.localMessageId {
                outbox.removeAll { $0.id == localId }
                persistOutbox()
            }
            scheduleMessageCacheSave([message.id])

        case .updateMessage(let e):
            // Content edits touch messageId; topic/channel moves touch every
            // id in messageIds (subject/new_stream_id carry the target).
            let ids = e.messageIds ?? [e.messageId]
            for id in ids {
                guard var message = messages[id] else { continue }
                if id == e.messageId, let rendered = e.renderedContent {
                    message.content = rendered
                    message.lastEditTimestamp = e.editTimestamp ?? message.lastEditTimestamp
                }
                if let newTopic = e.subject {
                    message.subject = newTopic
                }
                if let newStream = e.newStreamId {
                    message.streamId = newStream
                }
                messages[id] = message
            }
            forEachMessageList { $0.handleChangedMessages(ids: ids) }
            scheduleMessageCacheSave(ids)

        case .deleteMessage(let e):
            for id in e.allIds {
                messages.removeValue(forKey: id)
                cachedMessageIds.remove(id)
            }
            unreads.removeMessages(ids: e.allIds)
            forEachMessageList { $0.handleDeletedMessages(ids: e.allIds) }
            dirtyMessageIds.subtract(e.allIds)
            if let database {
                let ids = e.allIds
                Task.detached(priority: .utility) {
                    try? database.delete(ids: ids)
                }
            }

        case .updateMessageFlags(let e):
            guard let op = UpdateFlagsOp(rawValue: e.op) else {
                logger.error("update_message_flags with unknown op \(e.op, privacy: .public)")
                break
            }
            let ids = e.all ? Array(messages.keys) : e.messages
            for id in ids {
                guard var message = messages[id] else { continue }
                var flags = Set(message.flags ?? [])
                switch op {
                case .add: flags.insert(e.flag)
                case .remove: flags.remove(e.flag)
                }
                message.flags = Array(flags)
                messages[id] = message
            }
            if e.flag == "starred" {
                switch op {
                case .add: starredMessageIds.formUnion(e.messages)
                case .remove:
                    if e.all {
                        starredMessageIds = []
                    } else {
                        starredMessageIds.subtract(e.messages)
                    }
                }
            }
            unreads.handleFlagsEvent(
                op: op, flag: e.flag, ids: e.messages, all: e.all,
                locate: { self.messages[$0] })
            forEachMessageList { $0.handleChangedMessages(ids: ids) }
            scheduleMessageCacheSave(ids)

        case .reaction(let e):
            guard var message = messages[e.messageId] else { break }
            switch e.op {
            case "add":
                if !message.reactions.contains(e.reaction) {
                    message.reactions.append(e.reaction)
                }
            case "remove":
                message.reactions.removeAll {
                    $0.userId == e.userId && $0.emojiCode == e.emojiCode
                        && $0.reactionType == e.reactionType
                }
            default:
                break
            }
            messages[e.messageId] = message
            forEachMessageList { $0.handleChangedMessages(ids: [e.messageId]) }
            scheduleMessageCacheSave([e.messageId])

        case .typing(let e):
            guard e.senderId != selfUserId else { break }
            let key: ConversationKey?
            if let streamId = e.streamId {
                key = .topic(streamId: streamId, topic: e.topic ?? "")
            } else if let recipients = e.recipients {
                key = Unreads.dmKey(
                    participantIds: recipients.map(\.userId), selfUserId: selfUserId)
            } else {
                key = nil
            }
            guard let key else { break }
            if e.op == "start" {
                typing.handleStart(
                    key: key, userId: e.senderId, expiryMilliseconds: typingStartedExpiryMs)
            } else {
                typing.handleStop(key: key, userId: e.senderId)
            }

        case .realmUserAdd(let user):
            users[user.userId] = user

        case .realmUserUpdate(let update):
            guard var user = users[update.userId] else { break }
            if let name = update.fullName { user.fullName = name }
            if let avatar = update.avatarUrl { user.avatarUrl = avatar }
            if let active = update.isActive { user.isActive = active }
            users[update.userId] = user

        case .realmUserRemove(let userId):
            users.removeValue(forKey: userId)

        case .subscriptionAdd(let subs):
            for sub in subs {
                subscriptions[sub.streamId] = sub
            }

        case .subscriptionRemove(let streamIds):
            for id in streamIds {
                subscriptions.removeValue(forKey: id)
            }

        case .subscriptionUpdate(let e):
            guard var subscription = subscriptions[e.streamId] else { break }
            switch e.property {
            case "is_muted":
                subscription.isMuted = e.boolValue ?? subscription.isMuted
            case "pin_to_top":
                subscription.pinToTop = e.boolValue ?? subscription.pinToTop
            case "desktop_notifications":
                subscription.desktopNotifications =
                    e.boolValue ?? subscription.desktopNotifications
            case "color":
                subscription.color = e.stringValue ?? subscription.color
            default:
                break
            }
            subscriptions[e.streamId] = subscription

        case .streamUpdate(let e):
            switch e.property {
            case "name":
                guard let name = e.stringValue else { break }
                channels[e.streamId]?.name = name
                if var subscription = subscriptions[e.streamId] {
                    subscription.name = name
                    subscriptions[e.streamId] = subscription
                }
            case "description":
                guard let description = e.stringValue else { break }
                channels[e.streamId]?.description = description
                if var subscription = subscriptions[e.streamId] {
                    subscription.description = description
                    subscriptions[e.streamId] = subscription
                }
            case "is_archived":
                // Archived reads as gone, like a stream delete.
                if e.boolValue == true {
                    channels.removeValue(forKey: e.streamId)
                    subscriptions.removeValue(forKey: e.streamId)
                }
            default:
                break
            }

        case .remindersChanged:
            Task { await refreshReminders() }

        case .streamCreate(let streams):
            for stream in streams {
                channels[stream.streamId] = stream
            }

        case .streamDelete(let streamIds):
            for id in streamIds {
                channels.removeValue(forKey: id)
                subscriptions.removeValue(forKey: id)
            }

        case .submessage(let e):
            guard var message = messages[e.messageId] else { break }
            var submessages = message.submessages ?? []
            submessages.append(
                Submessage(msgType: e.msgType, content: e.content, senderId: e.senderId))
            message.submessages = submessages
            messages[e.messageId] = message
            forEachMessageList { $0.handleChangedMessages(ids: [e.messageId]) }
            scheduleMessageCacheSave([e.messageId])

        case .draftsAdd(let drafts):
            for draft in drafts {
                if let id = draft.id {
                    serverDrafts[id] = draft
                }
            }
            draftEventObserver?(.added(drafts))

        case .draftsUpdate(let draft):
            if let id = draft.id {
                serverDrafts[id] = draft
            }
            draftEventObserver?(.updated(draft))

        case .draftsRemove(let draftId):
            serverDrafts.removeValue(forKey: draftId)
            draftEventObserver?(.removed(draftId))

        case .userTopic(let item):
            let key = TopicKey(streamId: item.streamId, topic: item.topicName)
            let policy = TopicVisibilityPolicy(rawValue: item.visibilityPolicy) ?? .none
            if policy == .none {
                topicVisibility.removeValue(forKey: key)
            } else {
                topicVisibility[key] = policy
            }

        case .unexpected(let type, let op):
            logger.debug(
                "ignoring unexpected event type=\(type, privacy: .public) op=\(op ?? "-", privacy: .public)")
        }
    }
}
