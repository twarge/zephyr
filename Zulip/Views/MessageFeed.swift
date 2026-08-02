import SwiftUI
import ZulipAPI
import ZulipModel

/// The scrolling message feed shared by topic/DM transcripts and the channel
/// feed. Flat, left-aligned, sender-grouped rows with day separators; the
/// channel feed additionally interleaves clickable topic headers.
///
/// Scroll behavior: the bottom-most visible row is tracked as the scroll
/// anchor, which keeps the viewport stable while older history prepends; the
/// anchor advances to new messages only when already at the bottom.
struct MessageFeedList: View {
    /// How conversation-run headers render: hidden (single-topic/DM
    /// transcripts), topic name only (a channel's own feed), or
    /// "#channel › topic" (cross-channel views like Mentions).
    enum HeaderMode {
        case hidden
        case topicOnly
        case channelAndTopic
    }

    let store: PerAccountStore
    let model: MessageListModel
    let cache: MessageContentCache
    var headerMode = HeaderMode.hidden
    var onHeaderTap: ((ConversationKey) -> Void)?
    var onNewMessages: (() -> Void)?

    @State private var anchorId: String?
    @State private var nearBottom = true

    private enum Item: Identifiable {
        case daySeparator(String)
        case conversationHeader(key: ConversationKey, firstMessageId: Int)
        case message(Message, showHeader: Bool)

        var id: String {
            switch self {
            case .daySeparator(let label): "day-\(label)"
            case .conversationHeader(_, let firstMessageId): "hdr-\(firstMessageId)"
            case .message(let message, _): "msg-\(message.id)"
            }
        }
    }

    /// Messages interleaved with day separators (and conversation headers in
    /// multi-conversation feeds); consecutive messages from the same sender
    /// within 5 minutes coalesce under one header.
    private var items: [Item] {
        var out: [Item] = []
        var lastDay: DateComponents?
        var lastKey: ConversationKey?
        var lastSender: Int?
        var lastTimestamp = 0
        for message in model.messages {
            let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
            let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
            if day != lastDay {
                out.append(.daySeparator(daySeparatorLabel(for: date)))
                lastDay = day
                lastSender = nil
            }
            if headerMode != .hidden,
               let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId),
               key != lastKey {
                out.append(.conversationHeader(key: key, firstMessageId: message.id))
                lastKey = key
                lastSender = nil
            }
            let showHeader = message.senderId != lastSender || message.timestamp - lastTimestamp > 300
            out.append(.message(message, showHeader: showHeader))
            lastSender = message.senderId
            lastTimestamp = message.timestamp
        }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !model.haveOldest && !model.messages.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear {
                            Task { await model.fetchOlder() }
                        }
                }
                ForEach(items) { item in
                    switch item {
                    case .daySeparator(let label):
                        Text(label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    case .conversationHeader(let key, _):
                        ConversationHeaderRow(
                            store: store, conversationKey: key,
                            includeChannel: headerMode == .channelAndTopic,
                            onTap: onHeaderTap)
                    case .message(let message, let showHeader):
                        MessageRow(
                            store: store, message: message,
                            showHeader: showHeader, cache: cache)
                    }
                }
                if model.messages.isEmpty {
                    ContentUnavailableView("No Messages", systemImage: "bubble")
                        .padding(.top, 60)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $anchorId, anchor: .bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 60
        } action: { _, isNear in
            nearBottom = isNear
        }
        .onAppear {
            anchorId = items.last?.id
        }
        .onChange(of: model.messages.last?.id) { _, newLastId in
            guard let newLastId else { return }
            if nearBottom {
                anchorId = "msg-\(newLastId)"
            }
            onNewMessages?()
        }
    }
}

/// A recipient bar in the web app's style: full-width, tinted with the
/// channel's color, leading colored channel glyph.
private struct ConversationHeaderRow: View {
    let store: PerAccountStore
    let conversationKey: ConversationKey
    let includeChannel: Bool
    let onTap: ((ConversationKey) -> Void)?

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
                Image(systemName: glyph)
                    .font(.callout.weight(.bold))
                    .foregroundStyle(streamId == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(channelColor))
                if isResolved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Text(label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help("Open this conversation")
    }
}

struct MessageRow: View {
    let store: PerAccountStore
    let message: Message
    let showHeader: Bool
    let cache: MessageContentCache

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showHeader {
                AvatarView(store: store, userId: message.senderId, size: 32)
                    .padding(.top, 10)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if showHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.senderFullName)
                            .font(.callout.weight(.semibold))
                        Text(
                            Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                                .formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if message.lastEditTimestamp != nil {
                            Text("Edited")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 10)
                }
                MessageContentView(
                    content: cache.content(for: message), connection: store.connection)
                if !message.reactions.isEmpty {
                    ReactionsRow(reactions: message.reactions, selfUserId: store.selfUserId)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

struct ReactionsRow: View {
    let reactions: [Reaction]
    let selfUserId: Int

    private struct Group: Identifiable {
        var display: String
        var count: Int
        var reactedBySelf: Bool
        var id: String { display }
    }

    private var groups: [Group] {
        var byEmoji: [String: Group] = [:]
        for reaction in reactions {
            let display = reaction.reactionType == "unicode_emoji"
                ? (emojiCharacter(fromCodes: reaction.emojiCode) ?? ":\(reaction.emojiName):")
                : ":\(reaction.emojiName):"
            byEmoji[display, default: Group(display: display, count: 0, reactedBySelf: false)]
                .count += 1
            if reaction.userId == selfUserId {
                byEmoji[display]?.reactedBySelf = true
            }
        }
        return byEmoji.values.sorted { $0.count > $1.count }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(groups) { group in
                Text("\(group.display) \(group.count)")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        group.reactedBySelf ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                        in: .capsule)
            }
        }
        .padding(.top, 1)
    }
}
