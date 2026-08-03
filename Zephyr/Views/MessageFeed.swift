import SwiftUI
import ZulipAPI
import ZulipContent
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
    /// Search results: render `match_content` (server-marked term highlights)
    /// instead of the plain content.
    var useMatchHighlights = false
    var onHeaderTap: ((ConversationKey) -> Void)?
    var onNewMessages: (() -> Void)?

    @State private var anchorId: String?
    @State private var nearBottom = true

    private var outboxMessages: [OutboxMessage] {
        store.outbox.filter {
            $0.destination.matches(narrow: model.narrow, selfUserId: store.selfUserId)
        }
    }

    /// Names of people typing in this exact conversation (topic/DM narrows).
    private var typistNames: [String]? {
        let key: ConversationKey?
        switch model.narrow {
        case .topic(let streamId, let topic):
            key = .topic(streamId: streamId, topic: topic)
        case .dm(let userIds):
            key = Unreads.dmKey(participantIds: userIds, selfUserId: store.selfUserId)
        default:
            key = nil
        }
        guard let key else { return nil }
        return store.typing.typistIds(in: key)
            .compactMap { store.users[$0]?.fullName }
    }

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
                            showHeader: showHeader, cache: cache,
                            useMatchHighlights: useMatchHighlights)
                    }
                }
                if model.haveNewest {
                    ForEach(outboxMessages) { outboxMessage in
                        OutboxRow(store: store, message: outboxMessage)
                            .id("out-\(outboxMessage.id)")
                    }
                }
                if let names = typistNames, !names.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis.bubble")
                            .foregroundStyle(.secondary)
                        Text("\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") typing…")
                            .italic()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.vertical, 6)
                    .padding(.leading, 42)
                }
                if model.messages.isEmpty && outboxMessages.isEmpty {
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
        .onChange(of: outboxMessages.last?.id) { _, newLastId in
            if let newLastId, nearBottom {
                anchorId = "out-\(newLastId)"
            }
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
    var useMatchHighlights = false

    @State private var hovering = false
    @State private var showReactionPicker = false
    @State private var editing = false
    @State private var editText = ""
    @State private var showMoveSheet = false
    @State private var showReadReceipts = false
    @State private var showEditHistory = false

    private var content: MessageContent {
        if useMatchHighlights, let match = message.matchContent {
            // Uncached: search results are one-shot lists.
            return ContentParser.parse(html: match)
        }
        return cache.content(for: message)
    }

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
                            Button {
                                showEditHistory = true
                            } label: {
                                Text("Edited")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .help("Show edit history")
                            .popover(isPresented: $showEditHistory) {
                                EditHistoryView(store: store, message: message)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                if editing {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Message", text: $editText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...12)
                            .padding(6)
                            .background(
                                .quaternary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button("Cancel") { editing = false }
                                .keyboardShortcut(.cancelAction)
                            Button("Save") {
                                let content = editText.trimmingCharacters(
                                    in: .whitespacesAndNewlines)
                                if !content.isEmpty {
                                    store.editMessage(message.id, content: content)
                                }
                                editing = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                        .controlSize(.small)
                    }
                } else if let widget = MessageWidget.parse(message) {
                    MessageWidgetView(widget: widget, store: store)
                } else {
                    MessageContentView(
                        content: content, connection: store.connection)
                }
                if !message.reactions.isEmpty {
                    ReactionsRow(store: store, message: message)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if hovering || showReactionPicker {
                Button {
                    showReactionPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(.quaternary.opacity(0.6), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Add reaction")
                .popover(isPresented: $showReactionPicker) {
                    EmojiPickerView(store: store) { entry in
                        store.toggleReaction(
                            message: message, emojiName: entry.name,
                            emojiCode: entry.code, reactionType: entry.reactionType)
                    }
                }
                .padding(.top, showHeader ? 8 : 0)
            }
        }
        .contextMenu {
            let isStarred = (message.flags ?? []).contains("starred")
            Button(isStarred ? "Unstar" : "Star", systemImage: "star") {
                store.setStarred(!isStarred, messageId: message.id)
            }
            Button("Copy Text", systemImage: "doc.on.doc") {
                Platform.copyToPasteboard(content.plainText)
            }
            Button("Seen By…", systemImage: "eye") {
                showReadReceipts = true
            }
            if message.type == .stream {
                Button("Move to Topic…", systemImage: "arrow.turn.up.right") {
                    showMoveSheet = true
                }
            }
            if message.senderId == store.selfUserId {
                Divider()
                Button("Edit Message", systemImage: "pencil") {
                    Task {
                        editText = await store.fetchRawContent(message.id) ?? ""
                        if !editText.isEmpty {
                            editing = true
                        }
                    }
                }
                Button("Delete Message", systemImage: "trash", role: .destructive) {
                    store.deleteMessage(message.id)
                }
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            MoveTopicSheet(store: store, message: message)
        }
        .sheet(isPresented: $showReadReceipts) {
            ReadReceiptsSheet(store: store, message: message)
        }
    }
}

struct ReactionsRow: View {
    let store: PerAccountStore
    let message: Message

    private var reactions: [Reaction] { message.reactions }

    @State private var showPicker = false

    private struct Group: Identifiable {
        var id: String
        var sample: Reaction
        var count: Int
        var reactedBySelf: Bool
    }

    private var groups: [Group] {
        var byEmoji: [String: Group] = [:]
        var order: [String] = []
        for reaction in reactions {
            let key = "\(reaction.reactionType):\(reaction.emojiCode)"
            if byEmoji[key] == nil {
                byEmoji[key] = Group(id: key, sample: reaction, count: 0, reactedBySelf: false)
                order.append(key)
            }
            byEmoji[key]?.count += 1
            if reaction.userId == store.selfUserId {
                byEmoji[key]?.reactedBySelf = true
            }
        }
        return order.compactMap { byEmoji[$0] }.sorted { $0.count > $1.count }
    }

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
                    HStack(spacing: 3) {
                        emojiView(group.sample)
                        Text("\(group.count)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        group.reactedBySelf ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                        in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(group.reactedBySelf
                    ? "Remove your :\(group.sample.emojiName): reaction"
                    : "React with :\(group.sample.emojiName):")
            }
            Button {
                showPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("Add reaction")
            .popover(isPresented: $showPicker) {
                EmojiPickerView(store: store) { entry in
                    store.toggleReaction(
                        message: message, emojiName: entry.name,
                        emojiCode: entry.code, reactionType: entry.reactionType)
                }
            }
        }
        .padding(.top, 1)
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
