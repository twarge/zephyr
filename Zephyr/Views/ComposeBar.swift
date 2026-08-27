import PhotosUI
import SwiftUI
import TipKit
import UniformTypeIdentifiers
import ZulipAPI
import ZulipContent
import ZulipModel

/// Per-conversation draft persistence: survives switching conversations AND
/// app relaunches (UserDefaults-backed), and syncs with the server's /drafts
/// API via DraftSyncEngine — drafts follow you across devices. Composing
/// needs no network; the text stays until sent or cleared.
@MainActor
@Observable
final class DraftStore {
    /// One draft: the text, when it was last edited locally, and the
    /// server-side draft id once synced.
    struct Entry: Codable, Equatable {
        var text: String
        var updatedAt: Date
        var serverId: Int?
    }

    static let shared = DraftStore()
    /// Observable so the sidebar's Drafts section tracks edits live.
    /// Keyed per account: server draft ids are realm-scoped.
    private(set) var byAccount: [UUID: [SendDestination: Entry]]
    /// Sync hook (set by AppModel): local edits notify the account's engine.
    @ObservationIgnored var onLocalChange: ((UUID, SendDestination, String) -> Void)?

    private static let key = "composeDrafts.v2"
    private static let legacyKey = "composeDrafts"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(
            [UUID: [SendDestination: Entry]].self, from: data) {
            byAccount = saved
        } else {
            byAccount = [:]
        }
    }

    /// One-time adoption of the pre-sync flat format, attached to the
    /// last-active account (the best available guess).
    func migrateLegacy(to accountId: UUID) {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyKey),
              let old = try? JSONDecoder().decode([SendDestination: String].self, from: data)
        else { return }
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
        for (destination, text) in old where !text.isEmpty {
            if byAccount[accountId]?[destination] == nil {
                byAccount[accountId, default: [:]][destination] =
                    Entry(text: text, updatedAt: .now)
            }
        }
        persist()
    }

    func draft(for destination: SendDestination, account: UUID) -> String {
        byAccount[account]?[destination]?.text ?? ""
    }

    func entries(account: UUID) -> [SendDestination: Entry] {
        byAccount[account] ?? [:]
    }

    func setDraft(_ text: String, for destination: SendDestination, account: UUID) {
        var entry = byAccount[account]?[destination] ?? Entry(text: "", updatedAt: .now)
        guard entry.text != text else { return }
        entry.text = text
        entry.updatedAt = .now
        if text.isEmpty && entry.serverId == nil {
            byAccount[account]?[destination] = nil
        } else {
            // Emptied-but-synced entries stay (invisible) until the engine
            // deletes the server draft and removes them.
            byAccount[account, default: [:]][destination] = entry
        }
        persist()
        onLocalChange?(account, destination, text)
    }

    // MARK: Sync-engine mutations (no local-change notification)

    func adoptServer(
        _ text: String, serverId: Int, updatedAt: Date,
        for destination: SendDestination, account: UUID
    ) {
        byAccount[account, default: [:]][destination] =
            Entry(text: text, updatedAt: updatedAt, serverId: serverId)
        persist()
    }

    func setServerId(_ id: Int?, for destination: SendDestination, account: UUID) {
        guard var entry = byAccount[account]?[destination] else { return }
        entry.serverId = id
        byAccount[account]?[destination] = entry
        persist()
    }

    func removeEntry(for destination: SendDestination, account: UUID) {
        byAccount[account]?[destination] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(byAccount) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// A server-interpreted slash command, offered when the message starts
/// with "/".
struct SlashCommand: Identifiable, Equatable {
    let name: String
    let icon: String
    let summary: String
    var id: String { name }

    static let all: [SlashCommand] = [
        SlashCommand(
            name: "poll", icon: "chart.bar.xaxis",
            summary: "Question on this line, options on the following lines"),
        SlashCommand(
            name: "todo", icon: "checklist",
            summary: "Title on this line, tasks on the following lines"),
        SlashCommand(
            name: "me", icon: "figure.wave",
            summary: "Action message — “/me is heading out”"),
    ]
}

private enum ComposeSuggestion: Identifiable {
    case mention(User)
    case emoji(EmojiEntry)
    case channel(Subscription)
    case topicLink(channel: String, topic: String)
    case command(SlashCommand)

    var id: String {
        switch self {
        case .mention(let user): "m\(user.userId)"
        case .emoji(let entry): "e\(entry.id)"
        case .channel(let sub): "c\(sub.streamId)"
        case .topicLink(let channel, let topic): "t\(channel)>\(topic)"
        case .command(let command): "s\(command.name)"
        }
    }

    /// The Zulip markdown inserted on accept.
    var completion: String {
        switch self {
        case .mention(let user): "@**\(user.fullName)** "
        case .emoji(let entry): ":\(entry.name): "
        case .channel(let sub): "#**\(sub.name)** "
        case .topicLink(let channel, let topic): "#**\(channel)>\(topic)** "
        case .command(let command): "/\(command.name) "
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
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var topicFieldFocused = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    /// When a modified return (⇧/⌃) last arrived: the field inserts
    /// that newline natively, and the Send-key detector leaves any
    /// newline appended within this moment alone.
    @State private var hardwareNewlineAt = Date.distantPast
    /// When the field last lost focus — opening the + menu blurs it, so
    /// "was focused" for the editor-mode toggle means focused now OR
    /// blurred moments ago.
    @State private var composeBlurredAt = Date.distantPast
    @State private var topicText = ""
    @State private var topicPrefill = ""
    @State private var suggestions: [ComposeSuggestion] = []
    @State private var selectedSuggestion = 0
    /// The trigger-to-caret span the accepted completion replaces.
    @State private var tokenRange: Range<String.Index>?
    /// The last (text, caret) pair scanned for a token: typing fires both
    /// the text and the selection onChange in one update, and the mention
    /// scan sorts the whole user list — scan each state once.
    @State private var lastTokenScan: (text: String, caret: String.Index)?
    /// Compact-field caret (the expanded editor has `editorSelection`), so
    /// autocomplete follows edits in the middle of the draft.
    @State private var fieldSelection: TextSelection?
    /// True while the current update cycle contains a text edit: only
    /// typing may open the card — pure caret travel would otherwise pop
    /// it over an uncompleted token and capture Return/arrows.
    @State private var textJustEdited = false
    private struct UploadItem: Identifiable, Equatable {
        let id = UUID()
        var filename: String
        var progress: Double = 0
    }
    @State private var uploads: [UploadItem] = []
    @State private var linkTopics: [Int: [ChannelTopic]] = [:]
    @State private var linkTopicsLoading: Set<Int> = []
    @FocusState private var messageFocused: Bool
    @Environment(KeyboardRouter.self) private var keys
    @Environment(AppModel.self) private var model
    @State private var uploadOwnerId = UUID()

    // Long-form mode: multi-line editor, drag-resizable, server-rendered
    // preview; Return newlines and ⇧Return sends.
    @AppStorage("composeExpanded") private var expanded = false
    @AppStorage("composeEditorHeight") private var editorHeight = 140.0
    @State private var dragBaseHeight: CGFloat?
    @State private var editorSelection: TextSelection?
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

    /// The channel being composed to, for the #channel ranking boost.
    private var currentStreamId: Int? {
        switch mode {
        case .channel(let streamId): streamId
        case .fixed(.topic(let streamId, _), _): streamId
        case .fixed(.dm, _): nil
        }
    }

    private var canSend: Bool {
        destination != nil
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Sending waits for uploads: their [name](url) references only
            // land in the text when the upload finishes.
            && uploads.isEmpty
    }

    // Messages-style bar metrics: the + button matches the field height;
    // the send arrow rides inside the field's trailing edge.
    #if os(macOS)
    private nonisolated static let plusButtonSize: CGFloat = 30
    private nonisolated static let plusIconSize: CGFloat = 13
    private nonisolated static let sendIconSize: CGFloat = 26
    #else
    private nonisolated static let plusButtonSize: CGFloat = 36
    private nonisolated static let plusIconSize: CGFloat = 16
    private nonisolated static let sendIconSize: CGFloat = 30
    #endif

    /// Compact rows center the + on the field's midline; the expanded
    /// editor bottom-aligns so the + stays at the bar's foot.
    private var rowAlignment: VerticalAlignment {
        expanded ? .bottom : .center
    }

    var body: some View {
        let _ = PerfLog.render("ComposeBar")
        VStack(alignment: .leading, spacing: 6) {
            if expanded {
                dragHandle
            }
            if !suggestions.isEmpty {
                suggestionsCard
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
                        .background(.regularMaterial, in: .capsule)
                    }
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: rowAlignment, spacing: 8) {
                #if os(macOS)
                if expanded {
                    macExpandedColumn
                } else {
                    plusMenu
                }
                #else
                plusMenu
                #endif
                VStack(alignment: .leading, spacing: 6) {
                    if case .channel(let streamId) = mode {
                        TopicAutocompleteField(
                            store: store, streamId: streamId, topic: $topicText,
                            plainStyle: true, dropUp: true,
                            onCommit: { messageFocused = true },
                            onFocusChange: { focused in
                                topicFieldFocused = focused
                                updateComposeInputFocus()
                            })
                            .frame(maxWidth: 260)
                    }
                    if expanded {
                        expandedEditor
                    } else {
                        compactField
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        #if os(macOS)
        .padding(.bottom, 8)
        #else
        .padding(.bottom, 4)
        #endif
        // No bar slab: the transcript flows beneath the floating pill
        // through the safe-area region, toolbar-style.
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                upload(fileURL: url, securityScoped: true)
            }
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoPickerItems,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos]))
        .mediaDropTarget(onText: { appendToDraft($0) }) { urls in
            for url in urls {
                upload(fileURL: url, securityScoped: false)
            }
        }
        .onAppear {
            if case .fixed(let destination, _) = mode {
                text = DraftStore.shared.draft(for: destination, account: store.accountId)
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
            // Format menu (⌘B/⌘I/⌘K) wraps the selection or appends.
            keys.applyFormat = { format in
                applyFormat(format)
            }
            // Quote-and-reply appends to the draft.
            keys.registerComposeInsertion(owner: uploadOwnerId) { snippet in
                appendToDraft(snippet)
            }
            // Replying to a message in the channel feed steers the topic
            // field to that message's topic (set as prefill, so the
            // bottom-of-feed follow behavior resumes afterward).
            if case .channel = mode {
                keys.setComposeTopic = { topic in
                    topicText = topic
                    topicPrefill = topic
                }
            }
            consumeShareSeed()
            syncTopicPrefill()
        }
        .onChange(of: keys.activeFeed?.messages.last?.id) {
            syncTopicPrefill()
        }
        .onDisappear {
            flushDraftSave()
            keys.composeInputFocused = false
            keys.unregisterUpload(owner: uploadOwnerId)
            keys.unregisterComposeInsertion(owner: uploadOwnerId)
            if case .channel = mode {
                keys.setComposeTopic = nil
            }
        }
        .onChange(of: messageFocused) { _, focused in
            if !focused {
                composeBlurredAt = .now
            }
            updateComposeInputFocus()
        }
        .onChange(of: photoPickerItems) {
            guard !photoPickerItems.isEmpty else { return }
            uploadPickedPhotos()
        }
        .onChange(of: text) {
            if case .fixed(let destination, _) = mode {
                scheduleDraftSave(for: destination)
            }
            if let destination {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.typingStopped(in: destination)
                } else {
                    store.typingActivity(in: destination)
                }
            }
            textJustEdited = true
            updateSuggestions()
            // The selection onChange for the same keystroke may run before
            // or after this one; the flag spans the whole cycle.
            Task { @MainActor in textJustEdited = false }
        }
        // Caret moves re-aim the token detector at the edit point (and a
        // range selection dismisses the card).
        .onChange(of: editorSelection) { updateSuggestions() }
        .onChange(of: fieldSelection) { updateSuggestions() }
    }

    // MARK: Messages-style bar pieces

    /// Messages' + button: attachments, preview, and the long-form
    /// editor toggle in one menu.
    private var plusMenu: some View {
        Menu {
            Button("Attach File…", systemImage: "paperclip") {
                showFileImporter = true
            }
            Button("Photo Library…", systemImage: "photo") {
                showPhotosPicker = true
            }
            Divider()
            Button(
                expanded ? "Compact Editor" : "Long-Form Editor",
                systemImage: expanded
                    ? "rectangle.compress.vertical" : "rectangle.expand.vertical"
            ) {
                toggleEditorMode()
            }
            if expanded {
                Button(
                    showPreview ? "Back to Editing" : "Preview",
                    systemImage: showPreview ? "eye.slash" : "eye"
                ) {
                    togglePreview()
                }
                .disabled(!showPreview
                    && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Self.plusIconSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.plusButtonSize, height: Self.plusButtonSize)
                .composeGlass(in: Circle())
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attachments and compose options")
        .popoverTip(LongFormComposeTip())
    }

    /// The input pill: no send arrow anywhere — Return IS Send (the
    /// iOS keyboard labels it so), and the expanded editor keeps its
    /// arrow where Return means newline.
    private var compactField: some View {
        TextField(placeholder, text: $text, selection: $fieldSelection, axis: .vertical)
            .textFieldStyle(.plain)
            .autocorrectionDisabled(false)
            .lineLimit(1...10)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .composeGlass(in: RoundedRectangle(cornerRadius: 17))
            #if !os(macOS)
            .submitLabel(.send)
            #endif
            .focused($messageFocused)
            .onSubmit { send() }
            .onKeyPress(.upArrow) { moveSelection(-1) }
            .onKeyPress(.downArrow) { moveSelection(1) }
            .onKeyPress(.tab) { acceptSelection() }
            // The general form, not onKeyPress(.return, …): the keyed
            // form only fires for UNMODIFIED Return, so ⇧/⌃Return never
            // reached the newline branch and fell through to the
            // Send-detector as a send.
            .onKeyPress(phases: .down) { press in
                guard press.key == .return else { return .ignored }
                // ⌘Return sends on both platforms (the compact field
                // has no send button to carry the shortcut).
                if press.modifiers.contains(.command) {
                    send()
                    return .handled
                }
                #if !os(macOS)
                if press.modifiers.contains(.shift)
                    || press.modifiers.contains(.control) {
                    // Mark it and let the field insert the newline
                    // natively; the detector below skips it.
                    hardwareNewlineAt = .now
                    return .ignored
                }
                #endif
                return acceptSelection()
            }
            .onKeyPress(.escape) {
                guard !suggestions.isEmpty else { return .ignored }
                suggestions = []
                return .handled
            }
            #if !os(macOS)
            // The software keyboard's Send key inserts a newline in
            // vertical-axis fields instead of firing onSubmit (SwiftUI):
            // one newline appended at the end IS the Send press — strip
            // it and send. Our own ⇧Return newline is flagged around.
            .onChange(of: text) { oldValue, newValue in
                if newValue.hasSuffix("\n"), newValue.dropLast() == oldValue {
                    // A modified return moments ago = intentional newline.
                    if Date.now.timeIntervalSince(hardwareNewlineAt) < 0.3 {
                        return
                    }
                    text = String(newValue.dropLast())
                    send()
                }
            }
            #endif
    }

    /// A focused field stays focused across the compact/long-form swap,
    /// and the caret carries over.
    private func toggleEditorMode() {
        LongFormComposeTip().invalidate(reason: .actionPerformed)
        let restoreFocus = messageFocused
            || Date.now.timeIntervalSince(composeBlurredAt) < 3
        withAnimation(.snappy) { expanded.toggle() }
        showPreview = false
        previewTask?.cancel()
        guard restoreFocus else { return }
        let entering = expanded
        Task { @MainActor in
            if entering {
                editorSelection = fieldSelection
                    ?? TextSelection(insertionPoint: text.endIndex)
            } else {
                fieldSelection = editorSelection
            }
            messageFocused = true
        }
    }

    #if os(macOS)
    /// Long-form macOS: the + gives way to a visible icon column —
    /// compact-editor toggle, preview, attach file, attach photo, send.
    private var macExpandedColumn: some View {
        VStack(spacing: 10) {
            Button {
                toggleEditorMode()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Compact message field")
            Button {
                togglePreview()
            } label: {
                Image(systemName: showPreview ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!showPreview
                && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(showPreview ? "Back to editing" : "Preview as it will send")
            Button {
                showFileImporter = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach files")
            Button {
                showPhotosPicker = true
            } label: {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach photos or videos")
            sendButton
        }
        .padding(.bottom, 4)
    }
    #endif

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: Self.sendIconSize))
                .foregroundStyle(
                    canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)
        .help(expanded
            ? "Send (⇧Return; Return for a new line)"
            : "Send (Return; ⌥Return for a new line)")
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
                // Tapping the preview returns to editing (links inside
                // still win their own taps).
                .contentShape(.rect)
                .onTapGesture {
                    togglePreview()
                    messageFocused = true
                }
                .help("Tap to edit")
            } else {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text, selection: $editorSelection)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled(false)
                        .font(.body)
                        .padding(.horizontal, 5)
                        // AppKit's text view has no built-in top inset
                        // (UIKit's has 8), so without this the caret floats
                        // above the placeholder's 8pt baseline.
                        #if os(macOS)
                        .padding(.top, 8)
                        .padding(.bottom, 1)
                        #else
                        .padding(.vertical, 1)
                        #endif
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
        .composeGlass(in: RoundedRectangle(cornerRadius: 17))
        // macOS's send lives in the expanded icon column instead.
        #if !os(macOS)
        .overlay(alignment: .bottomTrailing) {
            sendButton
                .padding(6)
        }
        #endif
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

    /// ⌘B/⌘I/⌘K: wraps the active input's selection in markdown, or
    /// appends an empty pair when nothing is selected.
    private func applyFormat(_ format: ComposeFormat) {
        let wrappers: (String, String)
        switch format {
        case .bold: wrappers = ("**", "**")
        case .italic: wrappers = ("*", "*")
        case .link: wrappers = ("[", "](url)")
        case .strikethrough: wrappers = ("~~", "~~")
        case .code: wrappers = ("`", "`")
        case .quote: wrappers = ("```quote\n", "\n```")
        case .spoiler: wrappers = ("```spoiler\n", "\n```")
        }
        let selection = expanded
            ? (showPreview ? nil : editorSelection) : fieldSelection
        if let selection, case .selection(let range) = selection.indices,
           !range.isEmpty, range.upperBound <= text.endIndex {
            let selected = String(text[range])
            text.replaceSubrange(range, with: wrappers.0 + selected + wrappers.1)
        } else {
            text += wrappers.0 + wrappers.1
        }
        messageFocused = true
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
        // Material, not tint: the card floats over scrolling content now.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
        case .command(let command):
            HStack(spacing: 6) {
                Image(systemName: command.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("/\(command.name)")
                    .font(.callout.weight(.medium))
                Text(command.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .topicLink(let channel, let topic):
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(channel) › \(TopicName.displayName(topic))")
                    .font(.callout)
                    .lineLimit(1)
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

    /// The active input's insertion point: nil when a nonempty range is
    /// selected (completing would eat it), end-of-text when the input has
    /// reported no selection yet. Clamped — the selection binding can
    /// briefly trail a programmatic text edit.
    private var caretIndex: String.Index? {
        guard let selection = expanded ? editorSelection : fieldSelection else {
            return text.endIndex
        }
        guard case .selection(let range) = selection.indices, range.isEmpty else {
            return nil
        }
        return min(range.lowerBound, text.endIndex)
    }

    private func updateSuggestions() {
        guard let caret = caretIndex else {
            suggestions = []
            tokenRange = nil
            return
        }
        // Typeahead is input-driven (as on the web): caret travel alone
        // never opens a closed card, only refreshes or closes an open one.
        // (Before the memo check: a gated pass must not swallow the text
        // edit's own scan when the selection onChange runs first.)
        if suggestions.isEmpty && !textJustEdited {
            tokenRange = nil
            return
        }
        if let last = lastTokenScan, last.text == text, last.caret == caret { return }
        lastTokenScan = (text, caret)
        guard let (token, triggerIndex) = ComposeAutocomplete.token(in: text, endingAt: caret)
        else {
            suggestions = []
            tokenRange = nil
            return
        }
        tokenRange = triggerIndex..<caret
        selectedSuggestion = 0
        switch token {
        case .mention(let query):
            // Whoever spoke in the open conversation ranks first (the
            // feed is ascending, so the last write per sender wins).
            var spoke: [Int: Int] = [:]
            for message in keys.activeFeed?.messages ?? [] {
                spoke[message.senderId] = message.id
            }
            let users = ComposeRanking.topUsers(
                store.users.values.lazy.filter { $0.isActive != false },
                matching: query, limit: 6,
                conversationRecency: spoke,
                dmRecency: store.conversations.dmRecencyByUser)
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
            let channels = ComposeRanking.topChannels(
                store.subscriptions.values, matching: query, limit: 6,
                currentStreamId: currentStreamId,
                recency: store.conversations.channelRecency)
            suggestions = channels.map { .channel($0) }
        case .command(let query):
            suggestions = SlashCommand.all
                .filter { query.isEmpty || $0.name.hasPrefix(query.lowercased()) }
                .map { .command($0) }
        case .channelTopic(let channelQuery, let topicQuery):
            // "#channel>topic": a link to a conversation elsewhere.
            let channels = store.subscriptions.values
            let channel = channels.first {
                $0.name.caseInsensitiveCompare(channelQuery) == .orderedSame
            } ?? ComposeRanking.topChannels(
                channels, matching: channelQuery, limit: 1,
                currentStreamId: currentStreamId,
                recency: store.conversations.channelRecency
            ).first
            guard let channel else {
                suggestions = []
                return
            }
            guard let topics = linkTopics[channel.streamId] else {
                loadLinkTopics(streamId: channel.streamId)
                suggestions = []
                return
            }
            suggestions = topics
                .map(\.name)
                .filter { !$0.isEmpty }
                .filter { topicQuery.isEmpty || $0.localizedCaseInsensitiveContains(topicQuery) }
                .prefix(6)
                .map { .topicLink(channel: channel.name, topic: $0) }
        }
    }

    /// Topic lists for link autocomplete, fetched once per channel and
    /// refreshed into the open suggestion card when they arrive.
    private func loadLinkTopics(streamId: Int) {
        guard !linkTopicsLoading.contains(streamId) else { return }
        linkTopicsLoading.insert(streamId)
        let connection = store.connection
        Task {
            linkTopics[streamId] = (try? await connection.getTopics(streamId: streamId)) ?? []
            // New data for an already-scanned state: rescan, and let the
            // arriving topics open the (empty-while-loading) card.
            lastTokenScan = nil
            textJustEdited = true
            updateSuggestions()
            textJustEdited = false
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
        guard let tokenRange, tokenRange.upperBound <= text.endIndex else {
            suggestions = []
            return
        }
        let completion = suggestion.completion
        let caretOffset = text.distance(from: text.startIndex, to: tokenRange.lowerBound)
            + completion.count
        text.replaceSubrange(tokenRange, with: completion)
        // The selection bindings pin the caret at its old offset through a
        // programmatic edit; move it past the completion.
        let caret = TextSelection(
            insertionPoint: text.index(text.startIndex, offsetBy: caretOffset))
        if expanded {
            editorSelection = caret
        } else {
            fieldSelection = caret
        }
        suggestions = []
        self.tokenRange = nil
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
        upload(data: data, filename: filename)
    }

    /// Library picks arrive as data (no file URL, no original name); each
    /// gets a stamped name with the type's extension.
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

    private func upload(data: Data, filename: String) {
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

    /// Quote-and-reply snippets and dropped links land on their own line
    /// below whatever's already drafted.
    private func appendToDraft(_ snippet: String) {
        if text.isEmpty {
            text = snippet
        } else {
            text += (text.hasSuffix("\n") ? "" : "\n") + snippet
        }
    }

    /// Share-extension items the user routed here: uploads start (the
    /// file data is read up front, so the inbox clears immediately) and
    /// shared text lands in the draft.
    private func consumeShareSeed() {
        guard let items = model.pendingComposeSeed, !items.isEmpty else { return }
        model.pendingComposeSeed = nil
        for item in items {
            for file in item.files {
                upload(fileURL: file, securityScoped: false)
            }
            if let shared = item.text, !shared.isEmpty {
                text += (text.isEmpty ? "" : "\n") + shared
            }
            ShareInbox.clear(item)
        }
        messageFocused = true
    }

    /// Channel mode: the topic field follows the conversation shown at
    /// the bottom of the feed, until the user types their own.
    private func syncTopicPrefill() {
        guard case .channel = mode else { return }
        guard let last = keys.activeFeed?.messages.last else { return }
        if topicText.isEmpty || topicText == topicPrefill {
            topicText = last.subject
            topicPrefill = last.subject
        }
    }

    // MARK: Send

    private func updateComposeInputFocus() {
        keys.composeInputFocused = messageFocused || topicFieldFocused
    }

    /// Draft writes coalesce to one per typing pause: the sidebar's Drafts
    /// section observes the DraftStore, so per-keystroke writes re-rendered
    /// the whole sidebar with every character.
    private func scheduleDraftSave(for destination: SendDestination) {
        draftSaveTask?.cancel()
        let text = text
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            DraftStore.shared.setDraft(text, for: destination, account: store.accountId)
        }
    }

    /// Writes any pending draft immediately (leaving the conversation).
    private func flushDraftSave() {
        guard draftSaveTask != nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = nil
        if case .fixed(let destination, _) = mode {
            DraftStore.shared.setDraft(text, for: destination, account: store.accountId)
        }
    }

    private func send() {
        guard suggestions.isEmpty else { return }
        guard canSend, let destination else { return }
        showPreview = false
        previewTask?.cancel()
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.send(content, to: destination)
        store.typingStopped(in: destination)
        // A pending debounced save of the pre-send text must not outlive
        // the clear.
        draftSaveTask?.cancel()
        draftSaveTask = nil
        text = ""
        DraftStore.shared.setDraft("", for: destination, account: store.accountId)
        // Keep composing: submit otherwise resigns focus (dropping the
        // keyboard on iOS) after every message.
        messageFocused = true
    }
}

extension View {
    /// The floating-bar glass treatment for compose chrome; material
    /// fallback pre-26.
    @ViewBuilder
    func composeGlass(in shape: some Shape) -> some View {
        #if os(visionOS)
        // No glassEffect on visionOS — material is the native look there.
        background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
        #endif
    }

    /// The HIG's 44pt minimum tap target on iOS; unchanged under a
    /// pointer on macOS. Nonisolated so nonisolated label builders
    /// (PhotosPicker's) can call it.
    @ViewBuilder
    nonisolated func touchTarget() -> some View {
        #if os(macOS)
        self
        #else
        frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
        #endif
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
