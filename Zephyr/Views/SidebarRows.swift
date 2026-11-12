#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import TipKit
import ZulipAPI
import ZulipContent
import ZulipModel

/// A section header whose + button stays invisible until the pointer
/// approaches — matching the hover-revealed disclosure triangle beside it.
/// (Touch platforms keep it visible; there's nothing to hover.)
struct SectionHeaderWithAdd: View {
    let title: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: action) {
                // Filled variant: solid disc with a knocked-out plus.
                Image(systemName: "plus.circle.fill")
                    #if !os(macOS)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
                    #endif
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
            #if os(macOS)
            // Nudged in from the overlay scroller; invisible until hover.
            .padding(.trailing, 8)
            .opacity(hovering ? 1 : 0)
            #endif
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// A Recent Searches row with a hover-revealed remove button.
struct RecentSearchRow: View {
    let query: SearchQuery
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(query.displayDescription)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "magnifyingglass")
                    .sidebarIcon()
            }
            Spacer(minLength: 4)
            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from Recent Searches")
            }
        }
        .onHover { isHovering = $0 }
    }
}

/// Compact one-line DM row: presence dot (placeholder until M2), name(s),
/// bot marker, unread badge.
/// An unsent draft: conversation title over a one-line text snippet.
struct DraftRow: View {
    let store: PerAccountStore
    let conversationKey: ConversationKey
    let text: String

    private var title: String {
        if case .topic(let streamId, let topic) = conversationKey {
            let channel = store.channels[streamId]?.name
                ?? store.subscriptions[streamId]?.name ?? "?"
            let display = TopicName.displayName(topic)
            return "#\(channel) › \(display.isEmpty ? "general chat" : display)"
        }
        return conversationKey.displayTitle(in: store)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: "pencil.line")
                    .sidebarIcon(.gray)
            }
            Spacer(minLength: 0)
        }
        .sidebarRowPadding()
    }
}

/// The sidebar's activity footer while a "mark all messages as read"
/// sweep runs (Mail-style): spinner and running count batch by batch,
/// then the total — or a failure — lingering briefly.
struct MarkReadStatusFooter: View {
    let sweep: PerAccountStore.MarkReadSweep

    var body: some View {
        HStack(spacing: 6) {
            switch sweep {
            case .running:
                ProgressView()
                    .controlSize(.mini)
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .dimsWhenWindowInactive()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .dimsWhenWindowInactive()
            }
            Text(label)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var label: String {
        switch sweep {
        case .running(let count):
            count > 0
                ? "Marking messages as read… \(count.formatted())"
                : "Marking messages as read…"
        case .finished(let count):
            count == 1
                ? "Marked 1 message as read"
                : "Marked \(count.formatted()) messages as read"
        case .failed:
            "Couldn't mark messages as read"
        }
    }
}

/// A quiet disclosure row ("More conversations…", "Inactive channels…").
struct SidebarExpanderRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: "ellipsis.circle")
                        .sidebarIcon(.gray)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sidebarRowPadding()
    }
}

/// A search suggestion as a list row (macOS): a token to commit, or the
/// free-text search itself. Rows rather than the field's suggestion menu,
/// so the sidebar stays clickable while suggestions show.
struct SearchSuggestionRow: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label {
                    Text(title)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: icon)
                        .sidebarIcon()
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sidebarRowPadding()
    }
}

/// A user with no conversation yet: same shape as `DirectMessageRow`, name
/// dimmed until there's history.
struct UserDirectMessageRow: View {
    let store: PerAccountStore
    let user: User

    private var title: String {
        user.userId == store.selfUserId ? "Yourself" : user.fullName
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } icon: {
                PresenceDot(state: store.presenceState(of: user.userId))
            }
            Spacer(minLength: 4)
        }
        .sidebarRowPadding()
    }
}

struct DirectMessageRow: View {
    let store: PerAccountStore
    let conversation: ConversationList.Conversation

    private var participantIds: [Int] {
        conversation.key.dmParticipantIds ?? []
    }

    private var isBot: Bool {
        participantIds.count == 1 && store.users[participantIds[0]]?.isBot == true
    }

    private var unreadCount: Int {
        store.unreads.unreadIds[conversation.key]?.count ?? 0
    }

    private var hasMention: Bool {
        guard let ids = store.unreads.unreadIds[conversation.key] else { return false }
        return !ids.isDisjoint(with: store.unreads.mentionIds)
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(conversation.key.displayTitle(in: store))
                    .fontWeight(unreadCount > 0 ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                PresenceDot(state: store.presenceState(of: participantIds.first ?? 0))
            }
            Spacer(minLength: 4)
            // Bot marker joins the trailing icon stack, like channel locks.
            if isBot {
                Image(systemName: "cpu")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .help("Bot")
            }
            if hasMention {
                Text("@")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(.tint, in: .circle)
                    .dimsWhenWindowInactive()
            } else if unreadCount > 0 {
                CountBadge(count: unreadCount)
            }
        }
        .sidebarRowPadding()
    }
}

/// Sidebar state icons (muted bell, lock, followed, resolved): ~50%
/// larger than the caption2 they debuted at.
private var stateIconFont: Font {
    #if os(macOS)
    .system(size: 15)
    #else
    .callout
    #endif
}

/// The far-trailing column shared by a channel's disclosure chevron and
/// its topics' followed icon, so the two stack on one centerline (and the
/// unread counts beside them line up too).
private enum TrailingColumn {
    #if os(macOS)
    static let width: CGFloat = 26
    /// Clear of the overlay scroller, which wins clicks while visible.
    static let inset: CGFloat = 8
    #else
    static let width: CGFloat = 44
    static let inset: CGFloat = 0
    #endif
}

/// Web-style channel row: disclosure triangle for inline topics, colored
/// type glyph (globe/lock/#), name, badge.
struct ChannelRow: View {
    let store: PerAccountStore
    let subscription: Subscription
    var isExpanded = false
    var onToggle: (() -> Void)?

    private var unreadCount: Int {
        store.unreads.unreadCount(inChannel: subscription.streamId)
    }

    private var channelColor: Color {
        subscription.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: subscription.streamId)
    }

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(subscription.name)
                    .fontWeight(unreadCount > 0 && !subscription.muted ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "number")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(channelColor)
                    .dimsWhenWindowInactive()
            }
            Spacer(minLength: 4)
            // Trailing stack: state icons, badge, then the disclosure at
            // the far right.
            if subscription.muted {
                Image(systemName: "bell.slash.fill")
                    .font(stateIconFont)
                    .foregroundStyle(.tertiary)
                    .help("Muted channel")
            }
            if store.channels[subscription.streamId]?.inviteOnly == true {
                Image(systemName: "lock.fill")
                    .font(stateIconFont)
                    .foregroundStyle(.secondary)
                    .help("Private channel")
            }
            if unreadCount > 0 && !subscription.muted {
                CountBadge(count: unreadCount)
            }
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        // macOS: compact, nudged in from the overlay
                        // scroller (which wins clicks while visible).
                        // iOS: the system sidebar chevron's size and shade,
                        // in a wide tap target kept row-height-neutral —
                        // a 44pt-tall frame inflated every channel row.
                        #if os(macOS)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: TrailingColumn.width, height: 26)
                        .padding(.trailing, TrailingColumn.inset)
                        #else
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: TrailingColumn.width, height: 28)
                        #endif
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide topics" : "Show topics")
            }
        }
        .opacity(subscription.muted ? 0.6 : 1)
        .sidebarRowPadding()
    }
}

/// The topic thread rail, one segment per row in the Label icon column —
/// the same column as the channel's # icon, so alignment is the system's.
/// `.through` rows get a full tick, `.cap` ends the list with an L-shaped
/// foot pointing at the final topic, `.dotted` fades out at "All topics…".
enum TopicRailKind: Equatable {
    case through
    case cap
    case dotted
}

struct TopicRailTick: View {
    let color: Color
    let kind: TopicRailKind

    var body: some View {
        Group {
            switch kind {
            case .through:
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 24)
            case .cap:
                // └ — the foot overflows the 2pt frame to the right so the
                // vertical bar stays exactly on the rail line above it.
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(color)
                        .frame(width: 2, height: 14)
                    Capsule()
                        .fill(color)
                        .frame(width: 8, height: 2)
                        .offset(y: 12)
                }
                .frame(width: 2, height: 24, alignment: .topLeading)
            case .dotted:
                VStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        Capsule()
                            .fill(color)
                            .frame(width: 2, height: 3)
                    }
                }
            }
        }
        .dimsWhenWindowInactive()
    }
}

/// An indented topic row under an expanded channel.
struct SidebarTopicRow: View {
    let store: PerAccountStore
    let streamId: Int
    let topic: ChannelTopic
    /// The thread-rail tick beside this row.
    var rail: TopicRailKind?
    /// Called after a rename is submitted, so the sidebar can refresh its
    /// topic cache once the server has applied the move.
    var onRenamed: (() -> Void)?

    @State private var showRename = false
    @State private var renameText = ""
    @State private var showMove = false
    @State private var showLinks = false

    /// macOS's sidebar runs smaller than body; iOS keeps every row
    /// body-sized like Mail's.
    #if os(macOS)
    private static let topicFont = Font.callout
    #else
    private static let topicFont = Font.body
    #endif

    private var channelColor: Color {
        store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    private var key: ConversationKey {
        .topic(streamId: streamId, topic: topic.name)
    }

    private var unreadCount: Int {
        store.unreads.unreadIds[key]?.count ?? 0
    }

    private var hasMention: Bool {
        guard let ids = store.unreads.unreadIds[key] else { return false }
        return !ids.isDisjoint(with: store.unreads.mentionIds)
    }

    private var visibility: TopicVisibilityPolicy {
        store.topicVisibility(streamId: streamId, topic: topic.name)
    }

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(TopicName.displayName(topic.name).isEmpty
                    ? "general chat" : TopicName.displayName(topic.name))
                    .font(Self.topicFont.weight(unreadCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
            } icon: {
                if let rail {
                    TopicRailTick(color: channelColor, kind: rail)
                } else {
                    Color.clear.frame(width: 2)
                }
            }
            Spacer(minLength: 4)
            // State icons trail, like the channel lock.
            if TopicName.isResolved(topic.name) {
                Image(systemName: "checkmark.circle.fill")
                    .font(stateIconFont)
                    .foregroundStyle(.green)
                    .help("Resolved topic")
                    .dimsWhenWindowInactive()
            }
            if hasMention {
                Text("@")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(.tint, in: .circle)
                    .dimsWhenWindowInactive()
            } else if unreadCount > 0 {
                CountBadge(count: unreadCount)
            }
            // The followed icon sits under the channel's chevron; the
            // column is reserved either way so counts stay aligned. The
            // leading 2pt makes up this row's tighter HStack spacing.
            Group {
                if visibility == .followed {
                    Image(systemName: "plus.message")
                        .font(stateIconFont)
                        .foregroundStyle(.secondary)
                        .help("Followed topic — new messages notify you")
                        .popoverTip(TopicStateIconsTip())
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: TrailingColumn.width)
            .padding(.leading, 2)
            .padding(.trailing, TrailingColumn.inset)
        }
        .sidebarRowPadding()
        .opacity(visibility == .muted ? 0.5 : 1)
        .contextMenu {
            Button(visibility == .muted ? "Unmute Topic" : "Mute Topic") {
                store.setTopicVisibility(
                    streamId: streamId, topic: topic.name,
                    policy: visibility == .muted ? .none : .muted)
            }
            Button(visibility == .followed ? "Unfollow Topic" : "Follow Topic") {
                store.setTopicVisibility(
                    streamId: streamId, topic: topic.name,
                    policy: visibility == .followed ? .none : .followed)
            }
            Button("Rename Topic…") {
                renameText = TopicName.displayName(topic.name)
                showRename = true
            }
            Button("Move Topic…") {
                showMove = true
            }
            Divider()
            // Offered only when something links to or from the topic,
            // as the web app does.
            if store.topicLinks.hasLinks(streamId: streamId, topic: topic.name) {
                Button("View Links…") {
                    showLinks = true
                }
            }
            Button("Copy Link to Topic") {
                Platform.copyToPasteboard(key.link(in: store))
            }
            // #**channel>topic**: pasted into a message, a link.
            Button("Copy Topic Reference") {
                Platform.copyToPasteboard(key.reference(in: store))
            }
        }
        .alert("Rename Topic", isPresented: $showRename) {
            TextField("Topic", text: $renameText)
            Button("Rename") { renameTopic() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message in the topic moves to the new name.")
        }
        .sheet(isPresented: $showMove) {
            MoveTopicSheet(
                store: store,
                subject: .topic(streamId: streamId, name: topic.name, maxId: topic.maxId),
                onMoved: { onRenamed?() })
        }
        .sheet(isPresented: $showLinks) {
            TopicLinksSheet(store: store, streamId: streamId, topic: topic.name)
        }
    }

    /// Rename = move the whole topic, anchored at its newest message. A
    /// resolved topic stays resolved under its new name.
    private func renameTopic() {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != TopicName.displayName(topic.name) else { return }
        let newName = TopicName.isResolved(topic.name)
            ? TopicName.resolvedPrefix + trimmed : trimmed
        store.moveMessage(topic.maxId, toTopic: newName, propagateMode: "change_all")
        onRenamed?()
    }
}

private extension View {
    /// A hair of macOS row breathing room; iOS keeps the system's
    /// native row metrics untouched.
    @ViewBuilder
    func sidebarRowPadding() -> some View {
        #if os(macOS)
        padding(.vertical, 1)
        #else
        self
        #endif
    }
}

/// Sidebar row clicks. Double-click opens the entry standalone in a new
/// window. On macOS 26 that recognizer swallows a single click landing on
/// the row's label, icon, or badge — the List only sees clicks that miss
/// it, on the trailing Spacer — so a one-click gesture selects the row
/// itself. macOS 27 forwards the click to the List; the fallback stays off.
struct SidebarRowClicks: ViewModifier {
    let destination: Destination
    @Binding var selection: Destination?
    let detach: () -> Void

    /// macOS 26 and earlier. iOS delivers the tap to the List regardless.
    private static let clickSelects: Bool = {
        if #available(macOS 27, *) { return false }
        return true
    }()

    @ViewBuilder
    func body(content: Content) -> some View {
        let detachable = content
            .simultaneousGesture(TapGesture(count: 2).onEnded { detach() })
        if Self.clickSelects {
            // Low priority: a click on a control inside the row (the
            // channel's disclosure chevron) stays with the control
            // instead of also selecting the row.
            detachable.gesture(TapGesture().onEnded { selection = destination })
        } else {
            detachable
        }
    }
}
