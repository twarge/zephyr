import SwiftUI
import ZulipAPI
import ZulipModel

/// Per-conversation draft persistence: survives switching conversations AND
/// app relaunches (UserDefaults-backed; local-only — server draft sync is
/// deliberately deferred). Drafts are inherently offline-safe: composing
/// needs no network, and the text stays until sent or cleared.
@MainActor
final class DraftStore {
    static let shared = DraftStore()
    private var drafts: [SendDestination: String]

    private static let key = "composeDrafts"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([SendDestination: String].self, from: data) {
            drafts = saved
        } else {
            drafts = [:]
        }
    }

    func draft(for destination: SendDestination) -> String {
        drafts[destination] ?? ""
    }

    func setDraft(_ text: String, for destination: SendDestination) {
        if text.isEmpty {
            drafts.removeValue(forKey: destination)
        } else {
            drafts[destination] = text
        }
        if let data = try? JSONEncoder().encode(drafts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

private enum ComposeSuggestion: Identifiable {
    case mention(User)
    case emoji(EmojiEntry)
    case channel(Subscription)

    var id: String {
        switch self {
        case .mention(let user): "m\(user.userId)"
        case .emoji(let entry): "e\(entry.id)"
        case .channel(let sub): "c\(sub.streamId)"
        }
    }

    /// The Zulip markdown inserted on accept.
    var completion: String {
        switch self {
        case .mention(let user): "@**\(user.fullName)** "
        case .emoji(let entry): ":\(entry.name): "
        case .channel(let sub): "#**\(sub.name)** "
        }
    }
}

/// The Messages-style compose bar with @/#/:-autocomplete and typing
/// notifications. Fixed mode composes into a known conversation; channel
/// mode adds a topic field.
struct ComposeBar: View {
    enum Mode {
        case fixed(SendDestination, placeholder: String)
        case channel(streamId: Int)
    }

    let store: PerAccountStore
    let mode: Mode

    @State private var text = ""
    @State private var topicText = ""
    @State private var suggestions: [ComposeSuggestion] = []
    @State private var selectedSuggestion = 0
    @State private var tokenTriggerIndex: String.Index?
    @State private var uploadingFilenames: [String] = []
    @State private var showFileImporter = false
    @FocusState private var messageFocused: Bool
    @Environment(KeyboardRouter.self) private var keys
    @State private var uploadOwnerId = UUID()

    private var destination: SendDestination? {
        switch mode {
        case .fixed(let destination, _):
            return destination
        case .channel(let streamId):
            let topic = topicText.trimmingCharacters(in: .whitespaces)
            guard !topic.isEmpty else { return nil }
            return .topic(streamId: streamId, topic: topic)
        }
    }

    private var placeholder: String {
        switch mode {
        case .fixed(_, let placeholder):
            return "Message \(placeholder)"
        case .channel:
            return "Message this topic"
        }
    }

    private var canSend: Bool {
        destination != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !suggestions.isEmpty {
                suggestionsCard
            }
            if case .channel = mode {
                TextField("Topic", text: $topicText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 260)
            }
            if !uploadingFilenames.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Uploading \(uploadingFilenames.joined(separator: ", "))…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
                .help("Attach a file (or drop one on the message field)")
                TextField(placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 17))
                    .focused($messageFocused)
                    .onSubmit { send() }
                    .onKeyPress(.upArrow) { moveSelection(-1) }
                    .onKeyPress(.downArrow) { moveSelection(1) }
                    .onKeyPress(.tab) { acceptSelection() }
                    .onKeyPress(.return) { acceptSelection() }
                    .onKeyPress(.escape) {
                        guard !suggestions.isEmpty else { return .ignored }
                        suggestions = []
                        return .handled
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return; ⌥Return for a new line)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            for url in (try? result.get()) ?? [] {
                upload(fileURL: url, securityScoped: true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            for url in fileURLs {
                upload(fileURL: url, securityScoped: false)
            }
            return true
        }
        .onAppear {
            if case .fixed(let destination, _) = mode {
                text = DraftStore.shared.draft(for: destination)
            }
            // The keyboard router's r / c shortcuts focus this compose box.
            let focus = $messageFocused
            keys.focusCompose = { focus.wrappedValue = true }
            // Files dropped anywhere in the conversation upload into here.
            keys.registerUpload(owner: uploadOwnerId) { urls in
                for url in urls {
                    upload(fileURL: url, securityScoped: false)
                }
                focus.wrappedValue = true
            }
        }
        .onDisappear {
            keys.unregisterUpload(owner: uploadOwnerId)
        }
        .onChange(of: text) {
            if case .fixed(let destination, _) = mode {
                DraftStore.shared.setDraft(text, for: destination)
            }
            if let destination {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.typingStopped(in: destination)
                } else {
                    store.typingActivity(in: destination)
                }
            }
            updateSuggestions()
        }
    }

    // MARK: Suggestions

    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    accept(suggestion)
                } label: {
                    suggestionLabel(suggestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            index == selectedSuggestion
                                ? AnyShapeStyle(.tint.opacity(0.2))
                                : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(maxWidth: 360)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func suggestionLabel(_ suggestion: ComposeSuggestion) -> some View {
        switch suggestion {
        case .mention(let user):
            HStack(spacing: 6) {
                AvatarView(store: store, userId: user.userId, size: 18)
                Text(user.fullName)
                if user.isBot {
                    Image(systemName: "cpu").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        case .emoji(let entry):
            HStack(spacing: 6) {
                if let character = entry.character {
                    Text(character)
                } else if let src = entry.realmSrc,
                          let image = EmojiImageLoader.shared.image(
                            src: src, connection: store.connection) {
                    Image(platform: image)
                } else {
                    Image(systemName: "face.smiling")
                }
                Text(":\(entry.name):")
                    .font(.callout)
            }
        case .channel(let sub):
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sub.name)
            }
        }
    }

    private func updateSuggestions() {
        guard let (token, triggerIndex) = ComposeAutocomplete.trailingToken(in: text) else {
            suggestions = []
            tokenTriggerIndex = nil
            return
        }
        tokenTriggerIndex = triggerIndex
        selectedSuggestion = 0
        switch token {
        case .mention(let query):
            let users = store.users.values
                .filter { $0.isActive != false }
                .filter { query.isEmpty || $0.fullName.localizedCaseInsensitiveContains(query) }
                .sorted {
                    $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
                }
                .prefix(6)
            suggestions = users.map { .mention($0) }
        case .emoji(let query):
            store.loadEmojiCatalogIfNeeded()
            let prefixMatches = store.emojiEntries.filter {
                $0.name.hasPrefix(query.lowercased())
            }
            let containsMatches = store.emojiEntries.filter {
                !$0.name.hasPrefix(query.lowercased())
                    && $0.name.localizedCaseInsensitiveContains(query)
            }
            suggestions = (prefixMatches + containsMatches).prefix(8).map { .emoji($0) }
        case .channel(let query):
            let channels = store.subscriptions.values
                .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .prefix(6)
            suggestions = channels.map { .channel($0) }
        }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        selectedSuggestion = (selectedSuggestion + delta + suggestions.count) % suggestions.count
        return .handled
    }

    private func acceptSelection() -> KeyPress.Result {
        guard !suggestions.isEmpty, suggestions.indices.contains(selectedSuggestion) else {
            return .ignored
        }
        accept(suggestions[selectedSuggestion])
        return .handled
    }

    private func accept(_ suggestion: ComposeSuggestion) {
        guard let triggerIndex = tokenTriggerIndex, triggerIndex <= text.endIndex else {
            suggestions = []
            return
        }
        text.replaceSubrange(triggerIndex..<text.endIndex, with: suggestion.completion)
        suggestions = []
        tokenTriggerIndex = nil
        messageFocused = true
    }

    // MARK: Uploads

    /// Uploads a file and appends its `[filename](url)` reference to the
    /// draft.
    private func upload(fileURL: URL, securityScoped: Bool) {
        let filename = fileURL.lastPathComponent
        let scoped = securityScoped ? fileURL.startAccessingSecurityScopedResource() : false
        guard let data = try? Data(contentsOf: fileURL) else {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            return
        }
        if scoped { fileURL.stopAccessingSecurityScopedResource() }

        uploadingFilenames.append(filename)
        let connection = store.connection
        Task {
            defer { uploadingFilenames.removeAll { $0 == filename } }
            guard let path = try? await connection.uploadFile(data, filename: filename) else {
                return
            }
            let reference = "[\(filename)](\(path))"
            text = text.isEmpty ? reference : "\(text)\n\(reference)"
        }
    }

    // MARK: Send

    private func send() {
        guard suggestions.isEmpty else { return }
        guard canSend, let destination else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.send(content, to: destination)
        store.typingStopped(in: destination)
        text = ""
        DraftStore.shared.setDraft("", for: destination)
        if UserDefaults.standard.object(forKey: "playSendSound") as? Bool ?? true {
            Platform.playSendSound()
        }
    }
}

/// An optimistically-sent message awaiting its echo (or showing its failure).
struct OutboxRow: View {
    let store: PerAccountStore
    let message: OutboxMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(store: store, userId: store.selfUserId, size: 32)
                .padding(.top, 10)
                .opacity(0.7)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.users[store.selfUserId]?.fullName ?? "You")
                        .font(.callout.weight(.semibold))
                    switch message.state {
                    case .sending:
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Sending…")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    case .queued:
                        Label("Waiting for network", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Send Now") { store.retrySend(message.id) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button("Discard") { store.discardSend(message.id) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    case .failed(let reason):
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                        Button("Retry") { store.retrySend(message.id) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button("Discard") { store.discardSend(message.id) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
                .padding(.top, 10)
                Text(message.content)
                    .foregroundStyle(message.state == .sending ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}
