import Foundation

/// The unread digest the app writes into the App Group container and the
/// widget renders. Compiled into both targets; keep it dependency-free.
nonisolated struct UnreadSummary: Codable, Equatable {
    struct Line: Codable, Equatable, Identifiable {
        var title: String
        var count: Int
        var id: String { title }
    }

    /// One server's slice of the digest; the widget shows one row per
    /// server when more than one is connected.
    struct ServerLine: Codable, Equatable {
        var name: String
        var unread: Int
        var mentions: Int
    }

    var totalUnread: Int
    var mentions: Int
    /// The most unread conversations across every server, best first.
    var lines: [Line]
    /// Per-server breakdown, busiest first. Optional so a file written
    /// by an older app still decodes in a newer widget.
    var servers: [ServerLine]? = nil
    var updated: Date

    static let groupId = "group.com.twarge.zephyr"
    static let filename = "unread-summary.json"

    static var containerFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupId)?
            .appendingPathComponent(filename)
    }

    static func load() -> UnreadSummary? {
        guard let url = containerFileURL, let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(UnreadSummary.self, from: data)
    }
}
