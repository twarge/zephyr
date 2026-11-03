import Testing
@testable import ZulipContent

/// `hide_link_previews` (Zulip 13): which blocks a flagged message drops,
/// matching the web app's `.hide-link-previews` rules.
struct HiddenLinkPreviewTests {
    static let paragraph = #"<p><a href="https://example.com/post">https://example.com/post</a></p>"#
    static let websiteCard = #"<div class="message_embed"><a class="message_embed_image" href="https://example.com/post" style="background-image: url('https://cdn.example.com/thumb.jpg')"></a><div class="data-container"><div class="message_embed_title"><a href="https://example.com/post" title="A Post">A Post</a></div><div class="message_embed_description">Something interesting.</div></div></div>"#
    static let youtube = #"<div class="youtube-video message_inline_image"><a data-id="abc123" href="https://www.youtube.com/watch?v=abc123"><img src="https://i.ytimg.com/vi/abc123/default.jpg"></a></div>"#
    static let uploadedVideo = #"<div class="message_inline_image message_inline_video"><a href="/user_uploads/2/ab/clip.mp4" title="clip.mp4"><video preload="metadata" src="/user_uploads/2/ab/clip.mp4"></video></a></div>"#
    static let image = #"<div class="message_inline_image"><a href="/user_uploads/a.jpg"><img src="/thumb/a.webp"></a></div>"#

    @Test func websiteCardsAndVideoEmbedsHide() {
        let content = ContentParser.parse(
            html: Self.paragraph + Self.websiteCard + "<p>and</p>" + Self.youtube)
        #expect(content.hasHideableLinkPreviews)
        let hidden = content.withoutLinkPreviews()
        #expect(hidden.blocks == ContentParser.parse(html: Self.paragraph + "<p>and</p>").blocks)
        #expect(!hidden.hasHideableLinkPreviews)
    }

    @Test func imagePreviewsAndUploadedVideosStay() {
        // A bare image URL renders as its preview alone; hiding it would
        // blank the message, so the web keeps these (and the menu skips
        // messages that have nothing else).
        let content = ContentParser.parse(html: Self.image + Self.uploadedVideo)
        #expect(!content.hasHideableLinkPreviews)
        #expect(content.withoutLinkPreviews() == content)
    }

    @Test func nestedPreviewsHideToo() {
        let content = ContentParser.parse(
            html: "<blockquote>\n" + Self.paragraph + Self.websiteCard + "\n</blockquote>"
                + "<ul>\n<li>" + Self.youtube + "</li>\n</ul>")
        #expect(content.hasHideableLinkPreviews)
        let hidden = content.withoutLinkPreviews()
        #expect(!hidden.hasHideableLinkPreviews)
        guard case .blockquote(let quoted) = hidden.blocks.first else {
            Issue.record("expected the quote to survive: \(hidden.blocks)")
            return
        }
        #expect(quoted == ContentParser.parse(html: Self.paragraph).blocks)
    }

    @Test func plainMessagesHaveNothingToHide() {
        let content = ContentParser.parse(html: "<p>hello</p>")
        #expect(!content.hasHideableLinkPreviews)
        #expect(content.withoutLinkPreviews() == content)
    }
}
