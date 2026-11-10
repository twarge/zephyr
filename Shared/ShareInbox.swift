import Foundation

/// The App Group "share inbox": the share extension drops files and text
/// here; on next activation the app offers a destination picker and seeds
/// the compose bar. Compiled into both the app and the extension.
nonisolated enum ShareInbox {
    struct PendingItem: Equatable {
        var directory: URL
        var files: [URL]
        var text: String?
    }

    private static var inboxURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: UnreadSummary.groupId)?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    /// Extension side: a fresh item directory to copy attachments into.
    static func beginItem() -> URL? {
        guard let inbox = inboxURL else { return nil }
        let directory = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Darwin notification the extension posts once an item's manifest is
    /// written, so a running app picks the share up without waiting for
    /// its next activation.
    static let changedNotificationName = "com.twarge.zephyr.share-inbox-changed"

    /// A directory still without a manifest after this long was abandoned
    /// mid-copy (extension killed, out of space) and is swept.
    static let abandonedAfter: TimeInterval = 3600

    /// Extension side: writing the manifest marks the item complete (the
    /// app ignores directories that are still being filled). Atomic, so the
    /// app never reads a half-written manifest. Returns whether it landed.
    @discardableResult
    static func finishItem(_ directory: URL, text: String?) -> Bool {
        let manifest = ["text": text ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest),
              (try? data.write(
                to: directory.appendingPathComponent("manifest.json"), options: .atomic)) != nil
        else { return false }
        return true
    }

    /// Extension side: tells a running app the inbox has a new item.
    static func postChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changedNotificationName as CFString),
            nil, nil, true)
    }

    /// App side: completed inbox items; empty and abandoned leftovers are
    /// swept.
    static func pendingItems() -> [PendingItem] {
        guard let inbox = inboxURL,
              let directories = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: [.creationDateKey])
        else { return [] }
        return directories.compactMap { directory in
            guard let data = try? Data(
                    contentsOf: directory.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else {
                // No manifest: either still being filled (leave it) or
                // abandoned (remove it, or it leaks forever).
                let created = (try? directory.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate ?? .distantPast
                if Date.now.timeIntervalSince(created) > abandonedAfter {
                    try? FileManager.default.removeItem(at: directory)
                }
                return nil
            }
            let files = ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != "manifest.json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let text = manifest["text"].flatMap { $0.isEmpty ? nil : $0 }
            guard !files.isEmpty || text != nil else {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
            return PendingItem(directory: directory, files: files, text: text)
        }
    }

    static func clear(_ item: PendingItem) {
        try? FileManager.default.removeItem(at: item.directory)
    }
}
