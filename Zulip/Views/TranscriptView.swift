import SwiftUI
import ZulipAPI
import ZulipModel

/// The transcript for one conversation: flat, left-aligned, sender-grouped
/// (SPEC §5). Opens anchored at the newest messages; scrolling up pages in
/// history.
struct TranscriptView: View {
    let store: PerAccountStore
    let conversation: ConversationKey

    @State private var model: MessageListModel?
    @State private var cache = MessageContentCache()

    var body: some View {
        Group {
            if let model, model.didInitialFetch {
                TranscriptList(store: store, model: model, cache: cache, conversation: conversation)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(conversation.displayTitle(in: store))
        .task {
            guard model == nil else { return }
            let list = MessageListModel(store: store, narrow: conversation.narrow)
            model = list
            await list.fetchInitial()
            store.markConversationRead(conversation)
        }
    }
}

private struct TranscriptList: View {
    let store: PerAccountStore
    let model: MessageListModel
    let cache: MessageContentCache
    let conversation: ConversationKey

    private enum Item: Identifiable {
        case daySeparator(String)
        case message(Message, showHeader: Bool)

        var id: String {
            switch self {
            case .daySeparator(let label): "day-\(label)"
            case .message(let message, _): "msg-\(message.id)"
            }
        }
    }

    /// Messages interleaved with day separators; consecutive messages from
    /// the same sender within 5 minutes coalesce under one header.
    private var items: [Item] {
        var out: [Item] = []
        var lastDay: DateComponents?
        var lastSender: Int?
        var lastTimestamp = 0
        for message in model.messages {
            let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
            let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
            if day != lastDay {
                out.append(.daySeparator(date.formatted(date: .abbreviated, time: .omitted)))
                lastDay = day
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
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .onChange(of: model.messages.count) {
            // New arrivals while the conversation is open are read.
            store.markConversationRead(conversation)
        }
    }
}

private struct MessageRow: View {
    let store: PerAccountStore
    let message: Message
    let showHeader: Bool
    let cache: MessageContentCache

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showHeader {
                InitialsAvatar(
                    name: message.senderFullName, seed: message.senderId, size: 32)
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

private struct ReactionsRow: View {
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
