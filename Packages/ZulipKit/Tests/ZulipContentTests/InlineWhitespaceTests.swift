import Testing
@testable import ZulipContent

/// Whitespace-only text between inline siblings outside a `<p>` (tight list
/// items, spoiler headers) separates them; between blocks it's noise.
struct InlineWhitespaceTests {
    @Test func tightListItemKeepsSpaceBetweenInlines() {
        let content = ContentParser.parse(
            html: "<ul>\n<li><strong>a</strong> <em>b</em></li>\n</ul>")
        #expect(content.blocks == [
            .unorderedList(items: [
                [.paragraph([.strong([.text("a")]), .text(" "), .emphasis([.text("b")])])]
            ])
        ])
    }

    @Test func adjacentMentionsStaySeparated() {
        let content = ContentParser.parse(
            html: #"<ol><li><span class="user-mention" data-user-id="1">@Al</span> <span class="user-mention" data-user-id="2">@Bo</span></li></ol>"#)
        #expect(content.plainText == "@Al @Bo")
    }

    @Test func spoilerHeaderWithoutParagraphKeepsSpace() {
        let content = ContentParser.parse(
            html: #"<div class="spoiler-block"><div class="spoiler-header"><strong>a</strong> <em>b</em></div><div class="spoiler-content"><p>x</p></div></div>"#)
        #expect(content.blocks == [
            .spoiler(
                header: [.strong([.text("a")]), .text(" "), .emphasis([.text("b")])],
                content: [.paragraph([.text("x")])])
        ])
    }

    @Test func whitespaceBetweenBlocksMakesNoParagraph() {
        let content = ContentParser.parse(
            html: "\n<p>one</p>\n \n<p>two</p>\n<ul>\n<li>\n<p>loose</p>\n</li>\n</ul>\n")
        #expect(content.blocks == [
            .paragraph([.text("one")]),
            .paragraph([.text("two")]),
            .unorderedList(items: [[.paragraph([.text("loose")])]]),
        ])
    }

    @Test func edgeWhitespaceAroundInlinesIsTrimmed() {
        let content = ContentParser.parse(html: "<ul><li> <strong>a</strong> </li></ul>")
        #expect(content.blocks == [.unorderedList(items: [[.paragraph([.strong([.text("a")])])]])])
    }

    @Test func nodesAreHashable() {
        let a = ContentParser.parse(html: "<p>hi <strong>there</strong></p>")
        let b = ContentParser.parse(html: "<p>hi <strong>there</strong></p>")
        #expect(Set(a.blocks).count == 1)
        #expect(a.hashValue == b.hashValue)
    }
}
