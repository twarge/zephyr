import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel
#if canImport(UIKit)
import UIKit
#endif

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
    private let cache = NSCache<NSString, PlatformImage>()

    func image(for userId: Int, store: PerAccountStore) async -> PlatformImage? {
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
              let image = PlatformImage(data: data)
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
    private(set) var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var inflight: Set<String> = []

    /// Returns the cached image, kicking off a fetch on miss (nil this pass;
    /// observation re-renders callers when it lands).
    func image(src: String, connection: ApiConnection) -> PlatformImage? {
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
                  let image = PlatformImage(data: data)
            else { return }
            let height: CGFloat = 16
            let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
            let target = CGSize(width: height * ratio, height: height)
            #if canImport(AppKit)
            image.size = target
            images[src] = image
            #else
            // UIImage.size is immutable — redraw at the inline-emoji size.
            images[src] = UIGraphicsImageRenderer(size: target).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            #endif
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

    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platform: image)
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

/// Presence indicator: green = active, orange = idle, hollow = offline.
struct PresenceDot: View {
    let state: PresenceState

    var body: some View {
        Group {
            switch state {
            case .active:
                Circle().fill(.green)
            case .idle:
                Circle().fill(.orange)
            case .offline:
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .help(helpText)
    }

    private var helpText: String {
        switch state {
        case .active: "Active"
        case .idle: "Idle"
        case .offline: "Offline"
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
    /// Zulip's hash encoding: encodeURIComponent, then `%` → `.` (so the
    /// fragment survives routers that split on `%`).
    static func encodeHashComponent(_ text: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return (text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text)
            .replacingOccurrences(of: "%", with: ".")
    }

    /// The web-app permalink to a message ("copy link to message" /
    /// quote-and-reply's [said](…) target).
    static func permalink(to message: Message, in store: PerAccountStore) -> String {
        var base = store.connection.realmURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let narrow: String
        if let streamId = message.streamId {
            let name = (store.channels[streamId]?.name
                ?? store.subscriptions[streamId]?.name ?? "")
                .replacingOccurrences(of: " ", with: "-")
            narrow = "channel/\(streamId)-\(encodeHashComponent(name))"
                + "/topic/\(encodeHashComponent(message.subject))"
        } else if case .users(let recipients) = message.displayRecipient {
            let ids = recipients.map(\.id).sorted().map(String.init).joined(separator: ",")
            narrow = "dm/\(ids)-dm"
        } else {
            narrow = ""
        }
        return "\(base)/#narrow/\(narrow)/near/\(message.id)"
    }

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
        case .dm(let userIds, let near):
            components.queryItems = [
                URLQueryItem(name: "dm", value: userIds.map(String.init).joined(separator: ","))
            ]
            if let near {
                components.queryItems?.append(URLQueryItem(name: "near", value: String(near)))
            }
        case .starred:
            components.queryItems = [URLQueryItem(name: "is", value: "starred")]
        case .mentions:
            components.queryItems = [URLQueryItem(name: "is", value: "mentioned")]
        }
        return components.url
    }

    init?(appURL: URL) {
        guard appURL.scheme == "zephyr", appURL.host() == "narrow",
              let components = URLComponents(url: appURL, resolvingAgainstBaseURL: false)
        else { return nil }
        let value = { (name: String) in
            components.queryItems?.first(where: { $0.name == name })?.value
        }
        let near = value("near").flatMap(Int.init)
        if let streamValue = value("stream"), let streamId = Int(streamValue) {
            if let topic = value("topic") {
                self = .topic(streamId: streamId, topic: topic, nearMessageId: near)
            } else {
                self = .channel(streamId: streamId)
            }
        } else if let dm = value("dm") {
            let ids = dm.split(separator: ",").compactMap { Int($0) }
            guard !ids.isEmpty else { return nil }
            self = .dm(userIds: ids, nearMessageId: near)
        } else if let view = value("is") {
            switch view {
            case "starred": self = .starred
            case "mentioned": self = .mentions
            default: return nil
            }
        } else {
            return nil
        }
    }

    /// The in-app destination (with the message to land on, when the link
    /// carries one).
    func destination(selfUserId: Int) -> (destination: Destination, near: Int?) {
        switch self {
        case .channel(let streamId):
            (.channel(streamId: streamId), nil)
        case .topic(let streamId, let topic, let near):
            (.conversation(.topic(streamId: streamId, topic: topic)), near)
        case .dm(let userIds, let near):
            (.conversation(Unreads.dmKey(participantIds: userIds, selfUserId: selfUserId)), near)
        case .starred:
            (.starred, nil)
        case .mentions:
            (.mentions, nil)
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
