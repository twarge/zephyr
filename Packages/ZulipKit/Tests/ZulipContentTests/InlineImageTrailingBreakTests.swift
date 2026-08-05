import Testing
@testable import ZulipContent

/// Trailing <br> in an image paragraph must not survive as a break-only
/// paragraph — it rendered as a phantom empty line below the image.
@Suite struct InlineImageTrailingBreakTests {
    private let img = #"<img alt="a.png" class="inline-image" data-original-dimensions="3024x4032" data-original-src="/user_uploads/a.png" src="/user_uploads/thumbnail/a.png/840x560.webp">"#

    private func kinds(_ html: String) -> [String] {
        ContentParser.parse(html: html).blocks.map { block in
            switch block {
            case .paragraph: "paragraph"
            case .image: "image"
            default: "other"
            }
        }
    }

    @Test func trailingBreakAfterImageIsDropped() {
        #expect(kinds("<p>\(img)<br></p>") == ["image"])
        #expect(kinds("<p>\(img)<br><br></p>") == ["image"])
    }

    @Test func captionAndInteriorBreaksSurvive() {
        #expect(kinds("<p>Digikey<br>\(img)</p>") == ["paragraph", "image"])
        // Interior breaks between text runs are content, not noise.
        let parsed = ContentParser.parse(html: "<p>one<br>two</p>").blocks
        guard case .paragraph(let inlines) = parsed.first else {
            Issue.record("expected paragraph")
            return
        }
        #expect(inlines.contains { if case .lineBreak = $0 { true } else { false } })
    }
}
