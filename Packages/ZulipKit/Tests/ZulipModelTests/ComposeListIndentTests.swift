import Foundation
import Testing
@testable import ZulipModel

struct ComposeListIndentTests {
    /// The edit as plain values: the new text and its selection as
    /// character offsets.
    private func indent(
        _ text: String, _ from: Int, _ to: Int? = nil, increase: Bool = true
    ) -> (text: String, selection: ClosedRange<Int>)? {
        let lower = text.index(text.startIndex, offsetBy: from)
        let upper = text.index(text.startIndex, offsetBy: to ?? from)
        guard let edit = ComposeListIndent.edit(
            text, selection: lower..<upper, increase: increase)
        else { return nil }
        let start = edit.text.distance(from: edit.text.startIndex, to: edit.selection.lowerBound)
        let end = edit.text.distance(from: edit.text.startIndex, to: edit.selection.upperBound)
        return (edit.text, start...end)
    }

    // The web's own cases (web/tests/compose_ui.test.cjs).

    @Test func indentsTheItemAtTheCaret() throws {
        let result = try #require(indent("- Item 1\n- Item 2", 9))
        #expect(result.text == "- Item 1\n  - Item 2")
        #expect(result.selection == 11...11)
    }

    @Test func outdentsTheItemAtTheCaret() throws {
        let result = try #require(indent("- Item 1\n  - Item 2", 11, increase: false))
        #expect(result.text == "- Item 1\n- Item 2")
        #expect(result.selection == 9...9)
    }

    @Test func plainTextIsntTheList() {
        #expect(indent("Hello world", 5) == nil)
        #expect(indent("Hello world", 5, increase: false) == nil)
        #expect(indent("", 0) == nil)
    }

    @Test func anItemAtTheMarginKeepsTheKeys() throws {
        // Nothing to outdent, but the keys are still the list's.
        let result = try #require(indent("- Item 1", 3, increase: false))
        #expect(result.text == "- Item 1")
        #expect(result.selection == 3...3)
    }

    @Test func selectionMovesEveryItemItTouches() throws {
        let text = "- Item 1\n- Item 2\n- Item 3"
        let result = try #require(indent(text, 0, text.count))
        #expect(result.text == "  - Item 1\n  - Item 2\n  - Item 3")
        #expect(result.selection == 2...32)
    }

    @Test func numberedItemsIndentAndKeepTheirNumbers() throws {
        #expect(indent("1. Item 1", 0)?.text == "  1. Item 1")
        #expect(indent("1. a\n2. b\n3. c", 6)?.text == "1. a\n  2. b\n3. c")
        #expect(indent("12. twelve", 4)?.text == "  12. twelve")
    }

    // Beyond the web's tests.

    @Test func everyMarkerCounts() {
        for item in ["- a", "* a", "+ a", "1. a", "  - a", "\t* a", "- "] {
            #expect(indent(item, item.count) != nil, "\(item)")
        }
        for plain in ["-a", "*emphasis*", "**bold**", "1.5 apples", "1) a", "a. b", "---", "# h"] {
            #expect(indent(plain, plain.count) == nil, "\(plain)")
        }
    }

    @Test func plainLinesInASelectionStayPut() throws {
        let text = "- a\nplain\n* b"
        let result = try #require(indent(text, 0, text.count))
        #expect(result.text == "  - a\nplain\n  * b")
    }

    @Test func outdentTakesTwoSpacesOrOne() {
        #expect(indent("    - deep", 6, increase: false)?.text == "  - deep")
        #expect(indent(" - odd", 3, increase: false)?.text == "- odd")
        // A tab isn't spaces (the web leaves it too); the keys still belong
        // to the list.
        #expect(indent("\t- tabbed", 4, increase: false)?.text == "\t- tabbed")
    }

    @Test func caretInsideRemovedIndentationLandsAtTheLineStart() throws {
        let result = try #require(indent("x\n  - a", 3, increase: false))
        #expect(result.text == "x\n- a")
        #expect(result.selection == 2...2)
    }

    @Test func selectionEndingAtALineStartLeavesThatLine() throws {
        // A triple-clicked item: the selection runs through its newline.
        let result = try #require(indent("- a\n- b", 0, 4))
        #expect(result.text == "  - a\n- b")
        #expect(result.selection == 2...6)
    }

    @Test func caretOnTheLastLineStillCounts() throws {
        let result = try #require(indent("intro\n- a", 9))
        #expect(result.text == "intro\n  - a")
        #expect(result.selection == 11...11)
    }

    @Test func linesAroundTheSelectionAreUntouched() throws {
        let text = "- a\n- b\n- c"
        let result = try #require(indent(text, 5))
        #expect(result.text == "- a\n  - b\n- c")
    }

    @Test func windowsLineBreaksSplitLines() throws {
        let result = try #require(indent("- a\r\n- b", 7))
        #expect(result.text == "- a\r\n  - b")
    }

    @Test func emojiBeforeTheCaretKeepsItsPlace() throws {
        // Offsets are counted in UTF-16 inside; the caret must still land
        // after the same character.
        let result = try #require(indent("- 👍🏽 ok\n- b", 4))
        #expect(result.text == "  - 👍🏽 ok\n- b")
        #expect(result.selection == 6...6)
    }
}
