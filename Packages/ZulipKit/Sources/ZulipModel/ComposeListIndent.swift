import Foundation

/// ⌘] / ⌘[ in compose: indent or outdent the list items a selection
/// touches, as the Zulip web compose box does it (13.0's Ctrl+] / Ctrl+[,
/// `compose_ui.handle_list_indent`).
///
/// A list item is a line whose first non-blank text is a bullet ("- ",
/// "* ", "+ ") or a number ("1. "). One step is two spaces, the nesting
/// Zulip's markdown reads. Indent prefixes two spaces; outdent strips two
/// leading spaces (one, if that's all there is) and leaves an item at the
/// margin where it is. Every list item on the touched lines moves; the
/// other lines among them stay put, and numbers stay as typed.
///
/// One departure from the web: a selection that ends at the very start of
/// a line leaves that line out (the web takes it too), so a triple-clicked
/// item — newline and all — moves alone.
public enum ComposeListIndent {
    public struct Edit: Equatable, Sendable {
        public var text: String
        /// The selection carried through the edit, in `text`: it moves
        /// with the text around it, so the caret keeps its place in the item.
        public var selection: Range<String.Index>
    }

    /// nil when the selection touches no list item: the keys aren't the
    /// list's there. An item that can't outdent further still gets an
    /// edit, with the text unchanged — on the web the keys belong to the
    /// list either way.
    public static func edit(
        _ text: String, selection: Range<String.Index>, increase: Bool
    ) -> Edit? {
        let blockStart = text[..<selection.lowerBound]
            .lastIndex(where: isLineBreak).map { text.index(after: $0) } ?? text.startIndex
        var last = selection.upperBound
        if !selection.isEmpty, last > blockStart,
           isLineBreak(text[text.index(before: last)]) {
            last = text.index(before: last)
        }
        let blockEnd = text[last...].firstIndex(where: isLineBreak) ?? text.endIndex

        // The touched lines' starts, and how many spaces each gains (+2)
        // or loses.
        var changes: [(start: String.Index, delta: Int)] = []
        var isList = false
        var lineStart = blockStart
        while true {
            let lineEnd = text[lineStart..<blockEnd].firstIndex(where: isLineBreak) ?? blockEnd
            let line = text[lineStart..<lineEnd]
            if isListItem(line) {
                isList = true
                if increase {
                    changes.append((lineStart, 2))
                } else if line.hasPrefix(" ") {
                    changes.append((lineStart, line.hasPrefix("  ") ? -2 : -1))
                }
            }
            guard lineEnd < blockEnd else { break }
            lineStart = text.index(after: lineEnd)
        }
        guard isList else { return nil }

        var result = ""
        result.reserveCapacity(text.utf8.count + 2 * changes.count)
        var cursor = text.startIndex
        for change in changes {
            result += text[cursor..<change.start]
            if change.delta > 0 {
                result += "  "
                cursor = change.start
            } else {
                cursor = text.index(change.start, offsetBy: -change.delta)
            }
        }
        result += text[cursor...]

        // Selection ends move by what was inserted or removed before them
        // (counted in UTF-16, where each space is one unit). One sitting at
        // a line's start rides past the spaces indent puts there; one
        // inside the spaces outdent removes lands at the line's start.
        let offsets = changes.map { (start: $0.start.utf16Offset(in: text), delta: $0.delta) }
        func carried(_ index: String.Index) -> String.Index {
            let old = index.utf16Offset(in: text)
            var new = old
            for change in offsets where change.start <= old {
                new += change.delta > 0 ? change.delta : -min(-change.delta, old - change.start)
            }
            return String.Index(utf16Offset: new, in: result)
        }
        let lower = carried(selection.lowerBound)
        let upper = max(lower, carried(selection.upperBound))
        return Edit(text: result, selection: lower..<upper)
    }

    /// "- ", "* ", "+ " or digits and ". ", after any indentation.
    static func isListItem(_ line: Substring) -> Bool {
        let body = line.drop(while: \.isWhitespace)
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return true
        }
        let digits = body.prefix(while: { ("0"..."9").contains($0) })
        return !digits.isEmpty && body[digits.endIndex...].hasPrefix(". ")
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n"
    }
}
