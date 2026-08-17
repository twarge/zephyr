import SwiftUI
import TipKit
import ZulipAPI
import ZulipContent
import ZulipModel
#if canImport(AppKit)
import AppKit
#endif

/// Zulip-web-style keyboard navigation, shared by both platforms: a selected
/// message in the transcript (j/k/arrows), action keys on the selection, and
/// global navigation keys. One router per account window.
///
/// Input routing differs by platform: macOS uses an `NSEvent` local monitor
/// (guarded so text fields, sheets, and sidebar-list arrows are never
/// intercepted); iOS feeds hardware-keyboard presses in via `onKeyPress` on
/// the focused detail pane.
///
/// The keymap (matching the web/desktop app where the concept exists):
///   j / ↓, k / ↑     next / previous message
///   ⇧↓ / ⇧↑          extend the selection as a range from its anchor
///                    (⇧-click ranges to the clicked message, ⌘-click
///                    toggles membership; single-message actions target
///                    the anchor, copy/share/export take the whole set)
///   → / ←            next / previous attachment of the selected message
///                    (← at the first attachment returns to the message;
///                    at message level it focuses the sidebar)
///   ⇧→ / ⇧←          extend the attachment selection as a list range
///                    (⌘-click toggles, ⇧-click ranges; within one
///                    message only — Space/share/export take the set)
///   Space            Quick Look the selected attachment, or all of the
///                    selected message's attachments
///   r / Return       reply (focus compose; cross-channel feeds jump first)
///   e                edit selected message (own messages)
///   +                react 👍            *   star / unstar
///   s / Shift-S      go to topic / channel of selected message
///   a                combined feed
///   n / p            next unread topic / next unread DM conversation
///   /                search               c   compose here
///   x                new direct message   ?   this help
///   Esc              clear selection / close help
@MainActor
@Observable
final class KeyboardRouter {
    weak var store: PerAccountStore?
    weak var activeFeed: MessageListModel?

    /// Anchor of the message selection — the target of every single-message
    /// action (reply, edit, react, attachment traversal). Writes through
    /// here collapse any extended selection back to just this message,
    /// which is exactly what plain clicks, j/k moves, and clears mean.
    var selectedMessageId: Int? {
        get { anchorMessageId }
        set {
            anchorMessageId = newValue
            selectedMessageIds = newValue.map { [$0] } ?? []
            extensionTip = nil
        }
    }

    private var anchorMessageId: Int?
    /// The full selection (⌘-click toggles, ⇧-click/⇧↓/⇧↑ ranges); always
    /// contains the anchor when non-empty. Batch actions (copy, share,
    /// export) consume this; everything else targets the anchor.
    private(set) var selectedMessageIds: Set<Int> = []
    /// The moving end of a ⇧ range extension (the feed reveals it on
    /// change, the way it reveals the anchor).
    private(set) var extensionTip: Int?

    /// ⌘-click: toggle membership; the toggled message becomes the anchor
    /// (removing the anchor promotes its nearest remaining neighbor).
    func toggleMessageSelection(_ id: Int) {
        clearMediaSelection()
        extensionTip = nil
        if selectedMessageIds.contains(id) {
            selectedMessageIds.remove(id)
            if selectedMessageIds.isEmpty {
                anchorMessageId = nil
            } else if anchorMessageId == id {
                // Message ids are chronological — nearest id, nearest row.
                anchorMessageId = selectedMessageIds.min {
                    abs($0 - id) < abs($1 - id)
                }
            }
        } else {
            selectedMessageIds.insert(id)
            anchorMessageId = id
        }
    }

    /// ⇧-click: the selection becomes the transcript range from the anchor
    /// to the clicked message (replacing any scattered ⌘ picks, like list
    /// views do). Without an anchor it's a plain selection.
    func extendMessageSelection(to id: Int) {
        clearMediaSelection()
        guard let anchor = anchorMessageId,
              let ids = activeFeed?.messages.map(\.id),
              let anchorIndex = ids.firstIndex(of: anchor),
              let targetIndex = ids.firstIndex(of: id)
        else {
            selectedMessageId = id
            return
        }
        selectedMessageIds = Set(
            anchorIndex <= targetIndex
                ? ids[anchorIndex...targetIndex] : ids[targetIndex...anchorIndex])
        extensionTip = id
    }

    /// ⇧↓/⇧↑: steps the range's tip; the selection is always the
    /// anchor-to-tip transcript range (stepping back across the anchor
    /// shrinks, then grows the other side).
    private func extendSelection(_ delta: Int) -> Bool {
        guard let feed = activeFeed, !feed.messages.isEmpty else { return false }
        let ids = feed.messages.map(\.id)
        guard let anchor = anchorMessageId,
              let anchorIndex = ids.firstIndex(of: anchor)
        else { return moveSelection(delta) }
        clearMediaSelection()
        let tipIndex = extensionTip.flatMap { ids.firstIndex(of: $0) } ?? anchorIndex
        let newIndex = min(max(tipIndex + delta, 0), ids.count - 1)
        extensionTip = ids[newIndex]
        selectedMessageIds = Set(
            anchorIndex <= newIndex
                ? ids[anchorIndex...newIndex] : ids[newIndex...anchorIndex])
        if newIndex == 0 && delta < 0 {
            Task { await feed.fetchOlder() }
        }
        return true
    }

    /// Drops extended members (e.g. ones that left the feed window),
    /// keeping the anchor selected.
    func collapseSelectionToAnchor() {
        selectedMessageId = anchorMessageId
    }

    /// The selection in transcript order — what batch copy/share/export
    /// iterate. Falls back to ascending id order (chronological in Zulip)
    /// for members outside the active feed's window.
    func orderedSelection() -> [Int] {
        guard !selectedMessageIds.isEmpty else {
            return anchorMessageId.map { [$0] } ?? []
        }
        if let ids = activeFeed?.messages.map(\.id) {
            let ordered = ids.filter(selectedMessageIds.contains)
            if ordered.count == selectedMessageIds.count { return ordered }
        }
        return selectedMessageIds.sorted()
    }

    func selectedMessages() -> [Message] {
        orderedSelection().compactMap { id in
            store?.messages[id] ?? activeFeed?.messages.first { $0.id == id }
        }
    }
    #if canImport(AppKit)
    /// The window this router serves — with multiple main windows open,
    /// each router handles keys only while its own window is key.
    @ObservationIgnored weak var hostWindow: NSWindow?
    #endif
    /// Set to a message id to ask its row to enter edit mode; the row clears it.
    var editRequestId: Int?
    /// A menu-bar action aimed at the selected message; the owning row
    /// consumes it (same pattern as editRequestId).
    var messageActionRequest: MessageActionRequest?
    /// iOS counterpart of the macOS first-responder text check: single-key
    /// navigation must stay quiet while any text input in the detail focus
    /// scope is active (compose, topic field, message editor).
    var composeInputFocused = false
    var editingMessage = false
    var textInputActive: Bool { composeInputFocused || editingMessage }

    /// Pane handoff: ← from the messages pane focuses the sidebar list
    /// (native arrow navigation takes over); → returns to messages.
    /// Registered per platform (SidebarView / MainSplitView).
    var focusSidebar: (() -> Void)?
    var focusMessages: (() -> Void)?
    /// Set by "Mark as Unread from Here": suppresses visibility-based read
    /// marking so the freshly unread messages don't immediately re-mark;
    /// cleared when a feed (re)appears.
    var readMarkingPaused = false
    /// Message-link (/near/) navigation: the conversation to open anchored
    /// at a message, and the message to flash once visible.
    @ObservationIgnored var pendingNear: (key: ConversationKey, messageId: Int)?
    var highlightMessageId: Int?
    var showHelp = false

    /// Selected media (image/PDF) in the transcript, both platforms. Router
    /// state rather than FocusState: focus dies when the row re-renders
    /// (message selection lands a beat after the click); plain state
    /// survives. Space routes through the key monitor (macOS) or the detail
    /// pane's key handler (iOS) to the registered Quick Look action.
    ///
    /// Anchor of the attachment selection; writes collapse any extended
    /// attachment selection, mirroring `selectedMessageId`.
    var selectedMediaId: String? {
        get { anchorMediaId }
        set {
            anchorMediaId = newValue
            selectedMediaIds = newValue.map { [$0] } ?? []
            mediaExtensionTip = nil
            selectedMediaQuickLook = nil
        }
    }

    private var anchorMediaId: String?
    /// The full attachment selection (⌘-click toggles, ⇧-click/⇧→/⇧←
    /// range) — scoped to the anchor message's attachments, never across
    /// messages. Space, share, and export consume it.
    private(set) var selectedMediaIds: Set<String> = []
    private var mediaExtensionTip: String?
    @ObservationIgnored private var selectedMediaQuickLook: (() -> Void)?

    /// Registered by the visible feed: a message's attachments in render
    /// order (←/→ traversal), and a Quick Look session over a set of them.
    @ObservationIgnored var attachmentList: ((Int) -> [MessageAttachment])?
    @ObservationIgnored var presentAttachments: (([MessageAttachment], Int) -> Void)?

    /// Registered by the compose bar and sidebar: selecting media blurs text
    /// inputs, so Space reaches the monitor instead of typing a space.
    @ObservationIgnored var blurCompose: (() -> Void)?
    @ObservationIgnored var blurSearch: (() -> Void)?

    /// True while the tap that selected media is still dispatching. A tap
    /// on an attachment fires the row's simultaneous tap too, and the
    /// callback order is unspecified — the row checks this to leave the
    /// same tap's media selection alone (any other row tap clears a stale
    /// one). Both callbacks run synchronously within the event's delivery,
    /// so a reset enqueued on the main actor lands after them.
    @ObservationIgnored private(set) var mediaTapInFlight = false

    func selectMedia(_ id: String, quickLook: @escaping () -> Void) {
        #if canImport(AppKit)
        // ⌘/⇧-clicks are multi-select gestures, arbitrated against the
        // row's simultaneous tap — never a plain attachment selection.
        if let flags = NSApp.currentEvent?.modifierFlags {
            let mods = flags.intersection([.command, .shift])
            if !mods.isEmpty {
                reportModifierClick(media: id, command: mods.contains(.command))
                return
            }
        }
        #endif
        selectedMediaId = id
        selectedMediaQuickLook = quickLook
        mediaTapInFlight = true
        Task { mediaTapInFlight = false }
        QuickLookNavigationTip.imageSelected.sendDonation()
        blurCompose?()
        blurSearch?()
    }

    /// Keyboard-side selection: no view-registered action — Space routes
    /// through `presentAttachments` instead (the setter drops any stale
    /// click-registered one).
    private func selectAttachment(_ attachment: MessageAttachment) {
        selectedMediaId = attachment.mediaId
    }

    func clearMediaSelection() {
        selectedMediaId = nil
    }

    // MARK: Modifier-click arbitration

    /// A ⌘/⇧-click on an attachment fires the row's simultaneous tap too,
    /// in unspecified order — and unlike plain clicks, toggles aren't
    /// order-independent. Both handlers report what they saw; a single
    /// resolver scheduled after the event acts once, with complete
    /// information: attachment reports win over their row's.
    @ObservationIgnored private var pendingRowClick: (id: Int, command: Bool)?
    @ObservationIgnored private var pendingMediaClick: (id: String, command: Bool)?
    @ObservationIgnored private var modifierClickScheduled = false

    func reportModifierClick(message id: Int, command: Bool) {
        pendingRowClick = (id, command)
        scheduleModifierClickResolution()
    }

    func reportModifierClick(media id: String, command: Bool) {
        pendingMediaClick = (id, command)
        scheduleModifierClickResolution()
    }

    private func scheduleModifierClickResolution() {
        guard !modifierClickScheduled else { return }
        modifierClickScheduled = true
        Task { resolveModifierClick() }
    }

    private func resolveModifierClick() {
        modifierClickScheduled = false
        let media = pendingMediaClick
        let row = pendingRowClick
        pendingMediaClick = nil
        pendingRowClick = nil
        if let media {
            // Attachment multi-select lives within one message: a click
            // in a different message restarts the selection there (the
            // old message's attachment picks must not merge in).
            if let messageId = row?.id, selectedMessageId != messageId {
                selectedMessageId = messageId
                clearMediaSelection()
            }
            if media.command {
                toggleAttachmentSelection(media.id)
            } else {
                extendAttachmentSelection(to: media.id)
            }
        } else if let row {
            if row.command {
                toggleMessageSelection(row.id)
            } else {
                extendMessageSelection(to: row.id)
            }
        }
    }

    // MARK: Attachment multi-selection

    /// ⌘-click: toggle membership; the toggled attachment anchors
    /// (removing the anchor promotes its nearest list neighbor).
    private func toggleAttachmentSelection(_ id: String) {
        mediaExtensionTip = nil
        selectedMediaQuickLook = nil
        if selectedMediaIds.contains(id) {
            selectedMediaIds.remove(id)
            if selectedMediaIds.isEmpty {
                anchorMediaId = nil
            } else if anchorMediaId == id {
                let list = selectedMessageId.flatMap { attachmentList?($0) } ?? []
                let removed = list.firstIndex { $0.mediaId == id }
                anchorMediaId = selectedMediaIds.min { a, b in
                    guard let removed,
                          let ai = list.firstIndex(where: { $0.mediaId == a }),
                          let bi = list.firstIndex(where: { $0.mediaId == b })
                    else { return a < b }
                    return abs(ai - removed) < abs(bi - removed)
                }
            }
        } else {
            selectedMediaIds.insert(id)
            anchorMediaId = id
        }
    }

    /// ⇧-click: the attachment selection becomes the list range from the
    /// anchor to the clicked attachment; without an anchor, a plain
    /// selection.
    private func extendAttachmentSelection(to id: String) {
        guard let anchor = anchorMediaId,
              let messageId = selectedMessageId,
              let list = attachmentList?(messageId),
              let anchorIndex = list.firstIndex(where: { $0.mediaId == anchor }),
              let targetIndex = list.firstIndex(where: { $0.mediaId == id })
        else {
            selectedMediaId = id
            return
        }
        let range = anchorIndex <= targetIndex
            ? anchorIndex...targetIndex : targetIndex...anchorIndex
        selectedMediaIds = Set(range.map { list[$0].mediaId })
        mediaExtensionTip = id
        selectedMediaQuickLook = nil
    }

    /// ⇧→/⇧←: steps the attachment range's tip within the anchor
    /// message's list (entering plain selection when nothing is selected).
    private func extendAttachmentSelection(_ delta: Int) -> Bool {
        guard let messageId = selectedMessageId,
              let list = attachmentList?(messageId), !list.isEmpty
        else { return false }
        guard let anchor = anchorMediaId,
              let anchorIndex = list.firstIndex(where: { $0.mediaId == anchor })
        else { return moveAttachmentSelection(delta) }
        let tipIndex = mediaExtensionTip.flatMap { tip in
            list.firstIndex { $0.mediaId == tip }
        } ?? anchorIndex
        let newIndex = min(max(tipIndex + delta, 0), list.count - 1)
        mediaExtensionTip = list[newIndex].mediaId
        let range = anchorIndex <= newIndex
            ? anchorIndex...newIndex : newIndex...anchorIndex
        selectedMediaIds = Set(range.map { list[$0].mediaId })
        selectedMediaQuickLook = nil
        return true
    }

    @ObservationIgnored var currentDestination: Destination?
    @ObservationIgnored var navigate: ((Destination) -> Void)?
    @ObservationIgnored var focusCompose: (() -> Void)?
    /// Channel-mode compose only: replying to a message steers the topic
    /// field to that message's topic.
    @ObservationIgnored var setComposeTopic: ((String) -> Void)?
    @ObservationIgnored var focusSearch: (() -> Void)?
    @ObservationIgnored var newConversation: (() -> Void)?
    @ObservationIgnored private var monitor: Any?

    /// File-drop routing: the visible compose bar registers here so a drop
    /// anywhere in the conversation area uploads into it. Ownership-tokened —
    /// a disappearing compose must not unregister its successor.
    @ObservationIgnored private(set) var uploadFiles: (([URL]) -> Void)?
    @ObservationIgnored private var uploadOwner: UUID?

    func registerUpload(owner: UUID, _ handler: @escaping ([URL]) -> Void) {
        uploadOwner = owner
        uploadFiles = handler
    }

    func unregisterUpload(owner: UUID) {
        guard uploadOwner == owner else { return }
        uploadOwner = nil
        uploadFiles = nil
    }

    /// Text insertion into the visible compose bar (quote-and-reply);
    /// ownership-tokened like uploads.
    @ObservationIgnored private(set) var insertIntoCompose: ((String) -> Void)?
    @ObservationIgnored private var composeInsertionOwner: UUID?

    func registerComposeInsertion(owner: UUID, _ handler: @escaping (String) -> Void) {
        composeInsertionOwner = owner
        insertIntoCompose = handler
    }

    func unregisterComposeInsertion(owner: UUID) {
        guard composeInsertionOwner == owner else { return }
        composeInsertionOwner = nil
        insertIntoCompose = nil
    }

    /// Format-menu actions (⌘B/⌘I/⌘K) applied by the visible compose bar.
    @ObservationIgnored var applyFormat: ((ComposeFormat) -> Void)?

    /// The selected message (also the share target on iOS).
    var selectedMessage: Message? {
        guard let selectedMessageId else { return nil }
        return store?.messages[selectedMessageId]
            ?? activeFeed?.messages.first { $0.id == selectedMessageId }
    }

    /// The selected attachments in list order, resolved through the feed's
    /// registered list (empty when none are selected or no feed is
    /// registered) — the share/export set.
    func selectedAttachments() -> [MessageAttachment] {
        guard !selectedMediaIds.isEmpty, let messageId = selectedMessageId,
              let list = attachmentList?(messageId)
        else { return [] }
        return list.filter { selectedMediaIds.contains($0.mediaId) }
    }

    // MARK: Keymap

    func handleCharacter(_ character: Character) -> Bool {
        switch character {
        case "j": return moveSelection(1)
        case "k": return moveSelection(-1)
        case "r": return reply()
        case "e": return editSelected()
        case "+": return reactToSelected()
        case "*": return starSelected()
        case "s": return narrowToTopic()
        case "S": return narrowToChannel()
        case "a":
            navigate?(.combinedFeed)
            return true
        case "t":
            navigate?(.recentConversations)
            return true
        case "n": return nextUnread(dms: false)
        case "p": return nextUnread(dms: true)
        case "/":
            guard let focusSearch else { return false }
            focusSearch()
            return true
        case "c":
            guard let focusCompose else { return false }
            focusCompose()
            return true
        case "x":
            guard let newConversation else { return false }
            newConversation()
            return true
        case "?":
            showHelp = true
            return true
        default:
            return false
        }
    }

    func handleUpArrow() -> Bool { moveSelection(-1) }
    func handleDownArrow() -> Bool { moveSelection(1) }
    func handleReturn() -> Bool { reply() }

    /// → enters/advances the selected message's attachments.
    func handleRightArrow() -> Bool {
        guard selectedMessageId != nil else { return false }
        return moveAttachmentSelection(1)
    }

    /// ← steps back through attachments (first attachment → back to the
    /// message); with none selected it keeps its pane-handoff meaning.
    func handleLeftArrow() -> Bool {
        if selectedMediaId != nil {
            if !moveAttachmentSelection(-1) {
                clearMediaSelection()
            }
            return true
        }
        focusSidebar?()
        return true
    }

    func handleEscape() -> Bool {
        if showHelp {
            showHelp = false
            return true
        }
        if selectedMediaId != nil {
            clearMediaSelection()
            return true
        }
        if selectedMessageId != nil {
            selectedMessageId = nil
            return true
        }
        return false
    }

    func handleSpace() -> Bool {
        // Click-registered action first (single selections only): a
        // clicked image keeps its transcript-wide session, chips their
        // view-local preview.
        if selectedMediaIds.count <= 1, selectedMediaId != nil,
           let selectedMediaQuickLook {
            selectedMediaQuickLook()
            return true
        }
        // Keyboard-selected attachment(s), or the message itself: one
        // Quick Look session — over the multi-selection when there is
        // one, else the whole message — focused on the anchor.
        guard let messageId = selectedMessageId,
              let list = attachmentList?(messageId), !list.isEmpty,
              let presentAttachments
        else { return false }
        let scope = selectedMediaIds.count > 1
            ? list.filter { selectedMediaIds.contains($0.mediaId) } : list
        let focus = selectedMediaId.flatMap { id in
            scope.firstIndex { $0.mediaId == id }
        } ?? 0
        presentAttachments(scope, focus)
        return true
    }

    // MARK: Selection

    private func moveSelection(_ delta: Int) -> Bool {
        guard let feed = activeFeed, !feed.messages.isEmpty else { return false }
        let ids = feed.messages.map(\.id)
        let index: Int
        if let current = selectedMessageId, let position = ids.firstIndex(of: current) {
            index = min(max(position + delta, 0), ids.count - 1)
        } else {
            index = ids.count - 1  // First press selects the newest message.
        }
        selectedMessageId = ids[index]
        clearMediaSelection()
        if index == 0 && delta < 0 {
            Task { await feed.fetchOlder() }
        }
        return true
    }

    /// Steps the attachment selection within the selected message: +1 from
    /// message level enters at the first attachment, −1 past the first
    /// returns to message level; the far end clamps (the key is consumed).
    private func moveAttachmentSelection(_ delta: Int) -> Bool {
        guard let messageId = selectedMessageId,
              let list = attachmentList?(messageId), !list.isEmpty
        else { return false }
        guard let current = selectedMediaId.flatMap({ id in
            list.firstIndex { $0.mediaId == id }
        }) else {
            guard delta > 0 else { return false }
            selectAttachment(list[0])
            return true
        }
        let target = current + delta
        if target < 0 {
            clearMediaSelection()
        } else if target < list.count {
            selectAttachment(list[target])
        }
        return true
    }

    // MARK: Actions on the selection

    private func reply() -> Bool {
        guard let feed = activeFeed else { return false }
        switch feed.narrow {
        case .topic, .dm:
            guard let focusCompose else { return false }
            focusCompose()
            return true
        case .channel:
            // Channel feed: compose right here — the topic field follows
            // the replied-to message.
            guard let focusCompose else { return false }
            if let subject = selectedMessage?.subject {
                setComposeTopic?(subject)
            }
            focusCompose()
            return true
        default:
            // Cross-conversation feeds: jump to the selected message's
            // conversation, then focus its compose box once it's on screen.
            guard let store, let message = selectedMessage,
                  let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId)
            else { return false }
            navigate?(.conversation(key))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.focusCompose?()
            }
            return true
        }
    }

    private func editSelected() -> Bool {
        guard let message = selectedMessage, message.senderId == store?.selfUserId
        else { return false }
        editRequestId = message.id
        return true
    }

    private func reactToSelected() -> Bool {
        guard let store, let message = selectedMessage else { return false }
        store.toggleReaction(
            message: message, emojiName: "+1", emojiCode: "1f44d",
            reactionType: "unicode_emoji")
        return true
    }

    private func starSelected() -> Bool {
        guard let store, let message = selectedMessage else { return false }
        let starred = (message.flags ?? []).contains("starred")
        store.setStarred(!starred, messageId: message.id)
        return true
    }

    private func narrowToTopic() -> Bool {
        guard let store, let message = selectedMessage,
              let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId)
        else { return false }
        navigate?(.conversation(key))
        return true
    }

    private func narrowToChannel() -> Bool {
        guard let message = selectedMessage, let streamId = message.streamId
        else { return false }
        navigate?(.channel(streamId: streamId))
        return true
    }

    // MARK: Unread navigation

    private func nextUnread(dms: Bool) -> Bool {
        guard let store else { return false }
        let unread = store.conversations.conversations.map(\.key).filter { key in
            let isDm = if case .dm = key { true } else { false }
            guard isDm == dms else { return false }
            return !(store.unreads.unreadIds[key]?.isEmpty ?? true)
        }
        guard !unread.isEmpty else { return false }
        var target = unread[0]
        if case .conversation(let current) = currentDestination,
           let index = unread.firstIndex(of: current) {
            target = unread[(index + 1) % unread.count]
        }
        navigate?(.conversation(target))
        return true
    }

    // MARK: macOS event monitor

    #if canImport(AppKit)
    func installMonitor() {
        guard monitor == nil else { return }
        monitor = Self.makeMonitor(router: self)
    }

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// nonisolated so the AppKit handler closure infers nonisolated (the
    /// monitor fires on the main thread; assumeIsolated hops back safely).
    private nonisolated static func makeMonitor(router: KeyboardRouter) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags
                .intersection([.command, .option, .control])
            let keyCode = event.keyCode
            let character = event.charactersIgnoringModifiers?.first
            // ⌘V with a copied message pastes its quote block into
            // compose; with media on the pasteboard it uploads into the
            // compose bar; plain-text pastes stay native.
            if modifiers == .command, character == "v" {
                let consumed = MainActor.assumeIsolated {
                    router.handlePasteQuote() || router.handlePasteMedia()
                }
                return consumed ? nil : event
            }
            // ⌘C with a message selected copies it dual-faced (quote block
            // for compose, sender-and-text for everything else); native
            // copy wins for any live text selection.
            if modifiers == .command, character == "c" {
                let consumed = MainActor.assumeIsolated {
                    router.handleCopyMessage()
                }
                return consumed ? nil : event
            }
            guard modifiers.isEmpty else { return event }
            let shift = event.modifierFlags.contains(.shift)
            let consumed = MainActor.assumeIsolated {
                router.handleMonitorKey(
                    keyCode: keyCode, character: character, shift: shift)
            }
            return consumed ? nil : event
        }
    }

    /// ⌘C with messages selected: writes the pasteboard dual-faced — the
    /// Zulip quote blocks (chained, transcript order) for in-app compose
    /// pastes, stacked sender-and-text lines for every other target.
    /// Native copy wins while a text input is focused or message text is
    /// drag-selected.
    private func handleCopyMessage() -> Bool {
        guard let keyWindow = NSApp.keyWindow, keyWindow == hostWindow
        else { return false }
        if let responder = keyWindow.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }
        guard let store else { return false }
        let messages = selectedMessages()
        guard !messages.isEmpty else { return false }
        if Platform.currentTextSelection() != nil { return false }
        Task {
            var quotes: [String] = []
            var plains: [String] = []
            for message in messages {
                let raw = await store.fetchRawContent(message.id)
                    ?? ContentParser.parse(html: message.content).plainText
                quotes.append(messageQuoteBlock(message, raw: raw, store: store))
                plains.append(messageCopyText(message))
            }
            // Each quote block ends in a blank line, so plain
            // concatenation reads as separate quotes in compose.
            Platform.copyMessage(
                quote: quotes.joined(),
                plainText: plains.joined(separator: "\n"))
        }
        return true
    }

    /// A copied message pastes into the compose draft as its quote block;
    /// any other focused text input (search, message editor) keeps the
    /// native paste, which lands the plain-text face.
    private func handlePasteQuote() -> Bool {
        guard let keyWindow = NSApp.keyWindow, keyWindow == hostWindow,
              let quote = Platform.pasteboardMessageQuote(),
              let insertIntoCompose
        else { return false }
        if let responder = keyWindow.firstResponder,
           responder is NSTextView || responder is NSTextField,
           !composeInputFocused {
            return false
        }
        insertIntoCompose(quote)
        focusCompose?()
        return true
    }

    /// Pasted files upload directly; pasted image *data* (screenshots,
    /// browser images) lands in a temp PNG first, then rides the same
    /// upload-and-link path as a drop.
    private func handlePasteMedia() -> Bool {
        guard let keyWindow = NSApp.keyWindow, keyWindow == hostWindow,
              let uploadFiles else { return false }
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            uploadFiles(urls)
            return true
        }
        guard let pngData = MediaStaging.pngData(from: pasteboard),
              let fileURL = MediaStaging.stage(pngData, extension: "png", prefix: "Pasted")
        else { return false }
        uploadFiles([fileURL])
        return true
    }

    private func handleMonitorKey(
        keyCode: UInt16, character: Character?, shift: Bool = false
    ) -> Bool {
        // Only for this router's own window (not other main windows,
        // Settings, sheets, or popovers).
        guard let keyWindow = NSApp.keyWindow, keyWindow == hostWindow
        else { return false }
        if let responder = keyWindow.firstResponder {
            // Never steal keys from text editing.
            if responder is NSTextView || responder is NSTextField { return false }
            if responder is NSTableView || responder is NSOutlineView {
                // The focused sidebar list owns ↑↓←/Return (native
                // navigation, live selection); → hands focus back to the
                // messages pane. Letters still reach the shortcuts.
                switch keyCode {
                case 124:
                    focusMessages?()
                    return true
                case 125, 126, 123, 36, 76, 49:
                    return false
                default:
                    break
                }
            }
        }
        switch keyCode {
        case 123:
            // ← steps back through attachments, or hands focus to the
            // sidebar from message level; ⇧← extends the attachment range.
            return shift ? extendAttachmentSelection(-1) : handleLeftArrow()
        case 124: return shift ? extendAttachmentSelection(1) : handleRightArrow()
        case 126: return shift ? extendSelection(-1) : handleUpArrow()
        case 125: return shift ? extendSelection(1) : handleDownArrow()
        case 36, 76: return handleReturn()
        case 53: return handleEscape()
        case 49: return handleSpace()
        default:
            guard let character else { return false }
            return handleCharacter(character)
        }
    }
    #endif
}

#if canImport(AppKit)
/// Reports the hosting NSWindow of the view it's placed behind.
struct WindowReader: NSViewRepresentable {
    var onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindow(nsView.window)
        }
    }
}
#endif

/// The `?` overlay: the keymap, in Zulip web's grouping.
/// A Message-menu action routed to the selected message's row.
struct MessageActionRequest: Equatable {
    enum Action: Equatable {
        case replyQuoting
        case copyReference
        case translate
        case moveToTopic
        case forward
        case markUnreadFromHere
    }

    var messageId: Int
    var action: Action
}

struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    /// Shared with HelpView's Keyboard Navigation section.
    static let sections: [(String, [(String, String)])] = [
        ("Navigation", [
            ("j  or  ↓", "Next message"),
            ("k  or  ↑", "Previous message"),
            ("⇧↓ / ⇧↑", "Extend message selection"),
            ("n", "Next unread topic"),
            ("p", "Next unread direct message"),
            ("a", "Combined feed"),
            ("t", "Recent conversations"),
            ("s", "Go to topic of selected message"),
            ("⇧S", "Go to channel of selected message"),
            ("→", "Next attachment of selected message"),
            ("←", "Previous attachment (or focus sidebar)"),
            ("⇧→ / ⇧←", "Extend attachment selection"),
            ("/", "Search"),
            ("Esc", "Clear selection"),
        ]),
        ("Composing", [
            ("r  or  Return", "Reply to selected message"),
            ("c", "Compose in this conversation"),
            ("x", "New direct message"),
            ("e", "Edit your selected message"),
            ("⌘Return", "Send"),
            ("⌘N", "New conversation"),
        ]),
        ("Actions", [
            ("+", "React 👍 to selected message"),
            ("*", "Star / unstar selected message"),
            ("Space", "Quick Look selected message's attachments"),
            ("⌘C", "Copy selection (pastes into compose as quotes)"),
            ("⌘1…⌘9", "Switch server"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.sections, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title)
                                .font(.headline)
                            ForEach(rows, id: \.1) { keys, action in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(keys)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 120, alignment: .leading)
                                    Text(action)
                                        .font(.callout)
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}
