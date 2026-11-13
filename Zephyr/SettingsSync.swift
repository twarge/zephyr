import Foundation
import ZulipModel

/// Carries the user's preferences between their devices through iCloud's
/// key-value store.
///
/// Settings stay in `UserDefaults`, where every `@AppStorage` reads them; this
/// only copies a fixed list of keys in both directions. What describes one
/// device rather than the person stays put: the front server and everything
/// keyed by a local account id, sidebar and compose layout, drafts, search
/// history, the media cache's size, how many years of messages this device
/// keeps (a shorter choice elsewhere must not prune history here), whether
/// this device notifies, and anything a Focus filter has set. Credentials never go near it.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    static let syncedKeys: [String] = [
        "badgePolicy",
        "dmSortOrder",
        "channelsAboveDMs",
        "topicsFollowSelection",
        "combinedShowsMuted",
        "recentSearchLimit",
        "serverNameInTitles",
        "commandClickOpensTab",
        ComposeBar.returnSendsKey,
        MessageSounds.personalKey,
        MessageSounds.otherKey,
        MessageSounds.sendKey,
    ]

    /// Where the front account's server and email are published for the
    /// tvOS monitor's sign-in form to prefill (Apps/TV reads the same
    /// names). One way, and never a key or password: the TV still asks for
    /// its own API key.
    static let activeRealmKey = "activeAccountRealm"
    static let activeEmailKey = "activeAccountEmail"

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
    }

    /// Begins syncing. Without the iCloud entitlement, or signed out of
    /// iCloud, the store simply never reports or accepts anything.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.pull(keys: keys ?? Self.syncedKeys) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        })
        store.synchronize()
        pull(keys: Self.syncedKeys)
    }

    /// Cloud to device, for keys the cloud has a value for.
    private func pull(keys: [String]) {
        for key in keys where Self.syncedKeys.contains(key) {
            guard let value = store.object(forKey: key) as? NSObject,
                  (defaults.object(forKey: key) as? NSObject) != value
            else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// Device to cloud, for keys the user has actually set. A registered
    /// default is not a choice and must not overwrite one made elsewhere.
    private func push() {
        let chosen = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in Self.syncedKeys {
            guard let value = chosen[key] as? NSObject,
                  (store.object(forKey: key) as? NSObject) != value
            else { continue }
            store.set(value, forKey: key)
        }
        publishActiveAccount()
    }

    /// The front server changes by a `UserDefaults` write (AppStateStore),
    /// so this rides along with `push`. Signing out of the last account
    /// withdraws what was published.
    private func publishActiveAccount() {
        guard let global = AppModel.shared?.global else { return }
        let accounts = global.enabledAccounts
        let active = accounts.first { $0.id == AppStateStore.lastActiveAccount } ?? accounts.first
        set(active?.realmURL.absoluteString, forKey: Self.activeRealmKey)
        set(active?.email, forKey: Self.activeEmailKey)
    }

    private func set(_ value: String?, forKey key: String) {
        guard store.string(forKey: key) != value else { return }
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
    }
}
