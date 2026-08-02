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
        #expect(InternalLink.parse(href: "/#narrow/dm/5-user", realmURL: realm) == nil)
        #expect(InternalLink.parse(href: "https://example.com/docs", realmURL: realm) == nil)
        #expect(InternalLink.parse(href: "/#settings", realmURL: realm) == nil)
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
