import Foundation
import ZulipModel

/// Persists the application state that governs what you're looking at: the
/// front server, each server's selected destination, and sidebar
/// expansion — restored on launch.
@MainActor
enum AppStateStore {
    private static var defaults: UserDefaults { .standard }

    static var lastActiveAccount: UUID? {
        get {
            defaults.string(forKey: "lastActiveAccount").flatMap(UUID.init(uuidString:))
        }
        set {
            defaults.set(newValue?.uuidString, forKey: "lastActiveAccount")
        }
    }

    static func selection(for accountId: UUID) -> Destination? {
        guard let data = defaults.data(forKey: "selection-\(accountId.uuidString)") else {
            return nil
        }
        return try? JSONDecoder().decode(Destination.self, from: data)
    }

    static func setSelection(_ destination: Destination?, for accountId: UUID) {
        let key = "selection-\(accountId.uuidString)"
        if let destination, let data = try? JSONEncoder().encode(destination) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func expandedChannels(for accountId: UUID) -> Set<Int> {
        Set(defaults.array(forKey: "expandedChannels-\(accountId.uuidString)") as? [Int] ?? [])
    }

    static func setExpandedChannels(_ channels: Set<Int>, for accountId: UUID) {
        defaults.set(Array(channels), forKey: "expandedChannels-\(accountId.uuidString)")
    }

    static func collapsedSections(for accountId: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: "collapsedSections-\(accountId.uuidString)") ?? [])
    }

    static func setCollapsedSections(_ sections: Set<String>, for accountId: UUID) {
        defaults.set(Array(sections), forKey: "collapsedSections-\(accountId.uuidString)")
    }
}
