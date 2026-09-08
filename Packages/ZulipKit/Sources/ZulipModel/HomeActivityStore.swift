import Foundation
import Observation
import ZulipAPI

public struct HomeSummary: Codable, Sendable {
    public var topic: HomeTopicID
    public var fingerprint: String
    public var text: String
    public var sourceIds: [Int]
    public var generatedAt: Date

    public init(topic: HomeTopicID, fingerprint: String, text: String, sourceIds: [Int]) {
        self.topic = topic
        self.fingerprint = fingerprint
        self.text = text
        self.sourceIds = sourceIds
        generatedAt = Date()
    }
}

/// Account-scoped Home state, shared by windows. Its own fetch/event fence
/// lets read mentions and cross-device reactions refresh without replacing
/// a canonical transcript message with an older network response.
@MainActor @Observable
public final class HomeActivityStore {
    public private(set) var activities: [TopicActivity] = []
    public private(set) var verifiedTopics: Set<HomeTopicID> = []
    public private(set) var isLoading = false
    public private(set) var historyIsLimited = false
    public private(set) var refreshFailed = false
    public private(set) var summaries: [HomeTopicID: HomeSummary] = [:]
    public private(set) var revision = 0

    @ObservationIgnored private weak var store: PerAccountStore?
    @ObservationIgnored private let offline: OfflineStore?
    @ObservationIgnored private var index: TopicActivityIndex
    @ObservationIgnored private var eventRevision = 0
    @ObservationIgnored private var changedAt: [Int: Int] = [:]
    @ObservationIgnored private var topicChangedAt: [HomeTopicID: Int] = [:]
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var loadedLimit = 0
    @ObservationIgnored private var dirtyTopics: Set<HomeTopicID> = []
    @ObservationIgnored private var derived: [HomeTopicID: TopicActivity] = [:]
    @ObservationIgnored private var cutoffDay: Int?
    @ObservationIgnored private var checkedMentionTargets: Set<Int> = []
    @ObservationIgnored private var mentionChecksRemaining = 0
    @ObservationIgnored private var savedMentions: [HomeMentionRecord] = []
    @ObservationIgnored private var checking: Set<HomeTopicID> = []

    /// Topic checks are independent narrows, so they overlap rather than
    /// queue: a 30-row Home was ~90 strictly serial round trips. Bounded so
    /// opening Home doesn't arrive at the server as one burst.
    private static let maxConcurrentTopicChecks = 4

    init(selfUserId: Int, offline: OfflineStore?) {
        index = TopicActivityIndex(selfUserId: selfUserId)
        self.offline = offline
        // Only known pending requests are retained separately from the
        // normal history cache, so they survive its per-topic launch cap.
        savedMentions = (offline?.loadHomeMentions() ?? []).sorted { $0.message.id < $1.message.id }
        for record in savedMentions {
            index.restore(record)
            if let key = HomeTopicID(record.message) { dirtyTopics.insert(key) }
        }
        for summary in offline?.loadHomeSummaries() ?? [] { summaries[summary.topic] = summary }
    }

    func attach(to store: PerAccountStore) { self.store = store }

    func seedMissing(_ messages: [Message]) {
        for var message in messages where index.messages[message.id] == nil && changedAt[message.id] == nil {
            // Cached optimistic additions are not server confirmations.
            for action in store?.pendingActions ?? [] {
                if case .reaction(let id, let add, _, let code, let type) = action,
                   add, id == message.id {
                    message.reactions.removeAll {
                        $0.userId == index.selfUserId && $0.emojiCode == code && $0.reactionType == type
                    }
                }
            }
            upsert(message)
        }
        scheduleRebuild()
    }

    private func scheduleRebuild() {
        guard rebuildTask == nil else { return }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            self.rebuildTask = nil
            self.rebuild()
        }
    }

    func rebuild(now: Date = Date()) {
        let cutoff = Int(now.addingTimeInterval(-7 * 86400).timeIntervalSince1970)
        let day = cutoff / 86400
        if cutoffDay != day {
            derived = Dictionary(uniqueKeysWithValues: index.activities(since: cutoff).map { ($0.id, $0) })
            cutoffDay = day
        } else {
            guard !dirtyTopics.isEmpty else { return }
            for key in dirtyTopics { derived.removeValue(forKey: key) }
            for activity in index.activities(since: cutoff, topics: dirtyTopics) {
                derived[activity.id] = activity
            }
        }
        dirtyTopics.removeAll()
        activities = derived.values.sorted { $0.lastMessageId > $1.lastMessageId }
        revision &+= 1
        saveMentionsIfChanged(Set(activities.flatMap(\.unansweredMentionIds)))
    }

    /// Pending requests reach disk only when they actually change. A rebuild
    /// runs within 60ms of any channel event, and this used to encode and
    /// write the same records on every one of them; the set itself only
    /// moves when a mention arrives or is answered. The write stays
    /// synchronous at that rate so a quit can't lose the newest one.
    private func saveMentionsIfChanged(_ pending: Set<Int>) {
        guard let offline else { return }
        let records = index.mentionRecords(ids: pending)
        guard records != savedMentions else { return }
        savedMentions = records
        offline.saveHomeMentions(records)
    }

    private func upsert(_ message: Message, live: Bool = false) {
        if live {
            if let old = index.messages[message.id].flatMap(HomeTopicID.init) { topicChangedAt[old] = eventRevision }
            if let key = HomeTopicID(message) { topicChangedAt[key] = eventRevision }
        }
        guard index.messages[message.id] != message else { return }
        if let old = index.messages[message.id].flatMap(HomeTopicID.init) { dirtyTopics.insert(old) }
        index.upsert(message, live: live)
        if let key = HomeTopicID(message) { dirtyTopics.insert(key) }
    }

    private func remove(_ ids: [Int], live: Bool = false) {
        for id in ids {
            if let key = index.messages[id].flatMap(HomeTopicID.init) {
                dirtyTopics.insert(key)
                if live { topicChangedAt[key] = eventRevision }
            }
        }
        index.remove(ids)
    }

    public func saveSummary(_ summary: HomeSummary, source: [Message]) {
        guard let store, store.subscriptions[summary.topic.streamId] != nil,
              source.allSatisfy({ old in
                  guard let current = index.messages[old.id] else { return false }
                  return current.content == old.content && current.subject == old.subject
                      && current.streamId == old.streamId
                      && current.lastEditTimestamp == old.lastEditTimestamp
              }) else { return }
        summaries[summary.topic] = summary
        if summaries.count > 100 {
            let oldest = summaries.values.min { $0.generatedAt < $1.generatedAt }
            if let oldest { summaries.removeValue(forKey: oldest.topic) }
        }
        offline?.saveHomeSummaries(Array(summaries.values))
    }

    private func invalidateSummaries(ids: Set<Int>) {
        let affected = summaries.values.filter { !ids.isDisjoint(with: $0.sourceIds) }.map(\.topic)
        guard !affected.isEmpty else { return }
        for key in affected { summaries.removeValue(forKey: key) }
        offline?.saveHomeSummaries(Array(summaries.values))
    }

    func handleEvent(_ event: Event) {
        eventRevision &+= 1
        var touched: [Int] = []
        switch event.kind {
        case .message(let event):
            var message = event.message
            message.flags = event.flags
            upsert(message, live: true)
            touched = [message.id]
        case .updateMessage(let event):
            touched = event.messageIds ?? [event.messageId]
            for id in touched {
                guard var message = index.messages[id] else { continue }
                if let old = HomeTopicID(message) { verifiedTopics.remove(old) }
                if id == event.messageId, let content = event.renderedContent {
                    message.content = content
                    message.lastEditTimestamp = event.editTimestamp ?? message.lastEditTimestamp
                }
                if let topic = event.subject { message.subject = topic }
                if let stream = event.newStreamId { message.streamId = stream }
                upsert(message, live: true)
                if let new = HomeTopicID(message) { verifiedTopics.remove(new) }
            }
        case .deleteMessage(let event):
            touched = event.allIds
            for id in touched {
                if let message = index.messages[id], let key = HomeTopicID(message) {
                    verifiedTopics.remove(key)
                }
            }
            remove(touched, live: true)
        case .reaction(let event):
            touched = [event.messageId]
            index.applyReaction(event)
            if let key = index.messages[event.messageId].flatMap(HomeTopicID.init) {
                dirtyTopics.insert(key)
                topicChangedAt[key] = eventRevision
            }
            // Missing targets are fetched on the next refresh, never
            // treated as proof of no acknowledgement.
            if index.messages[event.messageId] == nil { lastRefresh = nil }
        case .subscriptionRemove(let ids), .streamDelete(let ids):
            let removed = Set(ids)
            touched = index.messages.values.filter { removed.contains($0.streamId ?? -1) }.map(\.id)
            remove(touched, live: true)
            for key in summaries.keys where removed.contains(key.streamId) {
                summaries.removeValue(forKey: key)
            }
            offline?.saveHomeSummaries(Array(summaries.values))
        case .subscriptionAdd, .subscriptionUpdate, .streamUpdate, .userTopic:
            break
        default:
            return
        }
        for id in touched { changedAt[id] = eventRevision }
        // Reaction metadata isn't included in the model prompt; a reaction
        // must update its indicator without spending another generation.
        if case .reaction = event.kind {} else { invalidateSummaries(ids: Set(touched)) }
        scheduleRebuild()
    }

    /// A bounded recent-history discovery pass followed by complete latest
    /// reply checks for visible topics. It never marks messages read.
    public func refresh(limit: Int = 30, force: Bool = false) async {
        guard let store, !isLoading else { return }
        if !force, loadedLimit >= limit, let lastRefresh,
           Date().timeIntervalSince(lastRefresh) < 60 { return }
        isLoading = true
        refreshFailed = false
        mentionChecksRemaining = 60
        if force { checkedMentionTargets.removeAll() }
        defer { isLoading = false; rebuild() }
        do {
            let cutoff = Int(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)
            if loadedLimit == 0 || force {
                historyIsLimited = false
                try await discover(narrow: [], cutoff: cutoff, pages: 5)
                // Unlike Unreads.mentionIds, this also returns read mentions.
                try await discover(
                    narrow: Narrow.mentions.apiElements,
                    cutoff: Int(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970),
                    pages: 5)
            }
            rebuild()
            try await check(Array(activities.filter { isVisible($0, in: store) }.prefix(limit)))
            loadedLimit = max(loadedLimit, limit)
            lastRefresh = Date()
        } catch is CancellationError {
            // A later Home visit resumes; do not make cancellation look
            // like a connection error or claim its partial fetch is fresh.
        } catch {
            refreshFailed = true
        }
    }

    /// Checks exactly the rows Home is showing. `refresh` covers the first
    /// `limit` visible topics, but a sidebar filter surfaces rows from
    /// further down the list; without this they sit at "checking replies"
    /// for as long as the filter is on.
    public func verifyVisible(_ ids: Set<HomeTopicID>) async {
        guard store != nil else { return }
        let pending = activities.filter { ids.contains($0.id) && !verifiedTopics.contains($0.id) }
        guard !pending.isEmpty else { return }
        mentionChecksRemaining = max(mentionChecksRemaining, 60)
        do {
            try await check(pending)
        } catch is CancellationError {
        } catch {
            refreshFailed = true
        }
    }

    /// Runs the per-topic checks with bounded concurrency. Every mutation
    /// still lands on the main actor between awaits, so the event fence and
    /// the shared mention-check budget are unaffected; only the waiting
    /// overlaps. `checking` keeps a refresh and a filter change from both
    /// fetching the same topic.
    private func check(_ topics: [TopicActivity]) async throws {
        let fresh = topics.filter { !checking.contains($0.id) }
        guard !fresh.isEmpty else { return }
        for activity in fresh { checking.insert(activity.id) }
        defer { for activity in fresh { checking.remove(activity.id) } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = fresh.makeIterator()
            for _ in 0..<Self.maxConcurrentTopicChecks {
                guard let activity = queue.next() else { break }
                group.addTask { try await self.refreshTopic(activity) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                guard let activity = queue.next() else { continue }
                group.addTask { try await self.refreshTopic(activity) }
            }
        }
    }

    public func isVisible(_ activity: TopicActivity, in store: PerAccountStore) -> Bool {
        guard let subscription = store.subscriptions[activity.id.streamId] else { return false }
        let policy = store.topicVisibility(streamId: activity.id.streamId, topic: activity.topic)
        if policy == .muted { return false }
        return !subscription.muted || policy == .followed || policy == .unmuted
    }

    private func discover(narrow: [NarrowElement], cutoff: Int, pages: Int) async throws {
        var anchor = MessageAnchor.newest
        var previousOldest: Int?
        for page in 0..<pages {
            let result = try await fetch(anchor: anchor, before: 200, narrow: narrow)
            guard let first = result.messages.min(by: { $0.id < $1.id }) else { return }
            historyIsLimited = historyIsLimited || result.historyLimited == true
            if result.foundOldest == true || first.timestamp < cutoff { return }
            if previousOldest == first.id { historyIsLimited = true; return }
            previousOldest = first.id
            anchor = .id(first.id)
            if page == pages - 1 { historyIsLimited = true }
        }
    }

    private func refreshTopic(_ activity: TopicActivity) async throws {
        guard let store else { return }
        let narrow = activity.conversation.narrow(selfUserId: index.selfUserId).apiElements
        let topicStart = topicChangedAt[activity.id] ?? 0
        let tailStart = eventRevision
        let tail = try await fetch(anchor: .newest, before: 50, narrow: narrow)
        let tailIds = Set(tail.messages.map(\.id))
        if tail.foundNewest == true, tail.historyLimited != true {
            let lowerBound = tail.messages.map(\.id).min()
                ?? (tail.foundOldest == true ? 0 : Int.max)
            let deleted = index.messages.values.filter {
                HomeTopicID($0) == activity.id && $0.id >= lowerBound
                    && !tailIds.contains($0.id) && (changedAt[$0.id] ?? 0) <= tailStart
            }.map(\.id)
            remove(deleted)
            invalidateSummaries(ids: Set(deleted))
        }
        // A latest-self-message query answers whether ANY later reply
        // exists, even when it is beyond the 50-message summary slice.
        let ownNarrow = narrow + [NarrowElement("sender", .int(index.selfUserId))]
        let start = eventRevision
        let own = try await fetch(anchor: .newest, before: 1, narrow: ownNarrow)
        let latestOwnId = own.messages.map(\.id).max() ?? 0
        if own.foundNewest == true, own.historyLimited != true {
            // Remove a stale/deleted last reply learned in an earlier
            // session, retaining any newer event that raced this request.
            let obsolete = index.messages.values.filter {
                HomeTopicID($0) == activity.id && $0.senderId == index.selfUserId
                    && $0.id > latestOwnId && (changedAt[$0.id] ?? 0) <= start
            }.map(\.id)
            remove(obsolete)
        }
        let stillPending = index.activities(since: 0, topics: [activity.id]).first?.unansweredMentionIds ?? []
        var checkedAllTargets = true
        for id in stillPending where !tailIds.contains(id) && !checkedMentionTargets.contains(id) {
            guard mentionChecksRemaining > 0 else {
                checkedAllTargets = false
                historyIsLimited = true
                break
            }
            mentionChecksRemaining -= 1
            let start = eventRevision
            let target = try await fetch(anchor: .id(id), before: 0, narrow: narrow)
            checkedMentionTargets.insert(id)
            if !target.messages.contains(where: { $0.id == id }), (changedAt[id] ?? 0) <= start {
                // A moved/deleted target is no longer a request in this topic.
                remove([id])
                invalidateSummaries(ids: [id])
            }
        }
        if tail.foundNewest == true, own.foundNewest == true,
           tail.historyLimited != true, own.historyLimited != true,
           checkedAllTargets, !store.isRecoveringEventStream,
           (topicChangedAt[activity.id] ?? 0) == topicStart {
            verifiedTopics.insert(activity.id)
        } else {
            verifiedTopics.remove(activity.id)
            if tail.historyLimited == true || own.historyLimited == true
                || tail.foundNewest != true || own.foundNewest != true {
                historyIsLimited = true
            }
        }
        rebuild()
    }

    private func fetch(
        anchor: MessageAnchor, before: Int, narrow: [NarrowElement]
    ) async throws -> GetMessagesResult {
        guard let store else { throw CancellationError() }
        try Task.checkCancellation()
        let start = eventRevision
        let result = try await store.connection.getMessages(
            anchor: anchor, numBefore: before, numAfter: 0, narrow: narrow)
        try Task.checkCancellation()
        let accepted = result.messages.filter { (changedAt[$0.id] ?? 0) <= start }
        for message in accepted {
            if let previous = index.messages[message.id], previous.content != message.content
                || previous.subject != message.subject || previous.streamId != message.streamId {
                invalidateSummaries(ids: [message.id])
            }
            upsert(message)
        }
        // A deleted message must not slip back in through the canonical
        // store's seedMissing callback after failing Home's event fence.
        store.reconcileFetchedMessages(accepted)
        return result
    }
}
