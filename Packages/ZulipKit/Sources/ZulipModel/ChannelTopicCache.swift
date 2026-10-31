import Foundation
import Observation
import ZulipAPI

/// Account-scoped topic lists per channel (GET /users/me/{id}/topics),
/// shared by the sidebar and its filter, compose's #-links, topic pickers,
/// and the channel topics view — one fetch serves them all.
///
/// Offline-first: the last fetched lists persist to disk, a channel with
/// none falls back to the topics in the message database, and new messages
/// bump their topic live — so expanded channels and the topic filter work
/// with no network. A fetched list replaces its channel's entry outright:
/// the server knows about moves and deletions the cache can't replay.
@MainActor @Observable
public final class ChannelTopicCache {
    /// Recency-ordered, newest first. No entry: nothing known yet.
    public private(set) var lists: [Int: [ChannelTopic]] = [:]
    /// True while `loadAll` fetches channels with no list at all — the
    /// only pass whose results can appear from nothing.
    public private(set) var isLoadingUncached = false

    @ObservationIgnored private weak var store: PerAccountStore?
    @ObservationIgnored private let offline: OfflineStore?
    /// Fetched from the server by this instance (vs. restored or adopted).
    @ObservationIgnored private var fresh: Set<Int> = []
    /// Partial lists read from the message database: shown, never saved.
    @ObservationIgnored private var seeded: Set<Int> = []
    @ObservationIgnored private var fetches: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadAllTask: Task<Void, Never>?
    @ObservationIgnored private var loadAllRetryAt: ContinuousClock.Instant?
    @ObservationIgnored private var movedChannels: Set<Int> = []
    @ObservationIgnored private var moveRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var isRestored = false

    /// Fetches in flight at once during `loadAll`.
    private static let concurrency = 5
    /// After a `loadAll` pass that failed, how long before another tries.
    private static let retryInterval: Duration = .seconds(15)
    /// Topics per channel read from the database when the server can't
    /// be reached.
    private static let seedLimit = 1000

    init(offline: OfflineStore?) {
        self.offline = offline
    }

    func attach(to store: PerAccountStore) { self.store = store }

    /// Whether this session has the channel's list from the server.
    public func isFresh(_ streamId: Int) -> Bool {
        fresh.contains(streamId)
    }

    /// Fetches one channel's list now (a sidebar expand, a view opening),
    /// joining a fetch already in flight. A failure keeps what's cached —
    /// or, when nothing is, the database's topics.
    public func refresh(_ streamId: Int) {
        fetch(streamId)
    }

    /// The channel's list, fetched first unless this session already has
    /// it from the server (or `refetch`); offline it resolves to the
    /// cached list.
    @discardableResult
    public func load(_ streamId: Int, refetch: Bool = false) async -> [ChannelTopic] {
        if refetch || !fresh.contains(streamId) {
            await fetch(streamId).value
        }
        return lists[streamId] ?? []
    }

    /// Fetches every subscribed channel's list this session hasn't (the
    /// filter matches topics everywhere), a few at a time. A chunk that
    /// fails outright — offline, or the server unreachable — ends the
    /// pass, channels still without a list take the database's, and the
    /// next call retries after a pause.
    public func loadAll() async {
        if let running = loadAllTask {
            await running.value
            return
        }
        if let retryAt = loadAllRetryAt, ContinuousClock.now < retryAt { return }
        guard let store else { return }
        let ids = store.subscriptions.keys.filter { !fresh.contains($0) }.sorted()
        guard !ids.isEmpty else { return }
        isLoadingUncached = ids.contains { lists[$0] == nil }
        let task = Task {
            var failed = false
            for start in stride(from: 0, to: ids.count, by: Self.concurrency) {
                let chunk = Array(ids[start..<min(start + Self.concurrency, ids.count)])
                await withTaskGroup(of: Void.self) { group in
                    for id in chunk {
                        let fetch = fetch(id)
                        group.addTask { await fetch.value }
                    }
                }
                let succeeded = chunk.filter { fresh.contains($0) }
                failed = failed || succeeded.count < chunk.count
                if succeeded.isEmpty {
                    await seedIfMissing(Array(ids[start...]))
                    break
                }
            }
            loadAllRetryAt = failed ? ContinuousClock.now + Self.retryInterval : nil
            isLoadingUncached = false
            loadAllTask = nil
        }
        loadAllTask = task
        await task.value
    }

    // MARK: Fetching

    @discardableResult
    private func fetch(_ streamId: Int) -> Task<Void, Never> {
        if let running = fetches[streamId] { return running }
        let connection = store?.connection
        let task = Task {
            defer { fetches[streamId] = nil }
            guard let connection else { return }
            do {
                install(try await connection.getTopics(streamId: streamId), for: streamId)
            } catch {
                await seedIfMissing([streamId])
            }
        }
        fetches[streamId] = task
        return task
    }

    private func install(_ topics: [ChannelTopic], for streamId: Int) {
        fresh.insert(streamId)
        let wasSeeded = seeded.remove(streamId) != nil
        guard wasSeeded || lists[streamId] != topics else { return }
        lists[streamId] = topics
        scheduleSave(within: .seconds(3))
    }

    /// Channels with no list at all get the database's topics — possibly
    /// none, which still settles a loading row.
    private func seedIfMissing(_ streamIds: [Int]) async {
        let missing = streamIds.filter { lists[$0] == nil }
        guard !missing.isEmpty else { return }
        let database = store?.database
        let limit = Self.seedLimit
        let found = await Task.detached(priority: .userInitiated) {
            var found: [Int: [ChannelTopic]] = [:]
            for id in missing {
                found[id] = (try? database?.recentTopics(streamId: id, limit: limit)) ?? []
            }
            return found
        }.value
        for (id, topics) in found where lists[id] == nil {
            lists[id] = topics
            seeded.insert(id)
        }
    }

    // MARK: Persistence

    /// Loads the lists saved last session (decoded off the main actor).
    /// Lists fetched in the meantime win; database seeds give way.
    func restore() async {
        defer { isRestored = true }
        guard let offline else { return }
        let saved = await Task.detached(priority: .utility) {
            offline.loadChannelTopics()
        }.value
        for (id, topics) in saved
        where !fresh.contains(id) && (lists[id] == nil || seeded.contains(id)) {
            lists[id] = topics
            seeded.remove(id)
        }
    }

    /// A replacement store instance (provisional → live, queue rebuild)
    /// starts from what this one knew. Nothing counts as fetched: events
    /// may have been missed across the swap, so `loadAll` fetches again.
    func adopt(from previous: ChannelTopicCache) {
        lists = previous.lists
        seeded = previous.seeded
        if previous.isRestored {
            isRestored = true
        } else {
            Task { await restore() }
        }
    }

    /// Debounced to the nearest deadline asked for: fetched lists save
    /// within seconds, while live bumps — a busy channel's every message —
    /// batch for a minute.
    private func scheduleSave(within delay: Duration) {
        guard offline != nil else { return }
        let deadline = ContinuousClock.now + delay
        if let saveDeadline, saveDeadline <= deadline { return }
        saveTask?.cancel()
        saveDeadline = deadline
        saveTask = Task {
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            saveTask = nil
            saveDeadline = nil
            await save()
        }
    }

    func save() async {
        guard let offline else { return }
        let snapshot = lists.filter { !seeded.contains($0.key) }
        await Task.detached(priority: .utility) {
            offline.saveChannelTopics(snapshot)
        }.value
    }

    // MARK: Events

    func handleEvent(_ event: Event) {
        switch event.kind {
        case .message(let e):
            // A new message makes its topic the channel's newest. Only
            // channels that have a list: a one-topic stub would pass for
            // the whole list.
            let message = e.message
            guard let streamId = message.streamId, var topics = lists[streamId] else { return }
            if let index = topics.firstIndex(where: { TopicName.matches($0.name, message.subject) }) {
                guard topics[index].maxId < message.id else { return }
                topics.remove(at: index)
            }
            let position = topics.firstIndex { $0.maxId < message.id } ?? topics.count
            topics.insert(ChannelTopic(name: message.subject, maxId: message.id), at: position)
            lists[streamId] = topics
            scheduleSave(within: .seconds(60))
        case .updateMessage(let e):
            // Moves and renames, partial ones included: the server's list
            // has the outcome right, so refetch rather than replay it.
            guard e.subject != nil || e.newStreamId != nil else { return }
            for id in [e.streamId, e.newStreamId].compactMap(\.self) where lists[id] != nil {
                movedChannels.insert(id)
            }
            scheduleMoveRefresh()
        case .subscriptionRemove(let ids), .streamDelete(let ids):
            let dropped = ids.filter { lists[$0] != nil }
            guard !dropped.isEmpty else { return }
            for id in dropped {
                lists[id] = nil
                fresh.remove(id)
                seeded.remove(id)
            }
            scheduleSave(within: .seconds(3))
        default:
            break
        }
    }

    /// Coalesces a burst of moves (resolving several topics, a bulk move)
    /// into one fetch per channel.
    private func scheduleMoveRefresh() {
        guard !movedChannels.isEmpty, moveRefreshTask == nil else { return }
        moveRefreshTask = Task {
            try? await Task.sleep(for: .seconds(1))
            moveRefreshTask = nil
            let channels = movedChannels
            movedChannels = []
            for id in channels {
                fresh.remove(id)
                fetch(id)
            }
        }
    }
}
