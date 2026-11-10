import SwiftUI
import ZulipModel

/// A recipient bar in the web app's style: full-width, tinted with the
/// channel's color, leading colored channel glyph.
struct ConversationHeaderRow: View {
    let store: PerAccountStore
    let conversationKey: ConversationKey
    let includeChannel: Bool
    let onTap: ((ConversationKey) -> Void)?

    @Environment(KeyboardRouter.self) private var keys: KeyboardRouter?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showLinks = false

    private var streamId: Int? {
        if case .topic(let id, _) = conversationKey { return id }
        return nil
    }

    private var channelColor: Color {
        guard let streamId else { return .gray }
        return store.subscriptions[streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: streamId)
    }

    private var glyph: String {
        guard let streamId else { return "person.fill" }
        let stream = store.channels[streamId]
        if stream?.inviteOnly == true { return "lock.fill" }
        if stream?.isWebPublic == true { return "globe" }
        return "number"
    }

    private var isResolved: Bool {
        if case .topic(_, let topic) = conversationKey {
            return TopicName.isResolved(topic)
        }
        return false
    }

    private var label: String {
        switch conversationKey {
        case .topic(let streamId, let topic):
            let display = TopicName.displayName(topic).isEmpty
                ? "general chat" : TopicName.displayName(topic)
            guard includeChannel else { return display }
            let channel = store.channels[streamId]?.name
                ?? store.subscriptions[streamId]?.name ?? "?"
            return "\(channel) › \(display)"
        case .dm:
            return conversationKey.displayTitle(in: store)
        }
    }

    var body: some View {
        Button {
            onTap?(conversationKey)
        } label: {
            HStack(spacing: 7) {
                // The # (or lock/globe) marks the channel — shown only when
                // the channel is part of the label. A topic-only header in
                // a channel feed shouldn't wear a channel glyph.
                if includeChannel || streamId == nil {
                    Image(systemName: glyph)
                        .font(.body.weight(.bold))
                        .foregroundStyle(
                            streamId == nil
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(channelColor))
                }
                if isResolved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
                Text(label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                streamId == nil
                    ? AnyShapeStyle(.quaternary.opacity(0.45))
                    : AnyShapeStyle(channelColor.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 6))
            // Opaque under the translucent tint so rows don't ghost through
            // a pinned header — clipped to the pill, so the top padding and
            // the corners stay clear and scrolled rows show around it.
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help("Open this conversation")
        .contextMenu {
            switch conversationKey {
            case .topic(let streamId, let topic):
                topicMenu(streamId: streamId, topic: topic)
            case .dm:
                Button("Mark as Read") {
                    store.markConversationRead(conversationKey)
                }
                Button("Copy Link to Conversation", systemImage: "link") {
                    Platform.copyToPasteboard(conversationKey.link(in: store))
                }
            }
        }
        .alert("Rename Topic", isPresented: $showRename) {
            TextField("Topic", text: $renameText)
            Button("Rename") {
                if case .topic(let streamId, let topic) = conversationKey {
                    store.renameTopic(streamId: streamId, topic: topic, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every message in the topic moves to the new name.")
        }
        .sheet(isPresented: $showLinks) {
            if case .topic(let streamId, let topic) = conversationKey {
                TopicLinksSheet(store: store, streamId: streamId, topic: topic)
            }
        }
    }

    @ViewBuilder
    private func topicMenu(streamId: Int, topic: String) -> some View {
        let visibility = store.topicVisibility(streamId: streamId, topic: topic)
        Button(visibility == .muted ? "Unmute Topic" : "Mute Topic") {
            store.setTopicVisibility(
                streamId: streamId, topic: topic,
                policy: visibility == .muted ? .none : .muted)
        }
        Button(visibility == .followed ? "Unfollow Topic" : "Follow Topic") {
            store.setTopicVisibility(
                streamId: streamId, topic: topic,
                policy: visibility == .followed ? .none : .followed)
        }
        Button(
            isResolved ? "Unresolve Topic" : "Resolve Topic",
            systemImage: isResolved ? "checkmark.circle.badge.xmark" : "checkmark.circle"
        ) {
            store.setTopicResolved(streamId: streamId, topic: topic, resolved: !isResolved)
        }
        Button("Rename Topic…") {
            renameText = TopicName.displayName(topic)
            showRename = true
        }
        Divider()
        Button("Mark Topic as Read") {
            store.markConversationRead(conversationKey)
        }
        Button("Mark All as Unread") {
            keys?.readMarkingPaused = true
            store.markConversationUnread(conversationKey)
        }
        // Offered only when something links to or from the topic, as the
        // web app does.
        if store.topicLinks.hasLinks(streamId: streamId, topic: topic) {
            Button("View Links…", systemImage: "arrow.left.arrow.right") {
                showLinks = true
            }
        }
        Button("Copy Link to Topic", systemImage: "link") {
            Platform.copyToPasteboard(conversationKey.link(in: store))
        }
        Button("Copy Topic Reference", systemImage: "number") {
            Platform.copyToPasteboard(conversationKey.reference(in: store))
        }
        if includeChannel {
            Divider()
            Button("Open Channel") {
                keys?.navigate?(.channel(streamId: streamId))
            }
        }
    }
}
