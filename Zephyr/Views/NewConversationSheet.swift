import SwiftUI
import ZulipAPI
import ZulipModel

/// How the new-conversation sheet is opened: the full ⌘N flow (people or
/// channel+topic), or scoped to people only — from the sidebar's "+" or a DM
/// transcript's "Add People…" (pre-seeded with the current participants;
/// Zulip DM membership is immutable, so that starts a new conversation).
enum NewConversationMode: Identifiable {
    case general
    case directMessage(initialUsers: [User])

    var id: String {
        switch self {
        case .general:
            return "general"
        case .directMessage(let users):
            return "dm-\(users.map { String($0.userId) }.joined(separator: ","))"
        }
    }
}

/// The ⌘N flow: pick people (DM, multi-select) or a channel + topic, write
/// the first message, send — then land in the conversation.
struct NewConversationSheet: View {
    let store: PerAccountStore
    @Binding var selection: Destination?
    let peopleOnly: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedUsers: [User]
    @State private var selectedChannel: Subscription?
    @State private var topicText = ""
    @State private var messageText = ""
    @FocusState private var queryFocused: Bool

    init(
        store: PerAccountStore, selection: Binding<Destination?>,
        mode: NewConversationMode = .general
    ) {
        self.store = store
        _selection = selection
        switch mode {
        case .general:
            peopleOnly = false
            _selectedUsers = State(initialValue: [])
        case .directMessage(let initialUsers):
            peopleOnly = true
            _selectedUsers = State(initialValue: initialUsers)
        }
    }

    private var userSuggestions: [User] {
        guard selectedChannel == nil else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return store.users.values
            .filter { $0.isActive != false }
            .filter { trimmed.isEmpty || $0.fullName.localizedCaseInsensitiveContains(trimmed) }
            .filter { user in !selectedUsers.contains(where: { $0.userId == user.userId }) }
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
            .prefix(5)
            .map { $0 }
    }

    private var channelSuggestions: [Subscription] {
        guard !peopleOnly, selectedUsers.isEmpty, selectedChannel == nil else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return store.subscriptions.values
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(5)
            .map { $0 }
    }

    private var destination: SendDestination? {
        if let channel = selectedChannel {
            let topic = topicText.trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty else { return nil }
            return .topic(streamId: channel.streamId, topic: topic)
        }
        guard !selectedUsers.isEmpty else { return nil }
        return .dm(userIds: selectedUsers.map(\.userId))
    }

    private var canSend: Bool {
        destination != nil
            && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(peopleOnly ? "New Direct Message" : "New Conversation")
                .font(.headline)

            // Recipient line: chips + search field.
            HStack(spacing: 6) {
                Text("To:")
                    .foregroundStyle(.secondary)
                if let channel = selectedChannel {
                    chip("#\(channel.name)") {
                        selectedChannel = nil
                        topicText = ""
                    }
                }
                ForEach(selectedUsers, id: \.userId) { user in
                    chip(user.fullName) {
                        selectedUsers.removeAll { $0.userId == user.userId }
                    }
                }
                TextField(
                    selectedUsers.isEmpty && selectedChannel == nil
                        ? (peopleOnly ? "Person" : "Person or #channel") : "Add person",
                    text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            if !userSuggestions.isEmpty || !channelSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(channelSuggestions) { channel in
                        suggestionButton(
                            label: "#\(channel.name)", icon: "number"
                        ) {
                            selectedChannel = channel
                            selectedUsers = []
                            query = ""
                        }
                    }
                    ForEach(userSuggestions, id: \.userId) { user in
                        suggestionButton(
                            label: user.userId == store.selfUserId
                                ? "\(user.fullName) (you)" : user.fullName,
                            icon: "person"
                        ) {
                            selectedUsers.append(user)
                            selectedChannel = nil
                            query = ""
                        }
                    }
                }
                .padding(4)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }

            if selectedChannel != nil {
                TextField("Topic", text: $topicText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
            }

            TextField("Message", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...10)
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { queryFocused = true }
    }

    private func chip(_ label: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.callout)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.tint.opacity(0.15), in: .capsule)
    }

    private func suggestionButton(
        label: String, icon: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func send() {
        guard canSend, let destination else { return }
        store.send(
            messageText.trimmingCharacters(in: .whitespacesAndNewlines), to: destination)
        switch destination {
        case .topic(let streamId, let topic):
            selection = .conversation(.topic(streamId: streamId, topic: topic))
        case .dm(let userIds):
            selection = .conversation(
                Unreads.dmKey(participantIds: userIds, selfUserId: store.selfUserId))
        }
        dismiss()
    }
}
