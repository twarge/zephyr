import SwiftUI
import ZulipAPI
import ZulipModel

/// Hugs its content's ideal width up to `maxWidth`, wrapping beyond it.
/// Overlays propose the base view's size, which defeats the usual
/// frame(maxWidth:)/fixedSize combinations — a hover card anchored to a
/// small pill needs its own sizing.
private struct CappedWidthLayout: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(.unspecified)
        if ideal.width <= maxWidth { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

struct ReactionsRow: View {
    let store: PerAccountStore
    let message: Message

    /// Each emoji reacted with, once, in first-reaction order.
    static func distinctEmojiNames(_ reactions: [Reaction]) -> [String] {
        var seen: Set<String> = []
        return reactions.map(\.emojiName).filter { seen.insert($0).inserted }
    }

    private var reactions: [Reaction] { message.reactions }

    private struct Group: Identifiable {
        var id: String
        var sample: Reaction
        var count: Int
        var reactedBySelf: Bool
        var userIds: [Int]
    }

    private var groups: [Group] {
        var byEmoji: [String: Group] = [:]
        var order: [String] = []
        for reaction in reactions {
            let key = "\(reaction.reactionType):\(reaction.emojiCode)"
            if byEmoji[key] == nil {
                byEmoji[key] = Group(
                    id: key, sample: reaction, count: 0, reactedBySelf: false, userIds: [])
                order.append(key)
            }
            byEmoji[key]?.count += 1
            byEmoji[key]?.userIds.append(reaction.userId)
            if reaction.userId == store.selfUserId {
                byEmoji[key]?.reactedBySelf = true
            }
        }
        return order.compactMap { byEmoji[$0] }.sorted { $0.count > $1.count }
    }

    /// "Steven Nguyen, You" — the hover card; self listed last as "You",
    /// long lists capped ("…, 14 others").
    private func reactorNames(_ group: Group) -> String {
        var names = group.userIds
            .filter { $0 != store.selfUserId }
            .map { store.users[$0]?.fullName ?? "Someone" }
        if group.reactedBySelf {
            names.append("You")
        }
        if names.count > 12 {
            let extra = names.count - 11
            names = Array(names.prefix(11)) + ["\(extra) others"]
        }
        return names.joined(separator: ", ")
    }

    /// The pill whose reactor card is showing (pointer rested on it for a
    /// beat; macOS and iPad-trackpad hover).
    @State private var hoverCardGroupId: String?
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(groups) { group in
                Button {
                    store.toggleReaction(
                        message: message,
                        emojiName: group.sample.emojiName,
                        emojiCode: group.sample.emojiCode,
                        reactionType: group.sample.reactionType)
                } label: {
                    HStack(spacing: 4) {
                        emojiView(group.sample)
                            .font(.system(size: 16))
                        if group.count > 1 {
                            Text("\(group.count)")
                                .font(.caption)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        group.reactedBySelf ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                        in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(reactorNames(group)) reacted with \(group.sample.emojiName)")
                // Immediate who-reacted card (the system tooltip's 1.5s
                // delay made it feel absent): a real popover after a short
                // rest — window-backed, so the message view can't clip it,
                // and the system flips it below when there's no room above.
                .popover(
                    isPresented: Binding(
                        get: { hoverCardGroupId == group.id },
                        set: { if !$0 { hoverCardGroupId = nil } }),
                    arrowEdge: .top
                ) {
                    reactorCard(group)
                        .presentationCompactAdaptation(.popover)
                }
                .onHover { inside in
                    hoverTask?.cancel()
                    if inside {
                        hoverTask = Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            hoverCardGroupId = group.id
                        }
                    } else if hoverCardGroupId == group.id {
                        hoverCardGroupId = nil
                    }
                }
            }
            // No trailing "+" pill: adding lives in the hover controls
            // (and the context menu), keeping the row to actual reactions.
        }
        .padding(.top, 1)
    }

    private func reactorCard(_ group: Group) -> some View {
        // The popover supplies its own chrome; the layout caps the width
        // (popovers propose ideal size, which would put a long reactor
        // list on one very wide line).
        CappedWidthLayout(maxWidth: 240) {
            VStack(alignment: .leading, spacing: 2) {
                Text(reactorNames(group))
                    .font(.caption.weight(.medium))
                Text(":\(group.sample.emojiName):")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func emojiView(_ reaction: Reaction) -> some View {
        if reaction.reactionType == "unicode_emoji",
           let character = emojiCharacter(fromCodes: reaction.emojiCode) {
            Text(character)
        } else if let src = store.realmEmoji[reaction.emojiCode]?.sourceUrl,
                  let image = EmojiImageLoader.shared.image(src: src, connection: store.connection) {
            Image(platform: image)
        } else {
            Text(":\(reaction.emojiName):")
        }
    }
}
