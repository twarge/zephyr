import SwiftUI
import UniformTypeIdentifiers
import ZulipAPI
import ZulipContent
import ZulipModel

/// Per-conversation draft persistence: survives switching conversations AND
/// app relaunches (UserDefaults-backed; local-only — server draft sync is
/// deliberately deferred). Drafts are inherently offline-safe: composing
/// needs no network, and the text stays until sent or cleared.
@MainActor
@Observable
final class DraftStore {
    static let shared = DraftStore()
    /// Observable so the sidebar's Drafts section tracks edits live.
    private(set) var drafts: [SendDestination: String]

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
    private struct UploadItem: Identifiable, Equatable {
        let id = UUID()
        var filename: String
        var progress: Double = 0
    }
    @State private var uploads: [UploadItem] = []
    @State private var showFileImporter = false
    @FocusState private var messageFocused: Bool
    @Environment(KeyboardRouter.self) private var keys
    @State private var uploadOwnerId = UUID()

    // Long-form mode: multi-line editor, drag-resizable, server-rendered
    // preview; Return newlines and ⇧Return sends.
    @AppStorage("composeExpanded") private var expanded = false
    @AppStorage("composeEditorHeight") private var editorHeight = 140.0
    @State private var dragBaseHeight: CGFloat?
    @State private var showPreview = false
    @State private var previewContent: MessageContent?
    @State private var previewTask: Task<Void, Never>?

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
        destination != nil
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Sending waits for uploads: their [name](url) references only
            // land in the text when the upload finishes.
            && uploads.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expanded {
                dragHandle
            }
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
            if !uploads.isEmpty {
                HStack(spacing: 6) {
                    ForEach(uploads) { item in
                        HStack(spacing: 5) {
                            Image(systemName: Self.fileIcon(for: item.filename))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(item.filename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 140)
                            UploadProgressRing(progress: item.progress)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.4), in: .capsule)
                    }
                    Spacer(minLength: 0)
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
                Button {
                    withAnimation(.snappy) {
                        expanded.toggle()
                    }
                    showPreview = false
                    previewTask?.cancel()
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 7)
                .help(expanded ? "Compact message field" : "Long-form message field")
                if expanded {
                    expandedEditor
                } else {
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
                }
                if expanded {
                    Button {
                        togglePreview()
                    } label: {
                        Image(systemName: showPreview ? "eye.slash" : "eye")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                    .disabled(!showPreview
                        && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(showPreview ? "Back to editing" : "Preview as it will send")
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(expanded
                    ? "Send (⇧Return; Return for a new line)"
                    : "Send (Return; ⌥Return for a new line)")
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
            // The keyboard router's r / c shortcuts focus this compose box;
            // media selection blurs it so Space can Quick Look.
            let focus = $messageFocused
            keys.focusCompose = { focus.wrappedValue = true }
            keys.blurCompose = { focus.wrappedValue = false }
            // Files dropped anywhere in the conversation upload into here.
            keys.registerUpload(owner: uploadOwnerId) { urls in
                for url in urls {
                    upload(fileURL: url, securityScoped: false)
                }
                focus.wrappedValue = true
            }
            // Quote-and-reply appends to the draft.
            keys.registerComposeInsertion(owner: uploadOwnerId) { snippet in
                if text.isEmpty {
                    text = snippet
                } else {
                    text += (text.hasSuffix("\n") ? "" : "\n") + snippet
                }
            }
        }
        .onDisappear {
            keys.unregisterUpload(owner: uploadOwnerId)
            keys.unregisterComposeInsertion(owner: uploadOwnerId)
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

    // MARK: Long-form mode

    /// Resizes the editor: drag up to grow (height persists).
    private var dragHandle: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragBaseHeight ?? editorHeight
                        dragBaseHeight = base
                        editorHeight = min(max(80, base - value.translation.height), 600)
                    }
                    .onEnded { _ in
                        dragBaseHeight = nil
                    })
            .help("Drag to resize")
    }

    @ViewBuilder
    private var expandedEditor: some View {
        Group {
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
            } else {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden)
                        .font(.body)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .focused($messageFocused)
                        .onKeyPress(.return, phases: .down) { press in
                            // Long-form: Return newlines, ⇧Return sends.
                            if press.modifiers.contains(.shift) {
                                send()
                                return .handled
                            }
                            if !suggestions.isEmpty {
                                return acceptSelection()
                            }
                            return .ignored
                        }
                        .onKeyPress(.upArrow) { moveSelection(-1) }
                        .onKeyPress(.downArrow) { moveSelection(1) }
                        .onKeyPress(.tab) { acceptSelection() }
                        .onKeyPress(.escape) {
                            guard !suggestions.isEmpty else { return .ignored }
                            suggestions = []
                            return .handled
                        }
                }
            }
        }
        .frame(height: editorHeight)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Server-rendered preview (POST /messages/render): exactly what will
    /// send, through the production renderer.
    private func togglePreview() {
        showPreview.toggle()
        previewTask?.cancel()
        guard showPreview else { return }
        previewContent = nil
        let content = text
        let connection = store.connection
        previewTask = Task {
            let html = (try? await connection.renderMessage(content: content)) ?? ""
            guard !Task.isCancelled else { return }
            previewContent = ContentParser.parse(
                html: html.isEmpty
                    ? "<p><em>Preview unavailable (offline?)</em></p>" : html)
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

        let item = UploadItem(filename: filename)
        uploads.append(item)
        let itemId = item.id
        let connection = store.connection
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        let mimeType = UTType(filenameExtension: fileExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let updateProgress: @MainActor (Double) -> Void = { fraction in
            if let index = uploads.firstIndex(where: { $0.id == itemId }) {
                uploads[index].progress = fraction
            }
        }
        Task {
            defer { uploads.removeAll { $0.id == itemId } }
            guard let path = try? await connection.uploadFile(
                data, filename: filename, mimeType: mimeType,
                progress: { fraction in
                    Task { @MainActor in updateProgress(fraction) }
                })
            else { return }
            // Any spaces the server kept in the path would break the
            // markdown link (and the server's inline preview of it).
            let linkPath = path.replacingOccurrences(of: " ", with: "%20")
            // Images and audio embed with a leading "!" (what the web app
            // inserts for supported media); other files stay plain links.
            let embed = mimeType.hasPrefix("image/") || mimeType.hasPrefix("audio/")
            let reference = "\(embed ? "!" : "")[\(filename)](\(linkPath))"
            text = text.isEmpty ? reference : "\(text)\n\(reference)"
        }
    }

    /// SF Symbol for an upload chip, by file extension.
    private static func fileIcon(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg":
            "photo"
        case "mov", "mp4", "m4v", "avi", "mkv", "webm":
            "film"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            "waveform"
        case "pdf":
            "doc.richtext"
        case "zip", "gz", "tar", "7z", "rar", "dmg":
            "doc.zipper"
        case "txt", "md", "csv", "json", "log", "swift", "py", "js":
            "doc.text"
        default:
            "doc"
        }
    }

    // MARK: Send

    private func send() {
        guard suggestions.isEmpty else { return }
        guard canSend, let destination else { return }
        showPreview = false
        previewTask?.cancel()
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

/// A small determinate ring for one upload's progress.
private struct UploadProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            Circle()
                // A sliver even at 0 so the ring reads as progress, not decoration.
                .trim(from: 0, to: max(progress, 0.04))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .animation(.linear(duration: 0.2), value: progress)
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
