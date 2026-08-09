import SwiftUI
import TipKit
import ZulipAPI
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
    var selectedMessageId: Int?
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
    /// Set by "Mark as Unread from Here": suppresses visibility-based read
    /// marking so the freshly unread messages don't immediately re-mark;
    /// cleared when a feed (re)appears.
    var readMarkingPaused = false
    /// Message-link (/near/) navigation: the conversation to open anchored
    /// at a message, and the message to flash once visible.
    @ObservationIgnored var pendingNear: (key: ConversationKey, messageId: Int)?
    var highlightMessageId: Int?
    var showHelp = false

    /// Selected media (image/PDF) in the transcript. Router state rather than
    /// FocusState: focus dies when the row re-renders (message selection
    /// lands a beat after the click); plain state survives. Space routes
    /// through the key monitor to the registered Quick Look action.
    var selectedMediaId: String?
    @ObservationIgnored private var selectedMediaQuickLook: (() -> Void)?

    /// Registered by the compose bar and sidebar: selecting media blurs text
    /// inputs, so Space reaches the monitor instead of typing a space.
    @ObservationIgnored var blurCompose: (() -> Void)?
    @ObservationIgnored var blurSearch: (() -> Void)?

    func selectMedia(_ id: String, quickLook: @escaping () -> Void) {
        selectedMediaId = id
        selectedMediaQuickLook = quickLook
        QuickLookNavigationTip.imageSelected.sendDonation()
        blurCompose?()
        blurSearch?()
    }

    func clearMediaSelection() {
        selectedMediaId = nil
        selectedMediaQuickLook = nil
    }

    @ObservationIgnored var currentDestination: Destination?
    @ObservationIgnored var navigate: ((Destination) -> Void)?
    @ObservationIgnored var focusCompose: (() -> Void)?
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

    private var selectedMessage: Message? {
        guard let selectedMessageId else { return nil }
        return store?.messages[selectedMessageId]
            ?? activeFeed?.messages.first { $0.id == selectedMessageId }
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
        guard let selectedMediaQuickLook else { return false }
        selectedMediaQuickLook()
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

    // MARK: Actions on the selection

    private func reply() -> Bool {
        guard let feed = activeFeed else { return false }
        switch feed.narrow {
        case .topic, .dm:
            guard let focusCompose else { return false }
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
            // ⌘V with media on the pasteboard uploads into the compose bar;
            // plain-text pastes stay native.
            if modifiers == .command, character == "v" {
                let consumed = MainActor.assumeIsolated {
                    router.handlePasteMedia()
                }
                return consumed ? nil : event
            }
            guard modifiers.isEmpty else { return event }
            let consumed = MainActor.assumeIsolated {
                router.handleMonitorKey(keyCode: keyCode, character: character)
            }
            return consumed ? nil : event
        }
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
        let pngData = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
        guard let pngData else { return false }
        // No spaces: the filename ends up inside a markdown link URL, and
        // raw spaces break Zulip's link parsing (and the server preview).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZephyrPaste", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory
            .appendingPathComponent("Pasted-\(formatter.string(from: .now)).png")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try pngData.write(to: fileURL)
        } catch {
            return false
        }
        uploadFiles([fileURL])
        return true
    }

    private func handleMonitorKey(keyCode: UInt16, character: Character?) -> Bool {
        // Only for this router's own window (not other main windows,
        // Settings, sheets, or popovers).
        guard let keyWindow = NSApp.keyWindow, keyWindow == hostWindow
        else { return false }
        if let responder = keyWindow.firstResponder {
            // Never steal keys from text editing.
            if responder is NSTextView || responder is NSTextField { return false }
            // Let arrows drive a focused sidebar list; letters still work.
            if responder is NSTableView || responder is NSOutlineView,
               keyCode == 125 || keyCode == 126 {
                return false
            }
        }
        switch keyCode {
        case 126: return handleUpArrow()
        case 125: return handleDownArrow()
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
            ("n", "Next unread topic"),
            ("p", "Next unread direct message"),
            ("a", "Combined feed"),
            ("t", "Recent conversations"),
            ("s", "Go to topic of selected message"),
            ("⇧S", "Go to channel of selected message"),
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
            ("Space", "Quick Look selected image"),
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
        .macWindowMinSize(width: 420, height: 420)
    }
}
