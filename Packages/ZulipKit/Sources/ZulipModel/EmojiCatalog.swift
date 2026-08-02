import Foundation
import ZulipAPI

/// Emoji character from Zulip's dash-joined hex codepoints ("1f44d-1f3fc").
public func emojiCharacter(fromCodes codes: String) -> String? {
    let scalars = codes.split(separator: "-")
        .compactMap { UInt32($0, radix: 16) }
        .compactMap { Unicode.Scalar($0) }
    guard !scalars.isEmpty else { return nil }
    return String(String.UnicodeScalarView(scalars))
}

/// One pickable emoji: a unicode emoji (character + shortcode) or a realm
/// custom emoji (image).
public struct EmojiEntry: Sendable, Hashable, Identifiable {
    public var name: String
    /// Reaction `emoji_code`: hex codepoints for unicode, emoji id for realm.
    public var code: String
    public var character: String?
    public var realmSrc: String?

    public var reactionType: String {
        character != nil ? "unicode_emoji" : "realm_emoji"
    }

    public var id: String { "\(reactionType):\(code)" }
}

public enum EmojiCatalog {
    /// Parses the server's emoji-data JSON (`server_emoji_data_url`):
    /// `{"code_to_names": {"1f419": ["octopus", …], …}}` — canonical name
    /// first.
    public static func parse(_ data: Data) throws -> [EmojiEntry] {
        struct ServerEmojiData: Decodable {
            var codeToNames: [String: [String]]
        }
        let decoded = try ZulipJSON.decoder.decode(ServerEmojiData.self, from: data)
        return decoded.codeToNames
            .compactMap { code, names -> EmojiEntry? in
                guard let name = names.first,
                      let character = emojiCharacter(fromCodes: code) else { return nil }
                return EmojiEntry(name: name, code: code, character: character, realmSrc: nil)
            }
            .sorted { $0.name < $1.name }
    }
}

/// Detects an in-progress autocomplete token at the end of compose text:
/// `@name`, `:shortcode`, or `#channel` (each needing a word boundary before
/// the trigger). Returns the token and where the trigger starts, so the
/// completion can replace the tail.
public enum ComposeAutocomplete {
    public enum Token: Equatable, Sendable {
        case mention(String)
        case emoji(String)
        case channel(String)
    }

    public static func trailingToken(in text: String) -> (token: Token, triggerIndex: String.Index)? {
        guard !text.isEmpty else { return nil }

        func lastTrigger(_ trigger: Character) -> String.Index? {
            guard let index = text.lastIndex(of: trigger) else { return nil }
            if index > text.startIndex {
                let before = text[text.index(before: index)]
                guard before.isWhitespace || before.isNewline else { return nil }
            }
            return index
        }

        let candidates: [(Character, String.Index)] = ["@", ":", "#"].compactMap { trigger in
            lastTrigger(trigger).map { (trigger, $0) }
        }
        guard let (trigger, index) = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        let query = String(text[text.index(after: index)...])
        guard query.count <= 30, !query.contains("\n") else { return nil }

        switch trigger {
        case "@":
            // Mention names may contain spaces; a completed mention ("**")
            // ends the token.
            guard !query.contains("*") else { return nil }
            return (.mention(query), index)
        case ":":
            // Shortcodes: word characters only, at least one (bare ":" is
            // usually punctuation).
            guard !query.isEmpty,
                  query.allSatisfy({ $0.isLetter || $0.isNumber || "_+-".contains($0) })
            else { return nil }
            return (.emoji(query), index)
        case "#":
            guard !query.contains("*") else { return nil }
            return (.channel(query), index)
        default:
            return nil
        }
    }
}

/// Who's typing where, from `typing` events, with server-tuned expiry.
@MainActor
@Observable
public final class TypingStatus {
    public private(set) var typists: [ConversationKey: [Int: Date]] = [:]

    public func typistIds(in key: ConversationKey) -> [Int] {
        (typists[key] ?? [:]).keys.sorted()
    }

    func handleStart(key: ConversationKey, userId: Int, expiryMilliseconds: Int) {
        typists[key, default: [:]][userId] = Date.now
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(expiryMilliseconds))
            guard let self,
                  let started = self.typists[key]?[userId],
                  Date.now.timeIntervalSince(started) * 1000 >= Double(expiryMilliseconds) - 100
            else { return }
            self.remove(key: key, userId: userId)
        }
    }

    func handleStop(key: ConversationKey, userId: Int) {
        remove(key: key, userId: userId)
    }

    private func remove(key: ConversationKey, userId: Int) {
        var forKey = typists[key] ?? [:]
        forKey.removeValue(forKey: userId)
        if forKey.isEmpty {
            typists.removeValue(forKey: key)
        } else {
            typists[key] = forKey
        }
    }
}
