import Testing
@testable import ZulipContent

/// Fixtures follow the exact HTML shapes Zulip's server renderer emits
/// (verified against live servers and zulip-flutter's parser tests).
struct ContentParserTests {
    @Test func simpleParagraph() {
        let content = ContentParser.parse(html: "<p>hello <strong>world</strong></p>")
        #expect(content.blocks == [
            .paragraph([.text("hello "), .strong([.text("world")])])
        ])
    }

    @Test func multipleParagraphsAndFormatting() {
        let content = ContentParser.parse(
            html: "<p>one <em>two</em> <del>three</del></p>\n<p>four <code>let x</code></p>")
        #expect(content.blocks.count == 2)
        #expect(content.blocks[1] == .paragraph([.text("four "), .inlineCode("let x")]))
    }

    @Test func userMention() {
        let content = ContentParser.parse(
            html: #"<p><span class="user-mention" data-user-id="31">@Example User</span> hi</p>"#)
        #expect(content.blocks == [
            .paragraph([
                .mention(MentionNode(text: "@Example User", target: .user(id: 31), silent: false)),
                .text(" hi"),
            ])
        ])
    }

    @Test func silentAndWildcardMentions() {
        let silent = ContentParser.parse(
            html: #"<p><span class="user-mention silent" data-user-id="31">Example User</span></p>"#)
        guard case .paragraph(let inlines) = silent.blocks[0],
              case .mention(let mention) = inlines[0] else {
            Issue.record("expected mention")
            return
        }
        #expect(mention.silent)

        let wildcard = ContentParser.parse(
            html: #"<p><span class="user-mention channel-wildcard-mention" data-user-id="*">@all</span></p>"#)
        guard case .paragraph(let wInlines) = wildcard.blocks[0],
              case .mention(let wMention) = wInlines[0] else {
            Issue.record("expected wildcard mention")
            return
        }
        #expect(wMention.target == .channelWildcard)
    }

    @Test func groupMention() {
        let content = ContentParser.parse(
            html: #"<p><span class="user-group-mention" data-user-group-id="17">@support</span></p>"#)
        #expect(content.blocks == [
            .paragraph([
                .mention(MentionNode(text: "@support", target: .userGroup(id: 17), silent: false))
            ])
        ])
    }

    @Test func unicodeEmoji() {
        let content = ContentParser.parse(
            html: #"<p><span aria-label="smiling face" class="emoji emoji-263a" role="img" title="smiling face">:smiling_face:</span></p>"#)
        #expect(content.blocks == [
            .paragraph([.emoji(.unicode("\u{263a}", name: "smiling_face"))])
        ])
    }

    @Test func multiCodepointEmoji() {
        // 👍🏼 = 1f44d + 1f3fc
        let content = ContentParser.parse(
            html: #"<p><span class="emoji emoji-1f44d-1f3fc" title="+1">:+1:</span></p>"#)
        guard case .paragraph(let inlines) = content.blocks[0],
              case .emoji(.unicode(let character, _)) = inlines[0] else {
            Issue.record("expected emoji")
            return
        }
        #expect(character == "👍🏼")
    }

    @Test func realmEmoji() {
        let content = ContentParser.parse(
            html: #"<p><img alt=":zulip:" class="emoji" src="/user_avatars/2/emoji/images/43.png" title="zulip"></p>"#)
        #expect(content.blocks == [
            .paragraph([.emoji(.realm(src: "/user_avatars/2/emoji/images/43.png", name: "zulip"))])
        ])
    }

    @Test func channelAndTopicLinks() {
        let content = ContentParser.parse(
            html: #"<p><a class="stream" data-stream-id="9" href="/#narrow/channel/9-announce">#announce</a> and <a class="stream-topic" data-stream-id="9" href="/#narrow/channel/9-announce/topic/hi">#announce &gt; hi</a></p>"#)
        guard case .paragraph(let inlines) = content.blocks[0] else {
            Issue.record("expected paragraph")
            return
        }
        guard case .link(let channelLink) = inlines[0],
              case .link(let topicLink) = inlines[2] else {
            Issue.record("expected links")
            return
        }
        #expect(channelLink.kind == .channel(streamId: 9))
        #expect(topicLink.kind == .channelTopic(streamId: 9))
    }

    @Test func codeBlockPreservesWhitespaceAndLanguage() {
        let content = ContentParser.parse(
            html: "<div class=\"codehilite\" data-code-language=\"Python\"><pre><span></span><code><span class=\"k\">def</span> <span class=\"nf\">f</span><span class=\"p\">():</span>\n    <span class=\"k\">pass</span>\n</code></pre></div>")
        #expect(content.blocks == [
            .codeBlock(language: "Python", code: "def f():\n    pass")
        ])
    }

    @Test func lists() {
        let unordered = ContentParser.parse(html: "<ul>\n<li>one</li>\n<li>two <strong>bold</strong></li>\n</ul>")
        #expect(unordered.blocks == [
            .unorderedList(items: [
                [.paragraph([.text("one")])],
                [.paragraph([.text("two "), .strong([.text("bold")])])],
            ])
        ])

        let ordered = ContentParser.parse(html: #"<ol start="3"><li>three</li></ol>"#)
        #expect(ordered.blocks == [
            .orderedList(start: 3, items: [[.paragraph([.text("three")])]])
        ])
    }

    @Test func blockquoteAndHeading() {
        let content = ContentParser.parse(
            html: "<blockquote>\n<p>quoted</p>\n</blockquote>\n<h3>title</h3>")
        #expect(content.blocks == [
            .blockquote([.paragraph([.text("quoted")])]),
            .heading(level: 3, [.text("title")]),
        ])
    }

    @Test func spoiler() {
        let content = ContentParser.parse(
            html: #"<div class="spoiler-block"><div class="spoiler-header">\#n<p>the reveal</p>\#n</div><div class="spoiler-content" aria-hidden="true">\#n<p>hidden text</p>\#n</div></div>"#)
        #expect(content.blocks == [
            .spoiler(
                header: [.text("the reveal")],
                content: [.paragraph([.text("hidden text")])])
        ])
    }

    @Test func inlineImage() {
        let content = ContentParser.parse(
            html: #"<div class="message_inline_image"><a href="/user_uploads/2/ab/photo.jpg" title="photo.jpg"><img data-original-content-type="image/jpeg" data-original-dimensions="1920x1080" src="/user_uploads/thumbnail/2/ab/photo.jpg/840x560.webp"></a></div>"#)
        #expect(content.blocks == [
            .image(
                ImageNode(
                    src: "/user_uploads/thumbnail/2/ab/photo.jpg/840x560.webp",
                    originalSrc: "/user_uploads/2/ab/photo.jpg",
                    alt: nil,
                    originalWidth: 1920,
                    originalHeight: 1080))
        ])
    }

    @Test func globalTime() {
        let content = ContentParser.parse(
            html: #"<p><time datetime="2026-08-01T17:00:00Z">Sat, Aug 1 2026, 10:00 AM</time></p>"#)
        #expect(content.blocks == [
            .paragraph([.globalTime(datetime: "2026-08-01T17:00:00Z")])
        ])
    }

    @Test func inlineAndBlockMath() {
        let inline = ContentParser.parse(
            html: #"<p><span class="katex"><span class="katex-mathml"><math xmlns="http://www.w3.org/1998/Math/MathML"><semantics><mrow><mi>x</mi></mrow><annotation encoding="application/x-tex">x^2</annotation></semantics></math></span><span class="katex-html" aria-hidden="true"><span class="base"><span class="mord mathnormal">x</span></span></span></span></p>"#)
        #expect(inline.blocks == [.paragraph([.inlineMath(tex: "x^2")])])

        let block = ContentParser.parse(
            html: #"<p><span class="katex-display"><span class="katex"><span class="katex-mathml"><math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><semantics><mrow><mi>e</mi></mrow><annotation encoding="application/x-tex">e=mc^2</annotation></semantics></math></span></span></span></p>"#)
        #expect(block.blocks == [.mathBlock(tex: "e=mc^2")])
    }

    @Test func unknownContentIsVisiblyUnimplemented() {
        let table = ContentParser.parse(html: "<table><tbody><tr><td>x</td></tr></tbody></table>")
        guard case .unimplemented = table.blocks[0] else {
            Issue.record("expected unimplemented block for table")
            return
        }

        let widget = ContentParser.parse(html: #"<p>before <marquee>zap</marquee></p>"#)
        guard case .paragraph(let inlines) = widget.blocks[0],
              case .unimplemented = inlines[1] else {
            Issue.record("expected unimplemented inline")
            return
        }
    }

    @Test func searchMatchHighlight() {
        let content = ContentParser.parse(
            html: #"<p>I tested this on <span class="highlight">Android</span> today</p>"#)
        #expect(content.blocks == [
            .paragraph([
                .text("I tested this on "),
                .highlight([.text("Android")]),
                .text(" today"),
            ])
        ])
        #expect(content.plainText == "I tested this on Android today")
    }

    @Test func plainTextFlattening() {
        let content = ContentParser.parse(
            html: #"<p>look <strong>at</strong> <span class="emoji emoji-263a" title="s">:s:</span></p><div class="codehilite"><pre><code>x = 1</code></pre></div>"#)
        #expect(content.plainText == "look at \u{263a} x = 1")
    }

    @Test func malformedHTMLDoesNotCrash() {
        let content = ContentParser.parse(html: "<p>unclosed <strong>tags")
        #expect(!content.blocks.isEmpty)
    }
}
