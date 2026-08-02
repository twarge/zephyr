import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// Move a message (and optionally its neighbors) to another topic.
struct MoveTopicSheet: View {
    let store: PerAccountStore
    let message: Message

    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var propagateMode = "change_all"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to Topic")
                .font(.headline)
            TextField("Topic", text: $topic)
                .textFieldStyle(.roundedBorder)
            Picker("Apply to:", selection: $propagateMode) {
                Text("This message only").tag("change_one")
                Text("This and later messages").tag("change_later")
                Text("The entire topic").tag("change_all")
            }
            .pickerStyle(.inline)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    let trimmed = topic.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        store.moveMessage(
                            message.id, toTopic: trimmed, propagateMode: propagateMode)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            topic = TopicName.displayName(message.topic)
        }
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
