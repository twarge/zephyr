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

    /// The realm's square icon (the register snapshot carries its URL).
    func realmIcon(store: PerAccountStore) async -> PlatformImage? {
        await realmImage(path: store.realmIconUrl, cacheKey: "realm-icon", store: store)
    }

    /// The realm's wide organization logo, when uploaded (night variant in
    /// dark appearance).
    func realmLogo(store: PerAccountStore, dark: Bool) async -> PlatformImage? {
        await realmImage(
            path: store.realmLogoPath(dark: dark),
            cacheKey: dark ? "realm-logo-night" : "realm-logo", store: store)
    }

    private func realmImage(
        path: String?, cacheKey: String, store: PerAccountStore
    ) async -> PlatformImage? {
        let key = "\(store.connection.realmURL.absoluteString)|\(cacheKey)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }
        guard let path,
              let url = URL(string: path, relativeTo: store.connection.realmURL),
              let (data, _) = try? await ApiConnection.mediaSession.data(
                  for: URLRequest(url: url.absoluteURL)),
              let image = PlatformImage(data: data)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// The realm's branding for the toolbar above the sidebar: the wide
/// uploaded organization logo when there is one, else the square realm
/// icon, else the realm's initial while loading.
/// The server-name-in-titles preference's default: on for macOS and
/// iPad, off for iPhone — its narrow titles have no room for a prefix.
var serverNameInTitlesDefault: Bool {
    #if os(macOS)
    true
    #else
    UIDevice.current.userInterfaceIdiom != .phone
    #endif
}

/// navigationTitle with the server name prefixed ("Twarge: Git › …"),
/// preference-gated — with several servers connected at once, the title
/// says which one this window is on.
private struct ServerPrefixedTitle: ViewModifier {
    let store: PerAccountStore
    let title: String
    @AppStorage("serverNameInTitles") private var serverNameInTitles =
        serverNameInTitlesDefault

    func body(content: Content) -> some View {
        let name = store.realmName ?? ""
        content.navigationTitle(
            serverNameInTitles && !name.isEmpty ? "\(name): \(title)" : title)
    }
}

extension View {
    func serverTitled(_ title: String, store: PerAccountStore) -> some View {
        modifier(ServerPrefixedTitle(store: store, title: title))
    }
}

struct RealmLogoView: View {
    let store: PerAccountStore
    /// The bar's available content height (macOS toolbars are shorter
    /// than iPad navigation bars); width scales with it.
    var height: CGFloat = 20

    @Environment(\.colorScheme) private var colorScheme
    @State private var logo: PlatformImage?
    @State private var icon: PlatformImage?

    var body: some View {
        Group {
            if let logo {
                Image(platform: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .frame(maxWidth: height * 7.5, alignment: .leading)
                    // Ideal size always: a crowded toolbar otherwise
                    // squeezes the width, and scaledToFit shrinks the
                    // whole mark with it.
                    .fixedSize()
            } else if let icon {
                Image(platform: icon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: height, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: height / 4))
            } else {
                let name = store.realmName ?? store.connection.realmURL.host() ?? "?"
                Text(String(name.prefix(1)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: height, height: height)
                    .background(
                        .quaternary.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: height / 4))
            }
        }
        .help(store.realmName ?? store.connection.realmURL.host() ?? "")
        .task(id: "\(store.accountId)|\(colorScheme == .dark)") {
            logo = await AvatarLoader.shared.realmLogo(
                store: store, dark: colorScheme == .dark)
            if logo == nil {
                icon = await AvatarLoader.shared.realmIcon(store: store)
            }
        }
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

    // Sized to the platform's type: 8pt beside macOS's 13pt sidebar
    // rows read right; iOS's body-sized rows want ~50% more.
    #if os(macOS)
    private static let size: CGFloat = 8
    private static let stroke: CGFloat = 1.5
    #else
    private static let size: CGFloat = 12
    private static let stroke: CGFloat = 2
    #endif

    var body: some View {
        Group {
            switch state {
            case .active:
                Circle().fill(.green)
            case .idle:
                Circle().fill(.orange)
            case .offline:
                Circle().strokeBorder(.tertiary, lineWidth: Self.stroke)
            }
        }
        .frame(width: Self.size, height: Self.size)
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

    /// The web-app permalink to a channel ("copy link to channel").
    @MainActor
    static func channelLink(streamId: Int, in store: PerAccountStore) -> String {
        var base = store.connection.realmURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let name = (store.channels[streamId]?.name
            ?? store.subscriptions[streamId]?.name ?? "")
            .replacingOccurrences(of: " ", with: "-")
        return "\(base)/#narrow/channel/\(streamId)-\(encodeHashComponent(name))"
    }

    /// The web-app permalink to this conversation (topic or DM), without a
    /// message anchor.
    @MainActor
    func link(in store: PerAccountStore) -> String {
        switch self {
        case .topic(let streamId, let topic):
            return Self.channelLink(streamId: streamId, in: store)
                + "/topic/\(Self.encodeHashComponent(topic))"
        case .dm(let joined):
            var base = store.connection.realmURL.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            // The self-DM key has no participants; link it as dm with self.
            let ids = joined.isEmpty ? String(store.selfUserId) : joined
            return "\(base)/#narrow/dm/\(ids)-dm"
        }
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
        case .recent:
            components.queryItems = [URLQueryItem(name: "view", value: "recent")]
        case .inbox:
            components.queryItems = [URLQueryItem(name: "view", value: "inbox")]
        case .combinedFeed:
            components.queryItems = [URLQueryItem(name: "view", value: "combined")]
        case .drafts:
            components.queryItems = [URLQueryItem(name: "view", value: "drafts")]
        case .search(let text, let senderId, let streamId, let topic):
            var items = [URLQueryItem(name: "search", value: text ?? "")]
            if let senderId {
                items.append(URLQueryItem(name: "sender", value: String(senderId)))
            }
            if let streamId {
                items.append(URLQueryItem(name: "stream", value: String(streamId)))
            }
            if let topic {
                items.append(URLQueryItem(name: "topic", value: topic))
            }
            components.queryItems = items
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
        // Search first: its items can include stream/topic scope.
        if let text = value("search") {
            self = .search(
                text: text.isEmpty ? nil : text,
                senderId: value("sender").flatMap(Int.init),
                streamId: value("stream").flatMap(Int.init),
                topic: value("topic"))
        } else if let view = value("view") {
            switch view {
            case "recent": self = .recent
            case "inbox": self = .inbox
            case "combined": self = .combinedFeed
            case "drafts": self = .drafts
            default: return nil
            }
        } else if let streamValue = value("stream"), let streamId = Int(streamValue) {
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
    /// carries one). The store, when available, resolves display names for
    /// search tokens.
    func destination(
        selfUserId: Int, store: PerAccountStore?
    ) -> (destination: Destination, near: Int?) {
        switch self {
        case .channel(let streamId):
            return (.channel(streamId: streamId), nil)
        case .topic(let streamId, let topic, let near):
            return (.conversation(.topic(streamId: streamId, topic: topic)), near)
        case .dm(let userIds, let near):
            return (
                .conversation(Unreads.dmKey(participantIds: userIds, selfUserId: selfUserId)),
                near)
        case .starred:
            return (.starred, nil)
        case .mentions:
            return (.mentions, nil)
        case .recent, .inbox:
            // Zulip's Inbox has no direct analog; Recent is the closest.
            return (.recentConversations, nil)
        case .combinedFeed:
            return (.combinedFeed, nil)
        case .drafts:
            return (.drafts, nil)
        case .search(let text, let senderId, let streamId, let topic):
            var tokens: [SearchToken] = []
            if let streamId {
                let name = store?.channels[streamId]?.name
                    ?? store?.subscriptions[streamId]?.name ?? "channel"
                tokens.append(.channel(streamId: streamId, name: name))
            }
            if let topic {
                tokens.append(.topic(topic))
            }
            if let senderId {
                let name = store?.users[senderId]?.fullName ?? "User \(senderId)"
                tokens.append(.sender(userId: senderId, name: name))
            }
            return (.search(SearchQuery(tokens: tokens, text: text ?? "")), nil)
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
