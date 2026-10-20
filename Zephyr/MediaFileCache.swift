import CryptoKit
import Foundation
import ZulipAPI

/// Downloaded attachments, kept on disk so reopening one — in Quick Look,
/// Preview, a share or a drag — doesn't fetch it again, across launches.
///
/// Each attachment gets a folder named for a hash of its realm and path,
/// holding the file under its real name (so Preview and Quick Look title
/// it sensibly); the folder's modification date is when it was last
/// used. Entries unused for as long as message history is kept are
/// removed, and past the size limit set in Settings the least recently
/// used go first. The .noindex extension keeps Spotlight out: these are a
/// cache, not the user's files.
///
/// On macOS the files are Locked (Finder's flag): Open, and Quick Look's
/// Open with Preview, hand Preview the cached file itself, which it would
/// otherwise rename, move, or autosave markup into in place — locked,
/// Preview offers Duplicate. Copies keep the flag, so files handed onward
/// go through `mediaHandoffCopy(of:)` or `unlockMediaFile(_:)`.
enum MediaFileCache {
    /// Settings' size limit, in megabytes.
    static let sizeLimitKey = "mediaCacheLimitMB"
    static let defaultSizeLimitMB = 500

    nonisolated static let root = URL.cachesDirectory
        .appendingPathComponent("ZephyrPreviews.noindex", isDirectory: true)

    /// Unlocked copies for drags and shares, one UUID folder each; their
    /// receivers copy them straight away, so a day is plenty.
    nonisolated static let handoffRoot = URL.temporaryDirectory
        .appendingPathComponent("ZephyrHandoff.noindex", isDirectory: true)

    /// Where downloads went while the cache lived per launch in tmp.
    nonisolated private static let legacyRoots = [
        URL.temporaryDirectory.appendingPathComponent("ZephyrPreviews", isDirectory: true),
        URL.temporaryDirectory.appendingPathComponent("ZephyrPreviews.noindex", isDirectory: true),
    ]

    /// Entries used this recently survive the size limit, so a download
    /// larger than the limit isn't removed while it's being shown.
    nonisolated private static let inUseGrace: TimeInterval = 10 * 60

    private static var sweepPending = false

    /// The folder an attachment is cached in.
    static func folder(for path: String, realm: URL) -> URL {
        let digest = SHA256.hash(data: Data((realm.absoluteString + "\n" + path).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Marks a cached entry as just used.
    static func touch(_ folder: URL) {
        var folder = folder
        var values = URLResourceValues()
        values.contentModificationDate = .now
        try? folder.setResourceValues(values)
    }

    /// Applies the retention window and size limit in the background, a
    /// moment from now — so a gallery's burst of downloads sweeps once.
    /// Called at launch, after each download, and when either setting
    /// changes.
    static func scheduleSweep() {
        guard !sweepPending else { return }
        sweepPending = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            sweepPending = false
            let retentionDays = AppModel.storedRetentionDays
            let limitMB = UserDefaults.standard.object(forKey: sizeLimitKey) as? Int
                ?? defaultSizeLimitMB
            await Task.detached(priority: .background) {
                sweep(retentionDays: retentionDays, limitBytes: Int64(limitMB) * 1_000_000)
            }.value
        }
    }

    nonisolated private static func sweep(retentionDays: Int?, limitBytes: Int64) {
        let fileManager = FileManager.default
        let now = Date.now
        for legacy in legacyRoots {
            remove(legacy)
        }
        for folder in (try? fileManager.contentsOfDirectory(
            at: handoffRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where lastUsed(folder) < now.addingTimeInterval(-86_400) {
            remove(folder)
        }

        let folders = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var entries = folders.map { (folder: $0, used: lastUsed($0), bytes: allocatedSize($0)) }
        if let retentionDays {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            for entry in entries where entry.used < cutoff {
                remove(entry.folder)
            }
            entries.removeAll { $0.used < cutoff }
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.used < $1.used }) {
            guard total > limitBytes, entry.used < now.addingTimeInterval(-inUseGrace)
            else { break }
            remove(entry.folder)
            total -= entry.bytes
        }
    }

    nonisolated private static func lastUsed(_ folder: URL) -> Date {
        (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    nonisolated private static func allocatedSize(_ folder: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in files {
            bytes += Int64(
                (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0)
        }
        return bytes
    }

    /// Removes `item`, unlocking what's inside first: nothing can remove a
    /// Locked file, the system's own cleanup included.
    nonisolated private static func remove(_ item: URL) {
        if let files = FileManager.default.enumerator(at: item, includingPropertiesForKeys: nil) {
            for case let file as URL in files {
                unlockMediaFile(file)
            }
        }
        try? FileManager.default.removeItem(at: item)
    }
}

/// Downloads an attachment into `MediaFileCache`, or finds it there.
func downloadMediaFile(path: String, connection: ApiConnection) async -> URL? {
    let filename = (path as NSString).lastPathComponent.removingPercentEncoding
        .flatMap { $0.isEmpty ? nil : $0 } ?? "file"
    let folder = MediaFileCache.folder(for: path, realm: connection.realmURL)
    let fileURL = folder.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: fileURL.path) {
        MediaFileCache.touch(folder)
        return fileURL
    }
    guard let (data, _) = await fetchMedia(path: path, connection: connection) else { return nil }
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Atomic, so a file in the cache is always whole.
        try data.write(to: fileURL, options: .atomic)
    } catch {
        // A concurrent download of the same file got there first and
        // locked it (a gallery and a drag, say).
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }
    #if os(macOS)
    var locked = URLResourceValues()
    locked.isUserImmutable = true
    var lockedURL = fileURL
    try? lockedURL.setResourceValues(locked)
    #endif
    MediaFileCache.scheduleSweep()
    return fileURL
}

/// An unlocked copy of a cached attachment, for drag receivers and share
/// services: what lands in Finder or another app is the user's to edit,
/// and a plain copy would arrive Locked.
nonisolated func mediaHandoffCopy(of url: URL) -> URL {
    #if os(macOS)
    let directory = MediaFileCache.handoffRoot
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let copy = directory.appendingPathComponent(url.lastPathComponent)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        unlockMediaFile(copy)
        return copy
    } catch {
        return url
    }
    #else
    return url
    #endif
}

/// Clears the Locked flag `downloadMediaFile` sets.
nonisolated func unlockMediaFile(_ url: URL) {
    var url = url
    var unlocked = URLResourceValues()
    unlocked.isUserImmutable = false
    try? url.setResourceValues(unlocked)
}
