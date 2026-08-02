import AppKit
import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// Memoized message-HTML parsing, keyed by (id, edit timestamp) so edits
/// re-parse exactly one message. One cache per open transcript.
@MainActor
final class MessageContentCache {
    private var cache: [Int: (edit: Int?, content: MessageContent)] = [:]

    func content(for message: Message) -> MessageContent {
        if let hit = cache[message.id], hit.edit == message.lastEditTimestamp {
            return hit.content
        }
        let parsed = ContentParser.parse(html: message.content)
        cache[message.id] = (message.lastEditTimestamp, parsed)
        return parsed
    }
}

// MARK: - Avatars

/// Fetches and caches user avatars. Users with an `avatar_url` load directly
/// (public paths); others go through the authenticated `/avatar/{id}`
/// redirect via `ApiConnection.mediaSession`.
@MainActor
final class AvatarLoader {
    static let shared = AvatarLoader()
    private let cache = NSCache<NSString, NSImage>()

    func image(for userId: Int, store: PerAccountStore) async -> NSImage? {
        let key = "\(store.connection.realmURL.absoluteString)|\(userId)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        let request: URLRequest?
        if let avatarUrl = store.users[userId]?.avatarUrl {
            request = URL(string: avatarUrl, relativeTo: store.connection.realmURL)
                .map { URLRequest(url: $0.absoluteURL) }
        } else {
            request = try? store.connection.authorizedURLRequest(path: "/avatar/\(userId)")
        }
        guard let request,
              let (data, _) = try? await ApiConnection.mediaSession.data(for: request),
              let image = NSImage(data: data)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Fetches and caches custom realm emoji images, pre-sized for inline text
/// embedding. Observable so text that fell back to `:name:` re-renders once
/// the image arrives.
@MainActor
@Observable
final class EmojiImageLoader {
    static let shared = EmojiImageLoader()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var inflight: Set<String> = []

    /// Returns the cached image, kicking off a fetch on miss (nil this pass;
    /// observation re-renders callers when it lands).
    func image(src: String, connection: ApiConnection) -> NSImage? {
        if let image = images[src] {
            return image
        }
        guard !inflight.contains(src) else { return nil }
        inflight.insert(src)
        Task {
            let request: URLRequest?
            if src.hasPrefix("http") {
                request = URL(string: src).map { URLRequest(url: $0) }
            } else {
                request = try? connection.authorizedURLRequest(path: src)
            }
            guard let request,
                  let (data, _) = try? await ApiConnection.mediaSession.data(for: request),
                  let image = NSImage(data: data)
            else { return }
            let height: CGFloat = 16
            let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
            image.size = NSSize(width: height * ratio, height: height)
            images[src] = image
        }
        return nil
    }
}

/// A user avatar: the real image when available, initials while loading or
/// on failure.
struct AvatarView: View {
    let store: PerAccountStore
    let userId: Int
    var size: CGFloat = 34

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else {
                InitialsAvatar(
                    name: store.users[userId]?.fullName ?? "?", seed: userId, size: size)
            }
        }
        .task(id: userId) {
            image = await AvatarLoader.shared.image(for: userId, store: store)
        }
    }
}

struct InitialsAvatar: View {
    let name: String
    let seed: Int
    var size: CGFloat = 34

    private var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.stableColor(for: seed).gradient, in: .circle)
    }
}

// MARK: - Titles and links

extension ConversationKey {
    @MainActor
    func displayTitle(in store: PerAccountStore) -> String {
        switch self {
        case .dm(let joined):
            let ids = joined.split(separator: ",").compactMap { Int($0) }
            if ids.isEmpty { return "Yourself" }
            return ids.map { store.users[$0]?.fullName ?? "User \($0)" }
                .joined(separator: ", ")
        case .topic(let streamId, let topic):
            let channel = (store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name)
                .map { "#\($0)" } ?? "#?"
            let display = TopicName.displayName(topic)
            return display.isEmpty ? channel : display
        }
    }
}

/// Bridges `InternalLink` to the custom URL scheme the content renderer
/// embeds and `MainSplitView`'s OpenURLAction decodes.
extension InternalLink {
    var appURL: URL? {
        var components = URLComponents()
        components.scheme = "zephyr"
        components.host = "narrow"
        switch self {
        case .channel(let streamId):
            components.queryItems = [URLQueryItem(name: "stream", value: String(streamId))]
        case .topic(let streamId, let topic, let near):
            components.queryItems = [
                URLQueryItem(name: "stream", value: String(streamId)),
                URLQueryItem(name: "topic", value: topic),
            ]
            if let near {
                components.queryItems?.append(URLQueryItem(name: "near", value: String(near)))
            }
        }
        return components.url
    }

    init?(appURL: URL) {
        guard appURL.scheme == "zephyr", appURL.host() == "narrow",
              let components = URLComponents(url: appURL, resolvingAgainstBaseURL: false),
              let streamValue = components.queryItems?.first(where: { $0.name == "stream" })?.value,
              let streamId = Int(streamValue)
        else { return nil }
        let topic = components.queryItems?.first(where: { $0.name == "topic" })?.value
        let near = components.queryItems?.first(where: { $0.name == "near" })?.value.flatMap(Int.init)
        if let topic {
            self = .topic(streamId: streamId, topic: topic, nearMessageId: near)
        } else {
            self = .channel(streamId: streamId)
        }
    }
}

/// Messages-style day labels: Today, Yesterday, weekday within a week,
/// then dates.
func daySeparatorLabel(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        return String(localized: "Today")
    }
    if calendar.isDateInYesterday(date) {
        return String(localized: "Yesterday")
    }
    if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now)),
       date >= weekAgo {
        return date.formatted(.dateTime.weekday(.wide))
    }
    return date.formatted(date: .abbreviated, time: .omitted)
}
