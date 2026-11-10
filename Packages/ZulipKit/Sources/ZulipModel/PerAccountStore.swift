import Foundation
import Observation
import ZulipAPI
import os

/// A server mutation the user asked for that didn't go through (the
/// optimistic change, where there was one, is rolled back). The UI shows
/// the newest one, then calls `clearActionFailure()`.
public struct ActionFailure: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let message: String

    init(id: UUID = UUID(), message: String) {
        self.id = id
        self.message = message
    }
}

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
    /// The server's Enter-sends setting (nil when the snapshot predates
    /// fetching it), kept live by `user_settings` events and reflecting a
    /// change still queued for replay.
    public internal(set) var serverEnterSends: Bool?

    public internal(set) var realmName: String?
    /// The realm's square icon (absolute, or relative to the realm URL).
    public internal(set) var realmIconUrl: String?
    var realmLogoUrl: String?
    var realmLogoSource: String?
    var realmNightLogoUrl: String?
    var realmNightLogoSource: String?
    /// Pending reminders by reminder id (refetched, never event-decoded).
    public internal(set) var reminders: [Int: Reminder] = [:]
    /// Every starred message id, server-wide (the sidebar count) — the
    /// cached message window only holds a slice of them.
    public internal(set) var starredMessageIds: Set<Int> = []
    public internal(set) var users: [Int: User] = [:]
    public internal(set) var channels: [Int: ZulipStream] = [:]
    public internal(set) var subscriptions: [Int: Subscription] = [:]
    /// Sidebar channel groupings (Zulip 12+), in display order.
    public internal(set) var channelFolders: [ChannelFolder] = []
    /// Folders archived mid-session, kept so an unarchive restores them.
    @ObservationIgnored var archivedChannelFolders: [Int: ChannelFolder] = [:]
    /// Per-topic visibility overrides (muted/unmuted/followed), keyed by
    /// (streamId, case-folded topic).
    public internal(set) var topicVisibility: [TopicKey: TopicVisibilityPolicy] = [:]

    public struct TopicKey: Hashable, Sendable {
        public var streamId: Int
        public var topic: String

        public init(streamId: Int, topic: String) {
            self.streamId = streamId
            self.topic = topic.lowercased()
        }
    }
    /// Custom emoji by id (reaction `emoji_code`).
    public internal(set) var realmEmoji: [String: RealmEmojiItem] = [:]
    /// Canonical map of every message we've seen (fetched or via events).
    public internal(set) var messages: [Int: Message] = [:]
    public let unreads: Unreads
    /// The unified sidebar model.
    public let conversations: ConversationList
    public let topicActivity: TopicActivityStore
    /// Per-channel topic lists, persisted for offline use.
    public let channelTopics: ChannelTopicCache
    /// Which conversations link to which (the topic menu's View Links).
    public let topicLinks: TopicLinkIndex

    struct WeakMessageList {
        weak var value: MessageListModel?
    }
    var messageLists: [UUID: WeakMessageList] = [:]

    /// Server-synced drafts by id (the /drafts API); the app-layer sync
    /// engine reconciles these with the local draft store.
    public internal(set) var serverDrafts: [Int: ServerDraft] = [:]
    /// Draft change notifications for the sync engine.
    public enum DraftChange: Sendable {
        case added([ServerDraft])
        case updated(ServerDraft)
        case removed(Int)
    }
    @ObservationIgnored public var draftEventObserver: ((DraftChange) -> Void)?

    /// Optimistically-sent messages awaiting their server echo event.
    public internal(set) var outbox: [OutboxMessage] = []
    /// Idempotent mutations recorded while offline, replayed on reconnect.
    public internal(set) var pendingActions: [PendingAction] = []
    /// Ids installed from the offline cache: a *fetched* copy replaces these
    /// (the usual reconcile rule is reversed — the server is fresher than
    /// last session's cache).
    var cachedMessageIds: Set<Int> = []
    @ObservationIgnored let offline: OfflineStore?
    /// Full retained message history + FTS index (see `MessageDatabase`).
    @ObservationIgnored public internal(set) var database: MessageDatabase?
    /// Days of on-disk message history to retain (nil = forever). Set by
    /// `GlobalStore` from app preferences.
    @ObservationIgnored public var messageRetentionDays: Int?
    @ObservationIgnored var dirtyMessageIds: Set<Int> = []
    @ObservationIgnored var cacheSaveTask: Task<Void, Never>?
    /// The latest flush's write, for readers that need it landed.
    @ObservationIgnored var cacheWriteTask: Task<Void, Never>?
    @ObservationIgnored var isFlushing = false
    @ObservationIgnored var flushRetryTask: Task<Void, Never>?
    @ObservationIgnored var flushRetryAttempt = 0
    /// Who's typing where (from typing events).
    public let typing = TypingStatus()
    /// User presence (maintained by the ping loop).
    public let presence = Presence()
    public let presencePingIntervalSeconds: Int
    let presenceOfflineThresholdSeconds: Int
    /// Unicode emoji (from server_emoji_data_url) + realm custom emoji, for
    /// pickers and :shortcode: autocomplete. Loaded lazily.
    public internal(set) var emojiEntries: [EmojiEntry] = []

    let serverEmojiDataUrl: String?
    let typingStartedWaitMs: Int
    let typingStoppedWaitMs: Int
    let typingStartedExpiryMs: Int
    @ObservationIgnored var emojiCatalogLoadStarted = false
    @ObservationIgnored var unicodeEmojiEntries: [EmojiEntry] = []
    @ObservationIgnored var typingSendState:
        [SendDestination: (lastStart: Date, stopTask: Task<Void, Never>)] = [:]

    /// True while the event stream is failing and being retried; UI shows a
    /// "connecting" banner.
    public var isRecoveringEventStream = false

    /// The newest compose preview re-rendered with link previews
    /// (`url_embed_data`, Zulip 13+). Only the latest is kept, as the server
    /// keeps only each user's latest render; `previewEmbedsHTML(for:)`
    /// matches it to a preview.
    public internal(set) var previewEmbeds: PreviewEmbeds?

    public struct PreviewEmbeds: Equatable, Sendable {
        public var eventId: Int
        /// The draft markdown that was re-rendered.
        public var content: String
        public var renderedContent: String
    }

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
    public internal(set) var markReadSweep: MarkReadSweep?
    @ObservationIgnored var markReadSweepGeneration = 0

    /// The server rejected this account's credentials (revoked API key,
    /// deactivated user or realm): event polling stopped, and only signing
    /// in again (re-adding the account) recovers. The UI shows a
    /// signed-out state rather than the reconnecting banner.
    public internal(set) var needsReauthentication = false

    func markNeedsReauthentication() {
        needsReauthentication = true
        isRecoveringEventStream = false
        flushRetryTask?.cancel()
        flushRetryTask = nil
    }

    public typealias ActionFailure = ZulipModel.ActionFailure
    /// The newest user action the server refused or never received.
    public internal(set) var lastActionFailure: ActionFailure?

    /// Optimistic actions run one at a time, in the order they were made
    /// (star then unstar must land in that order).
    @ObservationIgnored var actionChain: Task<Void, Never>?
    /// Sends the server accepted (local id → message id) whose echo hasn't
    /// cleared the outbox entry yet — the echo can die with a rebuilt queue.
    @ObservationIgnored var deliveredSends: [String: Int] = [:]
    /// Set once a rebuild replaced this store: it stops flushing and
    /// persisting, and forwards late results of in-flight work to
    /// `successor`.
    @ObservationIgnored public internal(set) var isRetired = false
    @ObservationIgnored weak var successor: PerAccountStore?
    @ObservationIgnored var ownsFiles = true
    @ObservationIgnored var evictionTask: Task<Void, Never>?

    let logger = Logger(subsystem: "com.twarge.zephyr", category: "store")

    /// `database` is `offline`'s, when already opened (the launch prefetch
    /// opens it off the main actor to start its read).
    public init(
        account: Account, connection: ApiConnection, snapshot: InitialSnapshot,
        offline: OfflineStore? = nil, database: MessageDatabase? = nil
    ) {
        accountId = account.id
        selfUserId = account.userId
        self.connection = connection
        self.offline = offline
        queueId = snapshot.queueId
        lastEventId = snapshot.lastEventId
        zulipFeatureLevel = snapshot.zulipFeatureLevel
        eventQueueLongpollTimeoutSeconds = snapshot.eventQueueLongpollTimeoutSeconds ?? 90
        serverEnterSends = snapshot.userSettings?.enterSends
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
        topicActivity = TopicActivityStore(selfUserId: account.userId, offline: offline)
        channelTopics = ChannelTopicCache(offline: offline)
        topicLinks = TopicLinkIndex()
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
        // hydration is the offline restore, kicked by the GlobalStore
        // after install — it decodes thousands of payloads and must not
        // block the main actor.
        if let offline {
            self.database = database ?? offline.openDatabase(realmURL: connection.realmURL)
            outbox = offline.loadOutbox().map { entry in
                var restored = entry
                restored.state = entry.restoredState
                return restored
            }
            pendingActions = offline.loadPendingActions()
            // The snapshot (cached at an offline relaunch, or freshly
            // registered before the queue replays) predates these actions:
            // without the reapply, unreads cleared offline resurrect.
            reapplyPendingActionsLocally()
        }
        topicActivity.attach(to: self)
        channelTopics.attach(to: self)
        topicLinks.attach(to: self)
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

    func forEachMessageList(_ body: (MessageListModel) -> Void) {
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

    /// Whether this realm's server can anchor a fetch at a date — the
    /// `date:` search (Zulip 12+).
    public var supportsDateAnchor: Bool {
        zulipFeatureLevel >= ApiConnection.anchorDateFeatureLevel
    }

    // MARK: Compose preview

    /// One compose preview's draft, and where the event stream stood when
    /// its render was requested: link previews that arrived before then
    /// belong to an earlier preview of the same text.
    public struct PreviewRequest: Equatable, Sendable {
        public var content: String
        public var sinceEventId: Int
    }

    /// Call as the preview's /messages/render goes out.
    public func previewRequest(for content: String) -> PreviewRequest {
        PreviewRequest(content: content, sinceEventId: lastEventId)
    }

    /// The draft re-rendered with the link previews the server fetched after
    /// its /messages/render reply (Zulip 13+), when the newest such rendering
    /// is this request's. It can arrive before the reply, or never.
    public func previewEmbedsHTML(for request: PreviewRequest) -> String? {
        guard let previewEmbeds, previewEmbeds.eventId > request.sinceEventId,
              previewEmbeds.content == request.content
        else { return nil }
        return previewEmbeds.renderedContent
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

    func sendTypingRequest(op: String, destination: SendDestination) {
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
        guard let urlString = serverEmojiDataUrl,
              let url = URL(string: urlString, relativeTo: connection.realmURL)?.absoluteURL
        else {
            emojiEntries = realmEmojiEntries()
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
            guard let self else { return }
            // Realm entries as of now: realm_emoji events may have landed
            // during the download.
            self.unicodeEmojiEntries = unicodeEntries
            self.emojiEntries = self.realmEmojiEntries() + unicodeEntries
        }
    }

    func realmEmojiEntries() -> [EmojiEntry] {
        realmEmoji
            .filter { !$0.value.deactivated }
            .map { id, item in
                EmojiEntry(name: item.name, code: id, character: nil, realmSrc: item.sourceUrl)
            }
            .sorted { $0.name < $1.name }
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
        clearDeliveredSends(messageIds: fetched.map(\.id))
        guard !written.isEmpty else { return }
        scheduleEviction()
        topicActivity.seedMissing(written.compactMap { messages[$0] })
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

    static let perfLogEnabled = UserDefaults.standard.bool(forKey: "perfLog")
    var perfEventCounts: [String: Int] = [:]
    var perfEventMs: [String: Double] = [:]
    var perfFlushScheduled = false

    func recordEventPerf(_ name: String, ms: Double) {
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
}
