import Foundation

extension MessageContent {
    /// Personal, notifying mentions. Broadcasts, group mentions, quoted
    /// mentions and silent references do not ask this individual to respond.
    public func mentions(userId: Int) -> Bool {
        blocks.contains { $0.mentions(userId: userId) }
    }
}

extension BlockNode {
    fileprivate func mentions(userId: Int) -> Bool {
        switch self {
        case .paragraph(let nodes), .heading(_, let nodes):
            nodes.contains { $0.mentions(userId: userId) }
        case .unorderedList(let items), .orderedList(_, let items):
            items.joined().contains { $0.mentions(userId: userId) }
        case .spoiler(let header, let content), .collapsible(let header, let content):
            header.contains { $0.mentions(userId: userId) }
                || content.contains { $0.mentions(userId: userId) }
        case .table(let table):
            (table.headerCells + table.rows.flatMap { $0 }).joined()
                .contains { $0.mentions(userId: userId) }
        default:
            false
        }
    }
}

extension InlineNode {
    fileprivate func mentions(userId: Int) -> Bool {
        switch self {
        case .mention(let mention):
            !mention.silent && mention.target == .user(id: userId)
        case .strong(let nodes), .emphasis(let nodes), .strikethrough(let nodes),
             .highlight(let nodes):
            nodes.contains { $0.mentions(userId: userId) }
        case .link(let link):
            link.text.contains { $0.mentions(userId: userId) }
        default:
            false
        }
    }
}
