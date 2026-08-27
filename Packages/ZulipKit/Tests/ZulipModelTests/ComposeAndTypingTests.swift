import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

struct ComposeAutocompleteTests {
    private func token(_ text: String) -> ComposeAutocomplete.Token? {
        ComposeAutocomplete.trailingToken(in: text)?.token
    }

    @Test func detectsTrailingTokens() {
        #expect(token("hello @Ti") == .mention("Ti"))
        #expect(token("@") == .mention(""))
        #expect(token("hey :oct") == .emoji("oct"))
        #expect(token("see #des") == .channel("des"))
        #expect(token("ping @Tim Ab") == .mention("Tim Ab"))
    }

    @Test func requiresBoundaryBeforeTrigger() {
        #expect(token("a@b") == nil)
        #expect(token("http://x") == nil)  // ':' not after whitespace
        #expect(token("c#4") == nil)
    }

    @Test func completedTokensStopSuggesting() {
        #expect(token("hi @**Tim Abbott** ") == nil)
        #expect(token("emoji :+1: done") == nil)  // ':' followed by space-containing tail
        #expect(token("in #**design** ") == nil)
    }

    @Test func laterTriggerWins() {
        #expect(token("@Tim said :thu") == .emoji("thu"))
        #expect(token(":+1 in #gen") == .channel("gen"))
    }

    @Test func replacementRangeCoversTrigger() throws {
        let text = "hello @Ti"
        let result = try #require(ComposeAutocomplete.trailingToken(in: text))
        var replaced = text
        replaced.replaceSubrange(result.triggerIndex..<text.endIndex, with: "@**Tim Abbott** ")
        #expect(replaced == "hello @**Tim Abbott** ")
    }

    @Test func tokenEndsAtTheCaret() throws {
        // Editing mid-message: the token is whatever precedes the caret,
        // and text after the caret never joins it.
        let text = "hey @Ti and more"
        let caret = text.index(text.startIndex, offsetBy: 7)  // after "@Ti"
        let result = try #require(ComposeAutocomplete.token(in: text, endingAt: caret))
        #expect(result.token == .mention("Ti"))
        var replaced = text
        replaced.replaceSubrange(result.triggerIndex..<caret, with: "@**Tim Abbott** ")
        #expect(replaced == "hey @**Tim Abbott**  and more")

        // The trailing "now" would have disqualified this shortcode.
        let emoji = "hey :oct now"
        let emojiCaret = emoji.index(emoji.startIndex, offsetBy: 8)  // after ":oct"
        #expect(ComposeAutocomplete.token(in: emoji, endingAt: emojiCaret)?.token
            == .emoji("oct"))

        // "/po|ll lunch": the command word is judged up to the caret.
        let command = "/po lunch"
        let commandCaret = command.index(command.startIndex, offsetBy: 3)
        #expect(ComposeAutocomplete.token(in: command, endingAt: commandCaret)?.token
            == .command("po"))

        // A caret before the trigger sees no token.
        #expect(ComposeAutocomplete.token(in: "@Tim", endingAt: "@Tim".startIndex) == nil)
    }
}

struct EmojiCatalogTests {
    @Test func parsesServerEmojiData() throws {
        let json = #"{"code_to_names": {"1f419": ["octopus"], "1f44d": ["+1", "thumbs_up"], "invalid": ["broken"]}}"#
        let entries = try EmojiCatalog.parse(Data(json.utf8))
        // "invalid" hex is dropped; canonical (first) names win; sorted.
        #expect(entries.map(\.name) == ["+1", "octopus"])
        #expect(entries.first { $0.name == "octopus" }?.character == "🐙")
        #expect(entries.first { $0.name == "+1" }?.character == "👍")
    }
}

@MainActor
struct TypingTests {
    private func makeStore(transport: FakeTransport) throws -> PerAccountStore {
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let snapshot = try ZulipJSON.decoder.decode(
            InitialSnapshot.self, from: Data(Fixtures.registerJSON(queueId: "q1").utf8))
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key", transport: transport)
        return PerAccountStore(account: account, connection: connection, snapshot: snapshot)
    }

    @Test func typingEventsTrackTypists() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        let key = ConversationKey.topic(streamId: 10, topic: "greetings")

        let start = #"{"id": 1, "type": "typing", "op": "start", "message_type": "stream", "sender": {"user_id": 2, "email": "other@example.com"}, "stream_id": 10, "topic": "greetings"}"#
        store.handleEvent(try decodeEvent(start))
        #expect(store.typing.typistIds(in: key) == [2])

        // Own typing events are ignored.
        let selfStart = #"{"id": 2, "type": "typing", "op": "start", "message_type": "stream", "sender": {"user_id": 1, "email": "self@example.com"}, "stream_id": 10, "topic": "greetings"}"#
        store.handleEvent(try decodeEvent(selfStart))
        #expect(store.typing.typistIds(in: key) == [2])

        let stop = #"{"id": 3, "type": "typing", "op": "stop", "message_type": "stream", "sender": {"user_id": 2, "email": "other@example.com"}, "stream_id": 10, "topic": "greetings"}"#
        store.handleEvent(try decodeEvent(stop))
        #expect(store.typing.typistIds(in: key).isEmpty)
    }

    @Test func dmTypingKeysNormalize() throws {
        let store = try makeStore(transport: FakeTransport(defaultResponse: .hang))
        let start = #"{"id": 1, "type": "typing", "op": "start", "message_type": "direct", "sender": {"user_id": 5, "email": "u5@example.com"}, "recipients": [{"user_id": 1, "email": "self@example.com"}, {"user_id": 5, "email": "u5@example.com"}]}"#
        store.handleEvent(try decodeEvent(start))
        #expect(store.typing.typistIds(in: .dm("5")) == [5])
    }

    @Test func typingActivityThrottlesStarts() async throws {
        let transport = FakeTransport(defaultResponse: .json(#"{"result": "success", "msg": ""}"#))
        let store = try makeStore(transport: transport)
        let destination = SendDestination.topic(streamId: 10, topic: "greetings")

        store.typingActivity(in: destination)
        store.typingActivity(in: destination)
        store.typingActivity(in: destination)
        try await eventually("one throttled start sent") {
            transport.requests.filter { $0.path == "/api/v1/typing" }.count == 1
        }
        let start = try #require(transport.requests.first { $0.path == "/api/v1/typing" })
        #expect(start.formValue("op") == "start")
        #expect(start.formValue("stream_id") == "10")

        store.typingStopped(in: destination)
        try await eventually("stop sent") {
            transport.requests.filter { $0.path == "/api/v1/typing" }.count == 2
        }
        let stop = transport.requests.filter { $0.path == "/api/v1/typing" }.last
        #expect(stop?.formValue("op") == "stop")
    }
}

@Suite struct SlashCommandTokenTests {
    @Test func slashAtStartSuggestsCommands() throws {
        let token = try #require(ComposeAutocomplete.trailingToken(in: "/p"))
        #expect(token.token == .command("p"))
        #expect(token.triggerIndex == "/p".startIndex)
        #expect(ComposeAutocomplete.trailingToken(in: "/")?.token == .command(""))
    }

    @Test func channelTopicLinkToken() throws {
        let token = try #require(ComposeAutocomplete.trailingToken(in: "see #general>rel"))
        #expect(token.token == .channelTopic(channel: "general", topic: "rel"))
        // Bare ">" right after the channel opens topic suggestions.
        #expect(ComposeAutocomplete.trailingToken(in: "#general>")?.token
            == .channelTopic(channel: "general", topic: ""))
        // A completed link stops suggesting.
        #expect(ComposeAutocomplete.trailingToken(in: "see #**general>rel** ") == nil)
    }

    @Test func slashElsewhereOrPastTheWordDoesNot() {
        // Mid-message slashes are just text.
        #expect(ComposeAutocomplete.trailingToken(in: "hi /p") == nil)
        // Past the command word, no command suggestions...
        #expect(ComposeAutocomplete.trailingToken(in: "/poll lunch") == nil)
        // ...but later triggers still autocomplete.
        #expect(ComposeAutocomplete.trailingToken(in: "/poll lunch with @Ni")?.token
            == .mention("Ni"))
    }
}

