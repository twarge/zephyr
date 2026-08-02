import Foundation
import Observation
import ZulipAPI
import os

/// Account-independent root: the account list plus one `PerAccountStore` +
/// `UpdateMachine` pair per loaded account. Owns the rebuild path — when a
/// machine reports queue death, the old store is discarded and a fresh
/// snapshot is registered ("on any doubt, rebuild").
@MainActor
@Observable
public final class GlobalStore: UpdateMachineDelegate {
    public private(set) var accounts: [Account]
    public private(set) var stores: [Account.ID: PerAccountStore] = [:]
    /// Bumped whenever a store is created or replaced, so UI can re-resolve.
    public private(set) var storeGeneration = 0

    /// Debug/harness hook: every applied event, tagged with its account.
    public var eventObserver: ((Account.ID, Event) -> Void)?

    private var machines: [Account.ID: UpdateMachine] = [:]
    private var loadTasks: [Account.ID: Task<PerAccountStore, any Error>] = [:]
    /// Stores built from the on-disk snapshot cache: rendered while the live
    /// register runs, never polled (their queue is stale), always replaced.
    private var provisionalStores: Set<Account.ID> = []
    private let accountsStore: any AccountsStore
    private let credentials: any CredentialStore
    private let transport: any ApiTransport
    private let sleep: UpdateMachine.SleepFunction
    private let logger = Logger(subsystem: "com.twarge.zephyr", category: "store")

    private let enablePresencePings: Bool

    public init(
        accountsStore: any AccountsStore,
        credentials: any CredentialStore,
        transport: any ApiTransport = URLSessionTransport.shared,
        enablePresencePings: Bool = true,
        sleep: @escaping UpdateMachine.SleepFunction = { try await Task.sleep(for: $0) }
    ) throws {
        self.accountsStore = accountsStore
        self.credentials = credentials
        self.transport = transport
        self.enablePresencePings = enablePresencePings
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
        provisionalStores.remove(accountId)
        accounts.removeAll { $0.id == accountId }
        try accountsStore.save(accounts)
        storeGeneration += 1
    }

    // MARK: Store lifecycle

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

    /// Builds a provisional store from the last register's cached snapshot,
    /// so launch renders instantly ("stale → live", zulip-mobile
    /// realtime.md). Returns false when there's nothing cached.
    public func installCachedStore(for accountId: Account.ID) -> Bool {
        guard stores[accountId] == nil,
              let account = accounts.first(where: { $0.id == accountId }),
              let apiKey = try? credentials.apiKey(
                realmURL: account.realmURL, email: account.email),
              let url = snapshotCacheURL(for: accountId),
              let data = try? Data(contentsOf: url),
              let snapshot = try? ZulipJSON.decoder.decode(InitialSnapshot.self, from: data)
        else { return false }
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: apiKey,
            transport: transport)
        connection.featureLevel = snapshot.zulipFeatureLevel
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)
        store.isRecoveringEventStream = true
        stores[accountId] = store
        provisionalStores.insert(accountId)
        storeGeneration += 1
        return true
    }

    private func loadStore(accountId: Account.ID) async throws -> PerAccountStore {
        guard let account = accounts.first(where: { $0.id == accountId }) else {
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
        let result = try await connection.registerQueue(idleQueueTimeoutSeconds: 12 * 60 * 60)
        let snapshot = result.snapshot
        connection.featureLevel = snapshot.zulipFeatureLevel
        if let cacheURL = snapshotCacheURL(for: accountId) {
            try? result.rawData.write(to: cacheURL, options: .atomic)
        }
        let store = PerAccountStore(account: account, connection: connection, snapshot: snapshot)
        installStore(store, for: accountId)
        return store
    }

    private func installStore(_ store: PerAccountStore, for accountId: Account.ID) {
        machines[accountId]?.stop()
        provisionalStores.remove(accountId)
        stores[accountId] = store
        let machine = UpdateMachine(
            store: store, delegate: self, enablePresence: enablePresencePings, sleep: sleep)
        machine.eventObserver = { [weak self] event in
            self?.eventObserver?(accountId, event)
        }
        machines[accountId] = machine
        machine.start()
        storeGeneration += 1
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
