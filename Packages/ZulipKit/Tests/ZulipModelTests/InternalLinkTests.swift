import Foundation
import Testing
@testable import ZulipModel

struct InternalLinkTests {
    private let realm = URL(string: "https://chat.example.com")!

    @Test func topicLink() {
        #expect(
            InternalLink.parse(href: "/#narrow/channel/9-announce/topic/hi.20there", realmURL: realm)
                == .topic(streamId: 9, topic: "hi there", nearMessageId: nil))
    }

    @Test func messageLinkWithNear() {
        #expect(
            InternalLink.parse(
                href: "/#narrow/channel/9-announce/topic/hi/near/123", realmURL: realm)
                == .topic(streamId: 9, topic: "hi", nearMessageId: 123))
        #expect(
            InternalLink.parse(href: "/#narrow/channel/9-announce/topic/hi/with/123", realmURL: realm)
                == .topic(streamId: 9, topic: "hi", nearMessageId: 123))
    }

    @Test func channelLink() {
        #expect(
            InternalLink.parse(href: "/#narrow/channel/9-announce", realmURL: realm)
                == .channel(streamId: 9))
    }

    @Test func legacyOperatorNames() {
        #expect(
            InternalLink.parse(href: "/#narrow/stream/9-announce/subject/hi", realmURL: realm)
                == .topic(streamId: 9, topic: "hi", nearMessageId: nil))
    }

    @Test func absoluteURLSameHostOnly() {
        #expect(
            InternalLink.parse(
                href: "https://chat.example.com/#narrow/channel/9-announce", realmURL: realm)
                == .channel(streamId: 9))
        #expect(
            InternalLink.parse(
                href: "https://other.example.com/#narrow/channel/9-announce", realmURL: realm)
                == nil)
    }

    @Test func unsupportedNarrowsFallThrough() {
        #expect(InternalLink.parse(href: "https://example.com/docs", realmURL: realm) == nil)
        #expect(InternalLink.parse(href: "/#settings", realmURL: realm) == nil)
        #expect(InternalLink.parse(href: "/#narrow/search/kernel", realmURL: realm) == nil)
    }

    @Test func dotEncodedTopics() {
        // "." encodes as ".2E"
        #expect(InternalLink.decodeHashComponent("v1.2E2") == "v1.2")
        #expect(InternalLink.decodeHashComponent(".23fun") == "#fun")
    }
}

struct TopicNameTests {
    @Test func resolvedPrefix() {
        #expect(TopicName.isResolved("✔ fixed the bug"))
        #expect(TopicName.displayName("✔ fixed the bug") == "fixed the bug")
        #expect(!TopicName.isResolved("normal topic"))
        #expect(TopicName.displayName("normal topic") == "normal topic")
    }
}

@Suite struct NarrowLinkExtensionsTests {
    private let realm = URL(string: "https://discourse.example.com")!

    @Test func absoluteTopicNearLink() {
        let link = InternalLink.parse(
            href: "https://discourse.example.com/#narrow/channel/63-Twarge-Software/topic/tw-chibi/near/80345",
            realmURL: realm)
        #expect(link == .topic(streamId: 63, topic: "tw-chibi", nearMessageId: 80345))
    }

    @Test func otherHostFallsThrough() {
        let link = InternalLink.parse(
            href: "https://elsewhere.example.com/#narrow/channel/63-x/topic/y",
            realmURL: realm)
        #expect(link == nil)
    }

    @Test func dmLinks() {
        #expect(InternalLink.parse(href: "#narrow/dm/9,10-dm/near/42", realmURL: realm)
            == .dm(userIds: [9, 10], nearMessageId: 42))
        // Single person: "{id}-{name}".
        #expect(InternalLink.parse(href: "#narrow/dm/9-tom", realmURL: realm)
            == .dm(userIds: [9], nearMessageId: nil))
        // Legacy operator and suffix.
        #expect(InternalLink.parse(href: "#narrow/pm-with/9,10-pm", realmURL: realm)
            == .dm(userIds: [9, 10], nearMessageId: nil))
    }

    @Test func viewLinks() {
        #expect(InternalLink.parse(href: "#narrow/is/starred", realmURL: realm) == .starred)
        #expect(InternalLink.parse(href: "#narrow/is/mentioned", realmURL: realm) == .mentions)
        #expect(InternalLink.parse(href: "#narrow/is/resolved", realmURL: realm) == nil)
    }
}

