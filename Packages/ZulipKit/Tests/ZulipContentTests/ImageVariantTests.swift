import Testing
@testable import ZulipContent

/// Real-world `message_inline_image` shapes (mirrors zulip-flutter's
/// fixtures): thumbnailed, HEIC-transcoded, animated, the transient
/// loading placeholder, pre-thumbnailing raw markup, and wrapper variants.
struct ImageVariantTests {
    private func imageNode(_ html: String) -> ImageNode? {
        let parsed = ContentParser.parse(html: html)
        for block in parsed.blocks {
            if case .image(let node) = block { return node }
        }
        return nil
    }

    @Test func thumbnailedImage() throws {
        let node = try #require(imageNode(
            #"<div class="message_inline_image"><a href="/user_uploads/2/ce/x/image.jpg" title="image.jpg"><img data-original-dimensions="6000x4000" src="/user_uploads/thumbnail/2/ce/x/image.jpg/840x560.webp"></a></div>"#))
        #expect(node.src.hasSuffix("840x560.webp"))
        #expect(node.originalSrc == "/user_uploads/2/ce/x/image.jpg")
        #expect(node.originalWidth == 6000)
    }

    @Test func heicWithTranscodedThumbnail() throws {
        let node = try #require(imageNode(
            #"<div class="message_inline_image"><a href="/user_uploads/2/ce/x/IMG_1.HEIC" title="IMG_1.HEIC"><img data-original-content-type="image/heic" data-original-dimensions="4032x3024" data-transcoded-image="840x630.webp" loading="lazy" src="/user_uploads/thumbnail/2/ce/x/IMG_1.HEIC/840x630.webp"></a></div>"#))
        #expect(node.originalSrc == "/user_uploads/2/ce/x/IMG_1.HEIC")
    }

    @Test func heicRawPreThumbnailMarkup() throws {
        let node = try #require(imageNode(
            #"<div class="message_inline_image"><a href="/user_uploads/2/ab/IMG_2.heic" title="IMG_2.heic"><img src="/user_uploads/2/ab/IMG_2.heic"></a></div>"#))
        #expect(node.src == "/user_uploads/2/ab/IMG_2.heic")
    }

    @Test func animatedImage() throws {
        let node = try #require(imageNode(
            #"<div class="message_inline_image"><a href="/user_uploads/2/9f/x/a.gif" title="a.gif"><img data-animated="true" data-original-content-type="image/gif" data-original-dimensions="64x64" src="/user_uploads/thumbnail/2/9f/x/a.gif/840x560-anim.webp"></a></div>"#))
        #expect(node.src.hasSuffix("-anim.webp"))
    }

    @Test func loadingPlaceholderParses() throws {
        // Transient state while the server transcodes; the renderer skips
        // the SVG loader and fetches the original instead.
        let node = try #require(imageNode(
            #"<div class="message_inline_image"><a href="/user_uploads/path/to/example.png" title="example.png"><img class="image-loading-placeholder" data-original-dimensions="1920x1080" data-original-content-type="image/png" src="/static/images/loading/loader-black.svg"></a></div>"#))
        #expect(node.src.hasPrefix("/static/images/loading"))
        #expect(node.originalSrc == "/user_uploads/path/to/example.png")
    }

    @Test func newStyleBareInlineImage() throws {
        // Zulip 11+: no wrapper div — a bare img.inline-image (verbatim from
        // a live realm via the unimplemented-content log).
        let node = try #require(imageNode(
            #"<img alt="20260618_143517.png" class="inline-image" data-original-content-type="image/png" data-original-dimensions="1484x1181" data-original-src="/user_uploads/3/5c/7iRGCHJOctbToCJNsICNx10H/20260618_143517.png" src="/user_uploads/thumbnail/3/5c/7iRGCHJOctbToCJNsICNx10H/20260618_143517.png/840x560.webp" />"#))
        #expect(node.src.hasSuffix("840x560.webp"))
        #expect(node.originalSrc == "/user_uploads/3/5c/7iRGCHJOctbToCJNsICNx10H/20260618_143517.png")
        #expect(node.originalWidth == 1484)
        #expect(node.originalHeight == 1181)
        #expect(node.alt == "20260618_143517.png")
    }

    @Test func inlineImageHoistsOutOfParagraph() {
        let parsed = ContentParser.parse(html:
            #"<p>before <img class="inline-image" data-original-src="/user_uploads/a.png" src="/thumb/a.webp"> after</p>"#)
        guard parsed.blocks.count == 3,
              case .paragraph = parsed.blocks[0],
              case .image(let image) = parsed.blocks[1],
              case .paragraph = parsed.blocks[2]
        else {
            Issue.record("expected paragraph/image/paragraph, got \(parsed.blocks)")
            return
        }
        #expect(image.originalSrc == "/user_uploads/a.png")
    }

    @Test func consecutiveInlineImagesFormGallery() {
        let parsed = ContentParser.parse(html:
            #"<p><img class="inline-image" src="/thumb/a.webp"><img class="inline-image" src="/thumb/b.webp"></p>"#)
        guard case .imageGallery(let images) = parsed.blocks.first else {
            Issue.record("expected gallery, got \(parsed.blocks)")
            return
        }
        #expect(images.count == 2)
    }

    @Test func wrapperVariantsStillParse() throws {
        // Anchor not the first child; img nested below the anchor.
        let node = try #require(imageNode(
            #"<div class="message_inline_image"><span></span><a href="/user_uploads/x.png"><span><img src="/thumb/x.webp"></span></a></div>"#))
        #expect(node.src == "/thumb/x.webp")
        #expect(node.originalSrc == "/user_uploads/x.png")
    }
}
