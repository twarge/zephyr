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

    /// Extension side: writing the manifest marks the item complete (the
    /// app ignores directories that are still being filled).
    static func finishItem(_ directory: URL, text: String?) {
        let manifest = ["text": text ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: manifest) {
            try? data.write(to: directory.appendingPathComponent("manifest.json"))
        }
    }

    /// App side: completed inbox items; empty leftovers are swept.
    static func pendingItems() -> [PendingItem] {
        guard let inbox = inboxURL,
              let directories = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil)
        else { return [] }
        return directories.compactMap { directory in
            guard let data = try? Data(
                    contentsOf: directory.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return nil }
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
