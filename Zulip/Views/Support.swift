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
            return topic.isEmpty ? channel : "\(channel) › \(topic)"
        }
    }
}

/// Emoji character from Zulip's dash-joined hex codepoints ("1f44d-1f3fc").
func emojiCharacter(fromCodes codes: String) -> String? {
    let scalars = codes.split(separator: "-")
        .compactMap { UInt32($0, radix: 16) }
        .compactMap { Unicode.Scalar($0) }
    guard !scalars.isEmpty else { return nil }
    return String(String.UnicodeScalarView(scalars))
}
