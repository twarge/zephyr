import Foundation
import Observation
import ZulipAPI
import os
import Synchronization

extension Duration {
    /// Whole milliseconds, for timing logs.
    var ms: Int {
        Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Account-independent root: the account list plus one `PerAccountStore` +
/// `UpdateMachine` pair per loaded account. Owns the rebuild path — when a
/// machine reports queue death, the old store is discarded and a fresh
/// snapshot is registered ("on any doubt, rebuild").
@MainActor
@Observable
public final class GlobalStore: UpdateMachineDelegate {
    public private(set) var accounts: [Account]
    public private(set) var stores: [Account.ID: PerAccountStore] = [:]

    /// The accounts that connect and appear in menus and windows —
    /// disabled ones keep their credentials but are otherwise inert.
    public var enabledAccounts: [Account] {
        accounts.filter(\.isEnabled)
    }
    /// Bumped whenever a store is created or replaced, so UI can re-resolve.
    public private(set) var storeGeneration = 0

    /// Debug/harness hook: every applied event, tagged with its account.
    public var eventObserver: ((Account.ID, Event) -> Void)?
    /// Every live store as it's installed (first register and each
    /// rebuild) — not the provisional ones built from the snapshot cache.
    public var storeInstalledObserver: ((Account.ID, PerAccountStore) -> Void)?

    /// Message-history retention in days (nil = keep forever), applied to
    /// every store; changing it re-prunes live stores immediately.
    public var messageRetentionDays: Int? {
        didSet {
            guard messageRetentionDays != oldValue else { return }
            for store in stores.values {
                store.messageRetentionDays = messageRetentionDays
                store.pruneMessageHistory()
            }
        }
    }

    private var machines: [Account.ID: UpdateMachine] = [:]
    private var loadTasks: [Account.ID: Task<PerAccountStore, any Error>] = [:]
    /// Stores built from the on-disk snapshot cache: rendered while the live
    /// register runs, never polled (their queue is stale), always replaced.
    private var provisionalStores: Set<Account.ID> = []
    /// Launch reads started ahead of `installCachedStore` (see
    /// `LaunchPrefetch`).
    @ObservationIgnored
    private var snapshotPrefetches: [Account.ID: Prefetch<InitialSnapshot?>] = [:]
    @ObservationIgnored
    private var offlinePrefetches: [Account.ID: Prefetch<OfflineRead>] = [:]
    @ObservationIgnored
    private var apiKeyPrefetches: [Account.ID: Prefetch<String?>] = [:]
    private let accountsStore: any AccountsStore
    private let credentials: any CredentialStore
    private let transport: any ApiTransport
    private let sleep: UpdateMachine.SleepFunction
    private let logger = Logger(subsystem: "com.twarge.zephyr", category: "store")
    /// Launch-timing chatter only under the perf probes (make perf).
    private static let perfLogEnabled = UserDefaults.standard.bool(forKey: "perfLog")

    private let enablePresencePings: Bool
    /// False in tests: no snapshot cache and no offline stores touch the real
    /// filesystem (fixture data was polluting Application Support).
    private let persistsToDisk: Bool

    public init(
        accountsStore: any AccountsStore,
        credentials: any CredentialStore,
        transport: any ApiTransport = URLSessionTransport.shared,
        enablePresencePings: Bool = true,
        persistsToDisk: Bool = true,
        sleep: @escaping UpdateMachine.SleepFunction = { try await Task.sleep(for: $0) }
    ) throws {
        self.accountsStore = accountsStore
        self.credentials = credentials
        self.transport = transport
        self.enablePresencePings = enablePresencePings
        self.persistsToDisk = persistsToDisk
        self.sleep = sleep
        accounts = try accountsStore.load()
    }

    // MARK: Accounts

    public func addAccount(
        realmURL: URL,
        email: String,
        apiKey: String,
        userId: Int,
        realmName: String? = nil
    ) throws -> Account {
        let account = Account(realmURL: realmURL, email: email, userId: userId, realmName: realmName)
        try credentials.setAPIKey(apiKey, realmURL: realmURL, email: email)
        accounts.append(account)
        try accountsStore.save(accounts)
        return account
    }

    /// Reorders the account list (drives ⌘1…⌘9 precedence); persisted.
    public func moveAccounts(fromOffsets: IndexSet, toOffset: Int) {
        var moved: [Account] = []
        for index in fromOffsets.sorted(by: >) where accounts.indices.contains(index) {
            moved.append(accounts.remove(at: index))
        }
        let insertion = toOffset - fromOffsets.count(where: { $0 < toOffset })
        accounts.insert(
            contentsOf: moved.reversed(),
            at: min(max(insertion, 0), accounts.count))
        try? accountsStore.save(accounts)
    }

    /// Disables (disconnects and quiesces, credentials kept) or re-enables
    /// an account. Re-enabling is lazy: windows and menus load the store on
    /// first use, like launch does.
    public func setAccountEnabled(_ accountId: Account.ID, enabled: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == accountId }),
              accounts[index].isEnabled != enabled else { return }
        accounts[index].isDisabled = enabled ? nil : true
        try? accountsStore.save(accounts)
        if !enabled {
            machines.removeValue(forKey: accountId)?.stop()
            loadTasks[accountId]?.cancel()
            loadTasks[accountId] = nil
            provisionalStores.remove(accountId)
            if let store = stores.removeValue(forKey: accountId) {
                store.persistMessageCache(synchronously: true)
                Task {
                    try? await store.connection.deleteEventQueue(queueId: store.queueId)
                }
            }
        }
        storeGeneration += 1
    }

    public func removeAccount(_ accountId: Account.ID) async throws {
        machines.removeValue(forKey: accountId)?.stop()
        if let store = stores.removeValue(forKey: accountId) {
            try? await store.connection.deleteEventQueue(queueId: store.queueId)
        }
        if let account = accounts.first(where: { $0.id == accountId }) {
            try? credentials.setAPIKey(nil, realmURL: account.realmURL, email: account.email)
        }
        if let cacheURL = snapshotCacheURL(for: accountId) {
            try? FileManager.default.removeItem(at: cacheURL)
        }
        OfflineStore.remove(for: accountId)
        provisionalStores.remove(accountId)
        accounts.removeAll { $0.id == accountId }
        try accountsStore.save(accounts)
        storeGeneration += 1
    }

    // MARK: Store lifecycle

    /// Interrupts every event loop's retry backoff (the network path came
    /// back): reconnects — and therefore recovery flushes — happen now.
    public func kickEventStreams() {
        for machine in machines.values {
            machine.kick()
        }
    }

    public func hasLiveStore(_ accountId: Account.ID) -> Bool {
        stores[accountId] != nil && !provisionalStores.contains(accountId)
    }

    /// Returns the live store for an account, loading (register + machine
    /// start) on first use. Concurrent calls are deduplicated.
    public func perAccountStore(for accountId: Account.ID) async throws -> PerAccountStore {
        if let store = stores[accountId], !provisionalStores.contains(accountId) {
            return store
        }
        if let task = loadTasks[accountId] { return try await task.value }
        let task = Task { try await self.loadStore(accountId: accountId) }
        loadTasks[accountId] = task
        defer { loadTasks[accountId] = nil }
        return try await task.value
    }

    // MARK: Warm-launch snapshot cache

    private func snapshotCacheURL(for accountId: Account.ID) -> URL? {
        persistsToDisk ? Self.snapshotCacheURL(for: accountId) : nil
    }

    fileprivate nonisolated static func snapshotCacheURL(for accountId: Account.ID) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { return nil }
        let directory = base
            .appendingPathComponent("com.twarge.zephyr", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(accountId.uuidString).json")
    }

    /// Takes over launch reads the app started before this store existed
    /// (`LaunchPrefetch`), for `installPrefetchedStore` to finish.
    public func adopt(_ prefetch: LaunchPrefetch) {
        let accountId = prefetch.accountId
        guard persistsToDisk, stores[accountId] == nil,
              snapshotPrefetches[accountId] == nil,
              accounts.contains(where: { $0.id == accountId && $0.isEnabled })
        else { return }
        snapshotPrefetches[accountId] = prefetch.snapshot
        offlinePrefetches[accountId] = prefetch.history
        apiKeyPrefetches[accountId] = prefetch.apiKey
    }

    /// Starts the launch reads for an account here, when the app didn't
    /// (see `LaunchPrefetch`).
    public func prefetchCachedSnapshot(for accountId: Account.ID) {
        guard persistsToDisk, snapshotPrefetches[accountId] == nil, stores[accountId] == nil,
              let account = accounts.first(where: { $0.id == accountId }),
              let prefetch = LaunchPrefetch(account: account, credentials: credentials)
        else { return }
        adopt(prefetch)
    }

    /// `installCachedStore` without suspending, for app init: installs only
    /// if the prefetched decode is done within `timeout` — usually it
    /// already is, having started at app init. A slower one (a giant
    /// realm's) stays prefetched for the async path, so it costs launch no
    /// more than the wait. The offline history read gets the same
    /// deadline; if it misses, the restore lands asynchronously as it used
    /// to.
    public func installPrefetchedStore(for accountId: Account.ID, waitingUpTo timeout: Duration) -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = DispatchTime.now() + .milliseconds(timeout.ms)
        guard let prefetch = snapshotPrefetches[accountId],
              let snapshot = prefetch.wait(until: deadline)
        else { return false }
        snapshotPrefetches[accountId] = nil
        guard let snapshot else { return false }
        let decoded = clock.now
        let history = offlinePrefetches[accountId]?.wait(until: deadline)
        let read = clock.now
        let installed = installProvisionalStore(
            for: accountId, snapshot: snapshot, history: history,
            apiKey: apiKeyPrefetches.removeValue(forKey: accountId)?.wait(until: deadline))
        if Self.perfLogEnabled {
            logger.info("init install: waited \((decoded - start).ms, privacy: .public) ms for the snapshot, \((read - decoded).ms, privacy: .public) ms more for history (\(history == nil ? "late" : "ready", privacy: .public)); install \((clock.now - read).ms, privacy: .public) ms")
        }
        return installed
    }

    /// Builds a provisional store from the last register's cached snapshot,
    /// so launch renders instantly ("stale → live", zulip-mobile
    /// realtime.md). Returns false when there's nothing cached.
    public func installCachedStore(for accountId: Account.ID) async -> Bool {
        let prefetch = snapshotPrefetches.removeValue(forKey: accountId)
        guard stores[accountId] == nil, let url = snapshotCacheURL(for: accountId)
        else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let snapshot = await (prefetch ?? Prefetch(priority: .userInitiated) {
            (try? Data(contentsOf: url)).flatMap {
                try? ZulipJSON.decoder.decode(InitialSnapshot.self, from: $0)
            }
        }).value
        guard let snapshot else { return false }
        if Self.perfLogEnabled {
            logger.info("cached snapshot decoded in \((clock.now - start).ms, privacy: .public) ms")
        }
        // The launch prefetch's other reads, when this is the slow path a
        // giant realm's decode fell back to: they've had longer than it.
        let history = await offlinePrefetches.removeValue(forKey: accountId)?.value
        let apiKey = await apiKeyPrefetches.removeValue(forKey: accountId)?.value
        return installProvisionalStore(
            for: accountId, snapshot: snapshot, history: history, apiKey: apiKey)
    }

    /// `history` is the prefetched offline read and `apiKey` the
    /// prefetched credential, when each has finished.
    private func installProvisionalStore(
        for accountId: Account.ID, snapshot: InitialSnapshot, history: OfflineRead?,
        apiKey prefetchedKey: String??
    ) -> Bool {
        // The live register may have finished while we decoded.
        guard stores[accountId] == nil,
              let account = accounts.first(where: { $0.id == accountId }),
              account.isEnabled,
              let apiKey = prefetchedKey ?? (try? credentials.apiKey(
                realmURL: account.realmURL, email: account.email))
        else { return false }
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: apiKey,
            transport: transport)
        connection.featureLevel = snapshot.zulipFeatureLevel
        let store = PerAccountStore(
            account: account, connection: connection, snapshot: snapshot,
            offline: persistsToDisk ? OfflineStore.forAccount(accountId) : nil,
            database: history?.database)
        store.messageRetentionDays = messageRetentionDays
        store.isRecoveringEventStream = true
        stores[accountId] = store
        provisionalStores.insert(accountId)
        storeGeneration += 1
        if let history {
            offlinePrefetches[accountId] = nil
            store.restoreOfflineCache(from: history.messages)
        } else {
            beginOfflineRestore(store, for: accountId)
        }
        return true
    }

    /// The restore for a store with no history yet: from the launch
    /// prefetch's read when one is under way, else a read of its own.
    private func beginOfflineRestore(_ store: PerAccountStore, for accountId: Account.ID) {
        if let prefetch = offlinePrefetches.removeValue(forKey: accountId) {
            store.beginOfflineRestore(reading: Task { await prefetch.value.messages })
        } else {
            store.beginOfflineRestore()
        }
    }

    private func loadStore(accountId: Account.ID) async throws -> PerAccountStore {
        guard let account = accounts.first(where: { $0.id == accountId }),
              account.isEnabled else {
            throw ModelError.accountNotFound
        }
        guard let apiKey = try credentials.apiKey(realmURL: account.realmURL, email: account.email) else {
            throw ModelError.missingCredentials
        }
        let settings = try await ApiConnection.getServerSettings(
            realm: account.realmURL, transport: transport)
        let featureLevel = settings.zulipFeatureLevel ?? 0
        guard featureLevel >= ServerCompat.minFeatureLevel else {
            throw ModelError.serverTooOld(version: settings.zulipVersion, featureLevel: featureLevel)
        }
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: apiKey, transport: transport)
        connection.featureLevel = featureLevel
        // Desktop clients poll persistently; a long idle timeout (12h, like
        // the mobile apps) makes expiry rare. Expiry is still handled.
        let clock = ContinuousClock()
        let registerStart = clock.now
        let result = try await connection.registerQueue(idleQueueTimeoutSeconds: 12 * 60 * 60)
        if Self.perfLogEnabled {
            logger.info("register round-trip: \((clock.now - registerStart).ms, privacy: .public) ms, payload \(result.rawData.count / 1024) KB")
        }
        let snapshot = result.snapshot
        connection.featureLevel = snapshot.zulipFeatureLevel
        if let cacheURL = snapshotCacheURL(for: accountId) {
            try? result.rawData.write(to: cacheURL, options: .atomic)
        }
        let store = PerAccountStore(
            account: account, connection: connection, snapshot: snapshot,
            offline: persistsToDisk ? OfflineStore.forAccount(accountId) : nil)
        installStore(store, for: accountId)
        return store
    }

    private func installStore(_ store: PerAccountStore, for accountId: Account.ID) {
        let previous = stores[accountId]
        machines[accountId]?.stop()
        provisionalStores.remove(accountId)
        stores[accountId] = store
        store.messageRetentionDays = messageRetentionDays
        store.pruneMessageHistory()
        let machine = UpdateMachine(
            store: store, delegate: self, enablePresence: enablePresencePings, sleep: sleep)
        machine.eventObserver = { [weak self] event in
            self?.eventObserver?(accountId, event)
        }
        machines[accountId] = machine
        machine.start()
        storeGeneration += 1
        if let previous {
            // Store swap (provisional → live, queue rebuild): carry the
            // old instance's hydration over instead of re-reading SQLite —
            // the second read ran during the post-register render storm
            // and starved for seconds at background priority.
            store.adoptCachedMessages(from: previous)
        } else {
            beginOfflineRestore(store, for: accountId)
        }
        storeInstalledObserver?(accountId, store)
    }

    public func updateMachineNeedsRebuild(_ machine: UpdateMachine, reason: UpdateMachine.RebuildReason) {
        guard let entry = machines.first(where: { $0.value === machine }) else { return }
        let accountId = entry.key
        logger.info("rebuilding store for account \(accountId, privacy: .public): \(String(describing: reason), privacy: .public)")
        stores[accountId]?.isRecoveringEventStream = true
        Task { await self.rebuild(accountId: accountId) }
    }

    private func rebuild(accountId: Account.ID) async {
        // The old store stays in `stores` (UI keeps rendering stale data with
        // the recovering banner) until the replacement is installed.
        var backoff = BackoffMachine(firstBound: .milliseconds(200), maxBound: .seconds(60))
        while true {
            do {
                _ = try await loadStore(accountId: accountId)
                return
            } catch is CancellationError {
                return
            } catch {
                logger.error("store rebuild failed; retrying: \(error)")
                do {
                    try await sleep(backoff.next())
                } catch {
                    return
                }
            }
        }
    }

    /// Stops all machines; optionally deletes the server-side event queues
    /// (used by the harness on ^C and at app quit).
    public func shutdown(deleteQueues: Bool = true) async {
        for machine in machines.values {
            machine.stop()
        }
        for store in stores.values {
            store.persistMessageCache(synchronously: true)
        }
        if deleteQueues {
            for store in stores.values {
                try? await store.connection.deleteEventQueue(queueId: store.queueId)
            }
        }
        machines.removeAll()
        stores.removeAll()
        storeGeneration += 1
    }
}

/// The launch's disk reads — the cached register snapshot, the offline
/// history and the API key — started off the main actor before SwiftUI
/// has built anything (the app starts them in its init, ahead of its
/// model), for a `GlobalStore` to adopt. By the time the store installs
/// the window's first store they have usually finished, so the main
/// thread doesn't wait on them.
public final class LaunchPrefetch: Sendable {
    public let accountId: Account.ID
    fileprivate let snapshot: Prefetch<InitialSnapshot?>
    fileprivate let history: Prefetch<OfflineRead>?
    fileprivate let apiKey: Prefetch<String?>

    /// Nil when the account has no snapshot cache location.
    public init?(account: Account, credentials: any CredentialStore) {
        guard let url = GlobalStore.snapshotCacheURL(for: account.id) else { return nil }
        accountId = account.id
        snapshot = Prefetch(priority: .userInitiated) {
            (try? Data(contentsOf: url)).flatMap {
                try? ZulipJSON.decoder.decode(InitialSnapshot.self, from: $0)
            }
        }
        // Nothing renders yet for it to starve (the restore's usual
        // utility priority is for reads that overlap first render).
        history = OfflineStore.forAccount(account.id).map { offline in
            let realmURL = account.realmURL
            let selfUserId = account.userId
            return Prefetch(priority: .userInitiated) {
                guard let database = offline.openDatabase(realmURL: realmURL) else {
                    return OfflineRead(database: nil, messages: [])
                }
                return OfflineRead(
                    database: database,
                    messages: PerAccountStore.readOfflineCache(
                        offline: offline, database: database, selfUserId: selfUserId))
            }
        }
        let realmURL = account.realmURL
        let email = account.email
        apiKey = Prefetch(priority: .userInitiated) {
            try? credentials.apiKey(realmURL: realmURL, email: email)
        }
    }
}

/// The launch prefetch's offline history: the database it opened (handed
/// to the store, so there's one connection) and what it read.
fileprivate struct OfflineRead: Sendable {
    let database: MessageDatabase?
    let messages: [Message]
}

/// Launch work running off the main actor: awaited by the async launch
/// path, or briefly waited on at app init.
fileprivate final class Prefetch<Value: Sendable>: Sendable {
    /// Filled when the work finishes.
    private final class Outcome: Sendable {
        let value = Mutex<Value?>(nil)
        let finished = DispatchSemaphore(value: 0)
    }

    private let outcome: Outcome
    private let task: Task<Value, Never>

    init(priority: TaskPriority, _ work: @escaping @Sendable () -> Value) {
        let outcome = Outcome()
        self.outcome = outcome
        task = Task.detached(priority: priority) {
            let value = work()
            outcome.value.withLock { $0 = value }
            outcome.finished.signal()
            return value
        }
    }

    var value: Value {
        get async { await task.value }
    }

    /// The result if the work finishes by `deadline`, else nil.
    func wait(until deadline: DispatchTime) -> Value? {
        guard outcome.finished.wait(timeout: deadline) == .success else { return nil }
        outcome.finished.signal()  // Later waits return at once too.
        return outcome.value.withLock { $0 }
    }
}
