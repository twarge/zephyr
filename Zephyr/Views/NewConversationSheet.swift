import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import ZulipAPI
import ZulipContent
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
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var activeUploads = 0
    @State private var showPreview = false
    @State private var previewContent: MessageContent?
    @State private var previewTask: Task<Void, Never>?

    // The compose bar's control metrics (touch-sized on iOS); the
    // suggestion list and editor cap/shrink so everything fits a medium
    // iPhone sheet.
    #if os(macOS)
    private nonisolated static let attachIconSize: CGFloat = 16
    private nonisolated static let sendIconSize: CGFloat = 24
    private nonisolated static let columnSpacing: CGFloat = 10
    private nonisolated static let suggestionsMaxHeight: CGFloat = 240
    private nonisolated static let editorMinHeight: CGFloat = 120
    #else
    private nonisolated static let attachIconSize: CGFloat = 22
    private nonisolated static let sendIconSize: CGFloat = 34
    private nonisolated static let columnSpacing: CGFloat = 0
    private nonisolated static let suggestionsMaxHeight: CGFloat = 180
    private nonisolated static let editorMinHeight: CGFloat = 80
    #endif

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
            // Sending waits for uploads: their [name](url) references only
            // land in the text when the upload finishes.
            && activeUploads == 0
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
                // Scrollable, height-capped: ten rows of matches would
                // otherwise crowd the editor off an iPhone sheet.
                ScrollView {
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
                }
                .frame(maxHeight: Self.suggestionsMaxHeight)
                .scrollBounceBehavior(.basedOnSize)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }

            if let channel = selectedChannel {
                // The compose bar's popover-style card. It drops downward
                // here — that's where this sheet has room (message field +
                // buttons) — capped so the sheet's bounds never clip it.
                TopicAutocompleteField(
                    store: store, streamId: channel.streamId, topic: $topicText,
                    maxSuggestions: 5)
                    .frame(maxWidth: 280)
                    .zIndex(1)
            }

            // The compose bar's expanded-mode editor: rounded editor with
            // the trailing control column — file, photo, preview, send.
            // No Cancel/Send row: the column sends, the sheet dismisses.
            HStack(alignment: .bottom, spacing: 8) {
                editor
                VStack(spacing: Self.columnSpacing) {
                    Button {
                        showFileImporter = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: Self.attachIconSize))
                            .foregroundStyle(.secondary)
                            .touchTarget()
                    }
                    .buttonStyle(.plain)
                    .help("Attach files")
                    .fileImporter(
                        isPresented: $showFileImporter,
                        allowedContentTypes: [.item],
                        allowsMultipleSelection: true
                    ) { result in
                        guard case .success(let urls) = result else { return }
                        for url in urls {
                            upload(fileURL: url)
                        }
                    }
                    PhotosPicker(
                        selection: $photoPickerItems,
                        maxSelectionCount: 10,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Image(systemName: "photo")
                            .font(.system(size: Self.attachIconSize))
                            .foregroundStyle(.secondary)
                            .touchTarget()
                    }
                    .buttonStyle(.plain)
                    .help("Attach photos or videos")
                    Button {
                        togglePreview()
                    } label: {
                        Image(systemName: showPreview ? "eye.slash" : "eye")
                            .font(.system(size: Self.attachIconSize))
                            .foregroundStyle(.secondary)
                            .touchTarget()
                    }
                    .buttonStyle(.plain)
                    .disabled(!showPreview
                        && messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(showPreview ? "Back to editing" : "Preview as it will send")
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: Self.sendIconSize))
                            .foregroundStyle(
                                canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            .touchTarget()
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘Return)")
                }
            }
            if activeUploads > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Uploading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(width: 460)
        #endif
        .onAppear { queryFocused = true }
        .onChange(of: photoPickerItems) {
            guard !photoPickerItems.isEmpty else { return }
            uploadPickedPhotos()
        }
    }

    /// The message editor (or its server-rendered preview), styled like
    /// the compose bar's expanded mode.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if showPreview {
                ScrollView {
                    Group {
                        if let previewContent {
                            MessageContentView(
                                content: previewContent, connection: store.connection)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                // Tapping the preview returns to editing.
                .contentShape(.rect)
                .onTapGesture { togglePreview() }
                .help("Tap to edit")
            } else {
                if messageText.isEmpty {
                    Text("Message")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $messageText)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .padding(.horizontal, 5)
                    #if os(macOS)
                    .padding(.top, 8)
                    .padding(.bottom, 1)
                    #else
                    .padding(.vertical, 1)
                    #endif
            }
        }
        .frame(minHeight: Self.editorMinHeight, maxHeight: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
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

    // MARK: Attachments and preview (the compose bar's behavior)

    private func upload(fileURL: URL) {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        guard let data = try? Data(contentsOf: fileURL) else {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            return
        }
        if scoped { fileURL.stopAccessingSecurityScopedResource() }
        upload(data: data, filename: fileURL.lastPathComponent)
    }

    private func uploadPickedPhotos() {
        let items = photoPickerItems
        photoPickerItems = []
        for pick in items {
            Task {
                guard let data = try? await pick.loadTransferable(type: Data.self)
                else { return }
                let ext = pick.supportedContentTypes.first?
                    .preferredFilenameExtension ?? "jpeg"
                let stamp = UUID().uuidString.prefix(8)
                upload(data: data, filename: "photo-\(stamp).\(ext)")
            }
        }
    }

    /// Uploads and appends the `[filename](url)` reference to the draft
    /// (images/audio embed with a leading "!").
    private func upload(data: Data, filename: String) {
        activeUploads += 1
        let connection = store.connection
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        let mimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        Task {
            defer { activeUploads -= 1 }
            guard let path = try? await connection.uploadFile(
                data, filename: filename, mimeType: mimeType, progress: { _ in })
            else { return }
            let linkPath = path.replacingOccurrences(of: " ", with: "%20")
            let embed = mimeType.hasPrefix("image/") || mimeType.hasPrefix("audio/")
            let reference = "\(embed ? "!" : "")[\(filename)](\(linkPath))"
            messageText = messageText.isEmpty
                ? reference : "\(messageText)\n\(reference)"
        }
    }

    /// Server-rendered preview (POST /messages/render): exactly what will
    /// send, through the production renderer.
    private func togglePreview() {
        showPreview.toggle()
        previewTask?.cancel()
        guard showPreview else { return }
        previewContent = nil
        let content = messageText
        let connection = store.connection
        previewTask = Task {
            let html = (try? await connection.renderMessage(content: content)) ?? ""
            guard !Task.isCancelled else { return }
            previewContent = ContentParser.parse(
                html: html.isEmpty
                    ? "<p><em>Preview unavailable (offline?)</em></p>" : html)
        }
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
