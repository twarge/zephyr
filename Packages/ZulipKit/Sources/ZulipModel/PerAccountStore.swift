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
        logger.info("offline restore: \(cached.count) messages in \((clock.now - start).ms, privacy: .public) ms")
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

    public func topicVisibility(streamId: Int, topic: String) -> TopicVisibilityPolicy {
        topicVisibility[TopicKey(streamId: streamId, topic: topic)] ?? .none
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

    public func moveMessage(_ messageId: Int, toTopic topic: String, propagateMode: String) {
        let connection = connection
        Task {
            try? await connection.moveMessage(
                messageId: messageId, newTopic: topic, propagateMode: propagateMode)
        }
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
            default:
                break
            }

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
