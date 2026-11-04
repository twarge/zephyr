import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// Move a message (and optionally its neighbors) — or a whole topic —
/// to another topic, in this or any other channel. Moving onto a topic
/// that already exists merges into it.
struct MoveTopicSheet: View {
    /// What moves: one message (with a propagate picker), or a whole
    /// topic (anchored at its newest message, always change_all).
    enum Subject {
        case message(Message)
        case topic(streamId: Int, name: String, maxId: Int)
    }

    let store: PerAccountStore
    let subject: Subject
    /// Runs after the move is requested (e.g. refresh the sidebar's
    /// cached topic list).
    var onMoved: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var topic: String
    @State private var streamId: Int
    @State private var propagateMode = "change_all"

    init(store: PerAccountStore, subject: Subject, onMoved: (() -> Void)? = nil) {
        self.store = store
        self.subject = subject
        self.onMoved = onMoved
        switch subject {
        case .message(let message):
            // Only channel messages can move (the menu gates on .stream),
            // so streamId is always present here.
            _streamId = State(initialValue: message.streamId ?? -1)
            _topic = State(initialValue: TopicName.displayName(message.topic))
        case .topic(let streamId, let name, _):
            _streamId = State(initialValue: streamId)
            // The raw name (✔ included, web-style): an unchanged move
            // keeps the topic resolved, and accepted suggestions insert
            // the destination's raw name — what's typed is what moves.
            _topic = State(initialValue: name)
        }
    }

    private var sourceStreamId: Int {
        switch subject {
        case .message(let message): message.streamId ?? -1
        case .topic(let streamId, _, _): streamId
        }
    }

    /// Subscribed channels by name; the source channel joins even when
    /// unsubscribed (a public channel opened via search) so the picker
    /// always has a valid selection.
    private var channelChoices: [(id: Int, name: String)] {
        var choices = store.subscriptions.values.map { (id: $0.streamId, name: $0.name) }
        if !choices.contains(where: { $0.id == sourceStreamId }) {
            choices.append((
                id: sourceStreamId,
                name: store.channels[sourceStreamId]?.name ?? "current channel"))
        }
        return choices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var canMove: Bool {
        let trimmed = topic.trimmingCharacters(in: .whitespaces)
        switch subject {
        case .message:
            return !trimmed.isEmpty
        case .topic(_, let name, _):
            // A channel change alone is a valid move (the empty name is
            // "general chat"); otherwise the name must actually change.
            return streamId != sourceStreamId || (!trimmed.isEmpty && trimmed != name)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch subject {
            case .message:
                Text("Move Message")
                    .font(.headline)
                Picker("Apply to:", selection: $propagateMode) {
                    Text("This message only").tag("change_one")
                    Text("This and later messages").tag("change_later")
                    Text("The entire topic").tag("change_all")
                }
                .pickerStyle(.inline)
            case .topic:
                Text("Move Topic")
                    .font(.headline)
            }
            Picker("Channel:", selection: $streamId) {
                ForEach(channelChoices, id: \.id) { choice in
                    Text("#\(choice.name)").tag(choice.id)
                }
            }
            // The compose bar's popover behavior: the field sits low and
            // the measured card floats up over the picker, so the sheet's
            // bounds never clip the suggestions.
            TopicAutocompleteField(
                store: store, streamId: streamId, topic: $topic, dropUp: true)
                .zIndex(1)
            if case .topic = subject {
                Text("Every message in the topic moves; moving to an existing topic merges them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    move()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canMove)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func move() {
        let trimmed = topic.trimmingCharacters(in: .whitespaces)
        let destination = streamId == sourceStreamId ? nil : streamId
        switch subject {
        case .message(let message):
            store.moveMessage(
                message.id, toTopic: trimmed, toChannel: destination,
                propagateMode: propagateMode)
        case .topic(_, _, let maxId):
            store.moveMessage(
                maxId, toTopic: trimmed, toChannel: destination,
                propagateMode: "change_all")
        }
        onMoved?()
    }
}

/// "Forward message to…": pick any conversation; the quoted message lands
/// in its compose field, ready to annotate and send.
struct ForwardMessageSheet: View {
    let store: PerAccountStore
    var open: (Destination) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Forward message to…", systemImage: "arrowshape.turn.up.right")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            OpenQuicklyView(store: store, open: open)
        }
    }
}

/// A custom reminder time, for anything the menu presets don't cover.
struct RemindTimeSheet: View {
    var onSet: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now.addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remind Me At")
                .font(.headline)
            DatePicker(
                "Time", selection: $date, in: Date.now...,
                displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Reminder") {
                    onSet(date)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 280)
    }
}

/// Who has read a message (server-filtered for privacy opt-outs).
struct ReadReceiptsSheet: View {
    let store: PerAccountStore
    let message: Message

    @Environment(\.dismiss) private var dismiss
    @State private var readerIds: [Int]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Seen by")
                .font(.headline)
            if let readerIds {
                if readerIds.isEmpty {
                    Text("No read receipts yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(readerIds, id: \.self) { userId in
                                HStack(spacing: 8) {
                                    AvatarView(store: store, userId: userId, size: 22)
                                    Text(store.users[userId]?.fullName ?? "User \(userId)")
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    Text("\(readerIds.count) \(readerIds.count == 1 ? "person" : "people")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
        .task {
            readerIds = await store.fetchReadReceipts(message.id) ?? []
        }
    }
}

/// A message's edit/move history, newest first.
struct EditHistoryView: View {
    let store: PerAccountStore
    let message: Message

    @State private var history: [EditHistoryEntry]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit History")
                .font(.headline)
            if let history {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(
                                        Date(timeIntervalSince1970: TimeInterval(entry.timestamp))
                                            .formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    if let editor = entry.userId.flatMap({ store.users[$0]?.fullName }) {
                                        Text("· \(editor)")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let previous = entry.prevTopic, let topic = entry.topic,
                                       previous != topic {
                                        Text("moved: \(TopicName.displayName(previous)) → \(TopicName.displayName(topic))")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if let rendered = entry.renderedContent {
                                    MessageContentView(
                                        content: ContentParser.parse(html: rendered),
                                        connection: store.connection)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(width: 420)
        .task {
            history = await store.fetchEditHistory(message.id) ?? []
        }
    }
}

/// View Links (the web app's topic menu item): the conversations this
/// topic's messages link to, and those whose messages link to it. The lists
/// come from every message stored on this device, then the server is asked
/// for linking messages never fetched. A row opens its conversation; a
/// message link lands on the message.
struct TopicLinksSheet: View {
    let store: PerAccountStore
    let streamId: Int
    let topic: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var lists: TopicLinkLists?
    @State private var isCheckingServer = false

    private var channelName: String {
        store.channels[streamId]?.name ?? store.subscriptions[streamId]?.name ?? "?"
    }

    private var topicName: String {
        let display = TopicName.displayName(topic)
        return display.isEmpty ? "general chat" : display
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollView {
                sections
            }
            .frame(maxHeight: 360)
            footer
        }
        .padding(16)
        .frame(width: 400)
        .task { await load() }
        #else
        // The ChannelColorSheet layout: half height to start, the whole
        // sheet scrolling when the lists run long.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                sections
                footer
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Links")
                .font(.headline)
            Text("#\(channelName) › \(topicName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var sections: some View {
        if let lists {
            VStack(alignment: .leading, spacing: 14) {
                if !lists.linksTo.isEmpty {
                    section("Links to", systemImage: "arrow.up.right", rows: lists.linksTo)
                }
                if !lists.linkedFrom.isEmpty {
                    section("Linked from", systemImage: "arrow.down.left", rows: lists.linkedFrom)
                }
                if lists.isEmpty, !isCheckingServer {
                    Text("Nothing links to or from this topic.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    private func section(
        _ title: LocalizedStringKey, systemImage: String, rows: [TopicLinkLists.Row]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            ForEach(rows) { row in
                TopicLinkRow(store: store, row: row) { open(row) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if isCheckingServer {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the server…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func load() async {
        lists = await store.topicLinks.lists(streamId: streamId, topic: topic)
        isCheckingServer = true
        if let filled = await store.topicLinks.listsIncludingServer(
            streamId: streamId, topic: topic) {
            lists = filled
        }
        isCheckingServer = false
    }

    private func open(_ row: TopicLinkLists.Row) {
        let link = InternalLink.topic(
            streamId: row.streamId, topic: row.topic, nearMessageId: row.messageId)
        dismiss()
        if let url = link.appURL {
            openURL(url)
        }
    }
}

/// One View Links row, styled like Recent Conversations': the channel's
/// colored glyph, channel › topic, and for a link to one message, who
/// sent it and when.
private struct TopicLinkRow: View {
    let store: PerAccountStore
    let row: TopicLinkLists.Row
    let open: () -> Void

    private var channelColor: Color {
        store.subscriptions[row.streamId]?.color.flatMap(Color.init(zulipHex:))
            ?? .stableColor(for: row.streamId)
    }

    private var glyph: String {
        let channel = store.channels[row.streamId]
        if channel?.inviteOnly == true { return "lock.fill" }
        if channel?.isWebPublic == true { return "globe" }
        return "number"
    }

    private var channelName: String {
        store.channels[row.streamId]?.name ?? store.subscriptions[row.streamId]?.name ?? "?"
    }

    /// The topic as its channel's list spells it now (a link's URL keeps
    /// whatever casing it was written with).
    private var topic: String {
        store.channelTopics.lists[row.streamId]?
            .first { TopicName.matches($0.name, row.topic) }?.name ?? row.topic
    }

    /// channel › topic as one run of text, so a long name wraps onto a
    /// second line at phone widths instead of truncating either part away.
    private var label: Text {
        let display = TopicName.displayName(topic)
        let chevron = Text(Image(systemName: "chevron.right"))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        let resolved = TopicName.isResolved(topic)
            ? Text("\(Text(Image(systemName: "checkmark.circle.fill")).foregroundStyle(.green)) ")
            : Text("")
        let name = Text(display.isEmpty ? "general chat" : display).fontWeight(.medium)
        return Text("\(channelName) \(chevron) \(resolved)\(name)")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // A fixed column, so #, lock and globe rows line up.
                Image(systemName: glyph)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(channelColor)
                    .frame(minWidth: 14)
                VStack(alignment: .leading, spacing: 1) {
                    label
                        .lineLimit(2)
                    if let sender = row.sender, let timestamp = row.timestamp {
                        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                        Text("\(sender) · \(date, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if row.isMessageLink {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(row.isMessageLink ? "Open at this message" : "Open this conversation")
    }
}
