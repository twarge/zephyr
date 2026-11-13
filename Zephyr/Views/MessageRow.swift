import SwiftUI
import TipKit
#if canImport(Translation)
import Translation
#endif
import ZulipAPI
import ZulipContent
import ZulipModel

struct MessageRow: View {
    let store: PerAccountStore
    let message: Message
    let showHeader: Bool
    let cache: MessageContentCache
    var useMatchHighlights = false
    /// Set in cross-conversation feeds: the control row swaps quoted
    /// reply for a jump to the message's own conversation.
    var showsConversationJump = false
    /// Set anywhere but the message's own transcript (the channel feed and
    /// every cross-conversation feed): the context menu leads with a jump
    /// to the message in its topic (or DM thread).
    var offersConversationJump = false

    @Environment(KeyboardRouter.self) private var keys
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// One state box per realized row instead of a box for every control.
    /// All of these values invalidate the same row body, so splitting them
    /// only multiplies AttributeGraph setup and teardown while scrolling.
    private struct InteractionState {
        var hovering = false
        var showReactionPicker = false
        var showMoveSheet = false
        var showTranslation = false
        var showReadReceipts = false
        var showForward = false
        var showRemindPicker = false
        var showEditHistory = false
        #if !os(macOS)
        /// Context-menu Share…: the message as text, staged for the sheet.
        var sharePayload: SharePayload?
        #endif
    }
    @State private var interaction = InteractionState()

    /// The keyboard selection's anchor (full ring).
    private var isKeySelected: Bool { keys.selectedMessageId == message.id }
    /// Extended-selection member (lighter ring than the anchor's).
    private var isMultiSelected: Bool { keys.selectedMessageIds.contains(message.id) }
    /// A followed message link flashes its target.
    private var isLinkTarget: Bool { keys.highlightMessageId == message.id }
    /// The inline editor is open on this message (router-held state).
    private var isEditing: Bool { keys.editingMessageId == message.id }

    private var content: MessageContent {
        if useMatchHighlights, let match = message.matchContent {
            // Uncached: search results are one-shot lists.
            let parsed = ContentParser.parse(html: match)
            return message.hidesLinkPreviews ? parsed.withoutLinkPreviews() : parsed
        }
        return cache.content(for: message)
    }
    private var isStarred: Bool {
        (message.flags ?? []).contains("starred")
    }

    private var isUnread: Bool {
        !(message.flags ?? []).contains("read")
    }

    /// The system selection highlight (follows the user's accent setting).
    static var selectionColor: Color {
        #if os(macOS)
        Color(nsColor: .selectedContentBackgroundColor)
        #else
        Color(uiColor: .tintColor)
        #endif
    }

    var body: some View {
        let _ = PerfLog.render("MessageRow")
        HStack(alignment: .top, spacing: 10) {
            if showHeader {
                AvatarView(store: store, userId: message.senderId, size: 32)
                    .padding(.top, 10)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if showHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Web-style: bold sender at the body text size (the
                        // timestamp lives right-aligned in the row gutter).
                        Text(message.senderFullName)
                            .font(.body.weight(.semibold))
                        if message.lastEditTimestamp != nil {
                            Button {
                                interaction.showEditHistory = true
                            } label: {
                                Text("Edited")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            .help("Show edit history")
                            .popover(isPresented: $interaction.showEditHistory) {
                                EditHistoryView(store: store, message: message)
                            }
                        }
                    }
                    .padding(.top, 10)
                } else {
                    // A follow-on message from the same sender keeps its
                    // time on a line of its own, as the sender line does
                    // for a first message: a hidden copy of the label holds
                    // the line open and the overlay draws the time in it.
                    // Text never runs under the time, and consecutive
                    // messages are separated by exactly the label's height.
                    timeLabel(timeText).hidden()
                }
                if isEditing {
                    InlineMessageEditor(store: store, messageId: message.id)
                } else if let widget = MessageWidget.parse(message) {
                    MessageWidgetView(widget: widget, store: store, messageId: message.id)
                        // Polls/todos are what the message window is for;
                        // surface its tip on one.
                        .popoverTip(MessageWindowTip())
                        .onAppear {
                            MessageWindowTip.supportsMultipleWindows =
                                supportsMultipleWindows
                        }
                } else {
                    MessageContentView(
                        content: content, connection: store.connection)
                        // Same menu over the text: selectable Text otherwise
                        // substitutes the system edit menu on right-click,
                        // which a SwiftUI .contextMenu can't override on
                        // macOS — the AppKit overlay intercepts instead.
                        #if os(macOS)
                        .overlay { RightClickMenu { messageMenu() } }
                        #else
                        .contextMenu { messageMenu() }
                        #endif
                }
                if !message.reactions.isEmpty {
                    ReactionsRow(store: store, message: message)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(
            isLinkTarget ? Color.yellow.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
        // Selection reads as a system-highlight outline, not a fill; the
        // anchor gets the full ring, extended members a lighter one.
        // While an attachment inside the message is selected, only its
        // accent ring shows — the message stays the keyboard context
        // (reply/star/j/k) without reading as a second selection.
        .overlay {
            if keys.selectedMediaId == nil {
                if isKeySelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Self.selectionColor, lineWidth: 2)
                } else if isMultiSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Self.selectionColor.opacity(0.45), lineWidth: 2)
                }
            }
        }
        // The whole row rect is clickable/right-clickable even where it's
        // transparent — without this, only the drawn text (or a selected
        // row's highlight fill) hit-tests, so clicks in the empty trailing
        // space fall through.
        .contentShape(.rect)
        // Web-style unread marker: an accent line on the left that melts
        // away when the message is marked read. Always present (at zero
        // opacity once read) so the disappearance animates.
        .overlay(alignment: .leading) {
            Capsule()
                .fill(.tint)
                .frame(width: 3)
                .padding(.vertical, 2)
                .opacity(isUnread ? 1 : 0)
                .animation(.easeOut(duration: 0.6), value: isUnread)
        }
        // Click/tap selects (like the web app); simultaneous so links and
        // buttons inside the row keep working. macOS: ⌘-click toggles
        // multi-selection membership, ⇧-click ranges from the anchor.
        .simultaneousGesture(TapGesture().onEnded {
            #if os(macOS)
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) || flags.contains(.shift) {
                // Deferred: an attachment under the same click reports
                // too, and its report wins (the router arbitrates).
                keys.reportModifierClick(
                    message: message.id, command: flags.contains(.command))
            } else {
                keys.selectedMessageId = message.id
                // A tap on an attachment also lands here (simultaneous,
                // in unspecified order); that tap's media selection must
                // survive — any other row tap drops a stale one.
                if !keys.mediaTapInFlight {
                    keys.clearMediaSelection()
                }
            }
            #else
            keys.selectedMessageId = message.id
            if !keys.mediaTapInFlight {
                keys.clearMediaSelection()
            }
            #endif
            // Clicking a message reclaims arrow keys from the sidebar.
            keys.focusMessages?()
        })
        // Double-click pops the message into its own window (the message
        // sibling of the sidebar's detach) — handy for monitoring a poll
        // or todo list. Plain .gesture, not simultaneous: interactive
        // children (links, vote buttons, attachments with their own
        // double-click) win where they hit-test.
        .gesture(
            TapGesture(count: 2).onEnded {
                MessageWindowTip().invalidate(reason: .actionPerformed)
                openWindow(value: MessageWindow(
                    accountId: store.accountId, messageId: message.id))
            },
            isEnabled: supportsMultipleWindows)
        // Message-menu actions aimed at this (selected) row: posted while
        // realized, or waiting for it to appear (the feed reveals it).
        .onChange(of: keys.messageActionRequest) { consumeActionRequest() }
        .onAppear { consumeActionRequest() }
        .overlay(alignment: .topTrailing) {
            // Fixed layout (opacity gating, not insertion) so the star sits
            // in exactly the same spot as control and as starred indicator.
            // macOS reveals on hover; touch reveals on tap (selection).
            #if os(macOS)
            let controlsActive = interaction.hovering || interaction.showReactionPicker
            #else
            let controlsActive = isKeySelected || interaction.showReactionPicker
            #endif
            // Top-aligned: the buttons' padding would otherwise center the
            // time a few points below its message's first line.
            HStack(alignment: .top, spacing: 2) {
                if showsConversationJump {
                    // Cross-conversation feeds swap quoted reply for a
                    // jump to the message's own conversation (⌘-click: in
                    // a new tab or window, per Settings).
                    Button {
                        #if os(macOS)
                        if supportsMultipleWindows,
                           NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                            ConversationJumpTabTip().invalidate(reason: .actionPerformed)
                            openConversationWindow(
                                asTab: DetachedWindowTabs.commandClickOpensTab)
                            return
                        }
                        #endif
                        goToConversation()
                    } label: {
                        Image(systemName: "arrow.turn.down.right")
                            .font(controlFont)
                            .foregroundStyle(.secondary)
                            .padding(controlPadding)
                            .background(.quaternary.opacity(0.6), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help(conversationJumpTitle)
                    #if os(macOS)
                    // On the clicked (selected) row only — the pointer is
                    // still over it, so its arrow is showing.
                    .popoverTip(isKeySelected ? ConversationJumpTabTip() : nil)
                    #endif
                    .opacity(controlsActive ? 1 : 0)
                    .allowsHitTesting(controlsActive)
                    // Hover-only: VoiceOver reaches these as row actions.
                    .accessibilityHidden(true)
                } else {
                    Button {
                        quoteAndReply()
                    } label: {
                        Image(systemName: "text.quote")
                            .font(controlFont)
                            .foregroundStyle(.secondary)
                            .padding(controlPadding)
                            .background(.quaternary.opacity(0.6), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Reply quoting this message")
                    .opacity(controlsActive ? 1 : 0)
                    .allowsHitTesting(controlsActive)
                    // Hover-only: VoiceOver reaches these as row actions.
                    .accessibilityHidden(true)
                }
                Button {
                    interaction.showReactionPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(controlFont)
                        .foregroundStyle(.secondary)
                        .padding(controlPadding)
                        .background(.quaternary.opacity(0.6), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Add reaction")
                .popover(isPresented: $interaction.showReactionPicker) {
                    EmojiPickerView(store: store) { entry in
                        store.toggleReaction(
                            message: message, emojiName: entry.name,
                            emojiCode: entry.code, reactionType: entry.reactionType)
                    }
                }
                .opacity(controlsActive ? 1 : 0)
                .allowsHitTesting(controlsActive)
                    // Hover-only: VoiceOver reaches these as row actions.
                    .accessibilityHidden(true)
                if store.supportsReminders {
                    // Hover control and pending-reminder indicator in one:
                    // gray outline clock on hover, orange filled clock while
                    // a reminder is set (the star's treatment).
                    let reminder = store.reminderForMessage(message.id)
                    Menu {
                        reminderMenuItems()
                    } label: {
                        Image(systemName: reminder == nil ? "clock" : "clock.fill")
                            .font(controlFont)
                            .foregroundStyle(
                                reminder == nil
                                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                            .padding(controlPadding)
                            .background(
                                controlsActive
                                    ? AnyShapeStyle(.quaternary.opacity(0.6))
                                    : AnyShapeStyle(.clear),
                                in: .circle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(
                        reminder.map { "Reminder: \(Self.reminderTimeText($0))" }
                            ?? "Remind me about this")
                    .opacity(controlsActive || reminder != nil ? 1 : 0)
                    .allowsHitTesting(controlsActive || reminder != nil)
                    .accessibilityHidden(true)
                }
                Button {
                    store.setStarred(!isStarred, messageId: message.id)
                } label: {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(controlFont)
                        .foregroundStyle(
                            isStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                        .padding(controlPadding)
                        .background(
                            controlsActive
                                ? AnyShapeStyle(.quaternary.opacity(0.6))
                                : AnyShapeStyle(.clear),
                            in: .circle)
                }
                .buttonStyle(.plain)
                .help(isStarred ? "Unstar" : "Star")
                .opacity(controlsActive || isStarred ? 1 : 0)
                .allowsHitTesting(controlsActive || isStarred)
                .accessibilityHidden(true)
                // The time rides the overlay (not a layout column) so the
                // hover controls line up beside it; the row holds a line
                // open for it (the sender line, or a follow-on message's
                // own time line). The star sits just to its left.
                timeLabel(timeText)
                    .padding(.top, showHeader ? 2 : 1)
            }
            .padding(.top, showHeader ? 8 : 0)
        }
        // After the overlay: the hover region must include the reaction
        // button itself, or entering the button drops row-hover and the
        // button vanishes under the pointer (flicker + missed clicks).
        .onHover { interaction.hovering = $0 }
        .contextMenu {
            messageMenu()
        }
        // VoiceOver: one element per message — sender, time, text, and
        // state — with the hover controls as actions. A poll or todo keeps
        // its children separate so its vote and check buttons stay
        // reachable.
        .accessibilityElement(
            children: MessageWidget.parse(message) == nil ? .combine : .contain)
        .accessibilityValue(accessibilityState)
        .accessibilityActions { accessibilityActionItems }
        // System translation UI, on-device (absent on platforms without
        // the Translation framework).
        .modifier(TranslationSheet(
            isPresented: $interaction.showTranslation, text: content.plainText))
        .sheet(isPresented: $interaction.showMoveSheet) {
            MoveTopicSheet(store: store, subject: .message(message))
        }
        .sheet(isPresented: $interaction.showReadReceipts) {
            ReadReceiptsSheet(store: store, message: message)
        }
        .sheet(isPresented: $interaction.showForward) {
            ForwardMessageSheet(store: store) { destination in
                interaction.showForward = false
                forwardMessage(to: destination)
            }
        }
        .sheet(isPresented: $interaction.showRemindPicker) {
            RemindTimeSheet { date in
                remind(at: date)
            }
        }
        #if !os(macOS)
        .sheet(item: $interaction.sharePayload) { payload in
            ShareActivityView(items: payload.items) { interaction.sharePayload = nil }
                .presentationDetents([.medium, .large])
        }
        #endif
    }

    static func reminderTimeText(_ reminder: Reminder) -> String {
        Date(timeIntervalSince1970: TimeInterval(reminder.scheduledDeliveryTimestamp))
            .formatted(date: .abbreviated, time: .shortened)
    }

    /// Spoken after the message: what the unread bar, star, reminder,
    /// and edit marker show.
    private var accessibilityState: String {
        var parts: [String] = []
        if isUnread { parts.append("Unread") }
        if isStarred { parts.append("Starred") }
        if store.supportsReminders, store.reminderForMessage(message.id) != nil {
            parts.append("Reminder set")
        }
        if isKeySelected { parts.append("Selected") }
        return parts.joined(separator: ", ")
    }

    /// The hover controls and in-text interactions, as VoiceOver actions.
    @ViewBuilder
    private var accessibilityActionItems: some View {
        if showsConversationJump {
            Button(conversationJumpTitle) { goToConversation() }
        } else {
            Button("Reply Quoting Message") { quoteAndReply() }
        }
        Button("Add Reaction") { interaction.showReactionPicker = true }
        ForEach(ReactionsRow.distinctEmojiNames(message.reactions), id: \.self) { name in
            Button("Toggle :\(name): Reaction") {
                if let reaction = message.reactions.first(where: { $0.emojiName == name }) {
                    store.toggleReaction(
                        message: message, emojiName: reaction.emojiName,
                        emojiCode: reaction.emojiCode, reactionType: reaction.reactionType)
                }
            }
        }
        Button(isStarred ? "Unstar" : "Star") {
            store.setStarred(!isStarred, messageId: message.id)
        }
        Button("Mark as Unread from Here") { markUnreadFromHere() }
        if message.senderId == store.selfUserId {
            Button("Edit Message") { keys.beginInlineEdit(message.id) }
        }
        ForEach(Array(Self.accessibleLinks(in: content).enumerated()), id: \.offset) { _, link in
            Button("Open Link: \(link.title)") {
                if let url = URL(string: link.href, relativeTo: store.connection.realmURL) {
                    openURL(url.absoluteURL)
                }
            }
        }
        if !MessageAttachment.list(in: content).isEmpty {
            Button("Show Attachments") {
                keys.selectedMessageId = message.id
                _ = keys.handleSpace()
            }
        }
    }

    /// Links in the message text, in reading order — combined into the
    /// row's one element, they're reachable as actions instead.
    static func accessibleLinks(in content: MessageContent) -> [(title: String, href: String)] {
        var links: [(title: String, href: String)] = []
        func visit(_ inlines: [InlineNode]) {
            for inline in inlines {
                switch inline {
                case .link(let link):
                    let title = MessageContent(blocks: [.paragraph(link.text)]).plainText
                    links.append((title.isEmpty ? link.href : title, link.href))
                case .strong(let children), .emphasis(let children),
                     .strikethrough(let children), .highlight(let children):
                    visit(children)
                default:
                    break
                }
            }
        }
        func visit(_ blocks: [BlockNode]) {
            for block in blocks {
                switch block {
                case .paragraph(let inlines), .heading(_, let inlines):
                    visit(inlines)
                case .blockquote(let children):
                    visit(children)
                case .unorderedList(let items), .orderedList(_, let items):
                    items.forEach { visit($0) }
                case .spoiler(_, let children), .collapsible(_, let children):
                    visit(children)
                default:
                    break
                }
            }
        }
        visit(content.blocks)
        return Array(links.prefix(10))
    }

    private func consumeActionRequest() {
        guard let request = keys.messageActionRequest, request.messageId == message.id
        else { return }
        keys.messageActionRequest = nil
        switch request.action {
        case .replyQuoting:
            quoteAndReply()
        case .copyReference:
            Platform.copyToPasteboard(ConversationKey.permalink(to: message, in: store))
        case .translate:
            interaction.showTranslation = true
        case .moveToTopic:
            if message.type == .stream {
                interaction.showMoveSheet = true
            }
        case .forward:
            interaction.showForward = true
        case .markUnreadFromHere:
            markUnreadFromHere()
        }
    }

    private var timeText: String {
        Date(timeIntervalSince1970: TimeInterval(message.timestamp))
            .formatted(date: .omitted, time: .shortened)
    }

    /// The row's time, as drawn in the overlay and as the hidden copy that
    /// holds a follow-on message's time line open (same font, same height).
    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.body.smallCaps())
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    /// Hover-control metrics: pointer-sized on macOS, tap-sized on touch.
    private var controlFont: Font {
        #if os(macOS)
        .callout
        #else
        .title3
        #endif
    }

    private var controlPadding: CGFloat {
        #if os(macOS)
        5
        #else
        10
        #endif
    }

    /// The reminder actions, shared by the hover clock button and the
    /// context menu: preset times (plus custom) — or just Cancel while a
    /// reminder is already pending.
    @ViewBuilder
    private func reminderMenuItems() -> some View {
        if let reminder = store.reminderForMessage(message.id) {
            Button("Cancel Reminder", systemImage: "clock.badge.xmark") {
                store.cancelReminder(reminder.reminderId)
            }
        } else {
            Button("In 1 Hour") { remind(at: .now.addingTimeInterval(3600)) }
            Button("In 3 Hours") { remind(at: .now.addingTimeInterval(3 * 3600)) }
            Button("Tomorrow at 9 AM") { remind(at: nextMorning(daysAhead: 1)) }
            Button("Next Week at 9 AM") { remind(at: nextMorning(daysAhead: 7)) }
            Divider()
            Button("At a Custom Time…") { interaction.showRemindPicker = true }
        }
    }

    /// The message context menu — one builder, attached both to the row
    /// and to the selectable text subtree (whose system menu would
    /// otherwise replace it).
    @ViewBuilder
    private func messageMenu() -> some View {
        if offersConversationJump {
            Button(conversationJumpTitle, systemImage: "arrow.turn.down.right") {
                goToConversation()
            }
            if supportsMultipleWindows {
                Button("Go to Message in New Window", systemImage: "macwindow.badge.plus") {
                    openConversationWindow()
                }
            }
            Divider()
        }
        #if os(macOS)
        // Falls back to quoting the whole message when nothing is selected.
        Button("Reply Quoting Selection", systemImage: "text.quote") {
            quoteAndReply(selectionOnly: true)
        }
        #endif
            Button("Reply Quoting Message", systemImage: "text.quote") {
                quoteAndReply()
            }
            Button("Forward Message…", systemImage: "arrowshape.turn.up.right") {
                interaction.showForward = true
            }
            if message.senderId != store.selfUserId {
                Button(
                    "Direct Message \(message.senderFullName)",
                    systemImage: "envelope"
                ) {
                    keys.navigate?(.conversation(Unreads.dmKey(
                        participantIds: [message.senderId],
                        selfUserId: store.selfUserId)))
                }
            }
            Button(isStarred ? "Unstar" : "Star", systemImage: "star") {
                store.setStarred(!isStarred, messageId: message.id)
            }
            Button("Mark as Unread from Here", systemImage: "message.badge") {
                markUnreadFromHere()
            }
            #if !os(macOS)
            // Out-of-app share (AirDrop, Messages, save, print) — distinct
            // from Forward, which stays inside Zulip.
            Button("Share…", systemImage: "square.and.arrow.up") {
                interaction.sharePayload = SharePayload(
                    items: [messageShareText(message, content: content)])
            }
            #endif
            Button("Copy Text", systemImage: "doc.on.doc") {
                Platform.copyToPasteboard(content.plainText)
            }
            Button("Copy Message Reference", systemImage: "link") {
                Platform.copyToPasteboard(
                    ConversationKey.permalink(to: message, in: store))
            }
            #if canImport(Translation) && !os(visionOS)
            Button("Translate", systemImage: "translate") {
                interaction.showTranslation = true
            }
            #endif
            Button("Seen By…", systemImage: "eye") {
                interaction.showReadReceipts = true
            }
            if store.supportsReminders {
                if store.reminderForMessage(message.id) != nil {
                    reminderMenuItems()
                } else {
                    Menu("Remind Me About This") {
                        reminderMenuItems()
                    }
                }
            }
            if store.supportsHidingLinkPreviews,
               cache.parsedContent(for: message).hasHideableLinkPreviews {
                let hidden = message.hidesLinkPreviews
                Button(
                    hidden ? "Show Link Previews" : "Hide Link Previews",
                    systemImage: hidden ? "eye" : "eye.slash"
                ) {
                    store.setLinkPreviewsHidden(!hidden, messageId: message.id)
                }
            }
            if message.type == .stream {
                Button("Move Message…", systemImage: "arrow.turn.up.right") {
                    interaction.showMoveSheet = true
                }
            }
            let isOwn = message.senderId == store.selfUserId
            // Others' messages too, for those the realm or channel lets.
            let canDelete = store.canDeleteMessage(message)
            if isOwn || canDelete {
                Divider()
                if isOwn {
                    Button("Edit Message", systemImage: "pencil") {
                        keys.beginInlineEdit(message.id)
                    }
                }
                if canDelete {
                    Button("Delete Message", systemImage: "trash", role: .destructive) {
                        store.deleteMessage(message.id)
                    }
                }
            }
        
    }

    /// The web app's "Mark as unread from here", with visibility-based read
    /// marking paused so the on-screen rows don't immediately re-mark.
    private func markUnreadFromHere() {
        keys.readMarkingPaused = true
        store.markUnreadFromHere(message)
    }

    private func remind(at date: Date) {
        store.remindAboutMessage(message.id, at: date)
    }

    private func nextMorning(daysAhead: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: daysAhead, to: .now) ?? .now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    /// Quotes this message into another conversation's compose field.
    private func forwardMessage(to destination: Destination) {
        Task {
            let raw = await store.fetchRawContent(message.id) ?? content.plainText
            let quote = messageQuoteBlock(message, raw: raw, store: store)
            keys.navigate?(destination)
            try? await Task.sleep(for: .milliseconds(300))
            keys.insertIntoCompose?(quote)
            keys.focusCompose?()
        }
    }

    /// The jump's menu title: DMs have no topic to name.
    private var conversationJumpTitle: String {
        message.type == .stream ? "Go to Message in Topic" : "Go to Message in Conversation"
    }

    /// Jumps to the message's own conversation, anchored at (and
    /// flashing) the message — the near-link navigation pattern.
    private func goToConversation() {
        guard let key = Unreads.conversationKey(
            for: message, selfUserId: store.selfUserId) else { return }
        #if os(macOS)
        ConversationJumpTabTip.jumped.sendDonation()
        #endif
        keys.highlightMessageId = message.id
        keys.pendingNear = (key, message.id)
        keys.navigate?(.conversation(key))
    }

    /// The same jump in a window of its own (the sidebar's detached
    /// window), landing on the message — on macOS optionally as a tab of
    /// this window instead.
    private func openConversationWindow(asTab: Bool = false) {
        guard let key = Unreads.conversationKey(
            for: message, selfUserId: store.selfUserId) else { return }
        let window = DetachedWindow(
            accountId: store.accountId, destination: .conversation(key), near: message.id)
        #if os(macOS)
        DetachedWindowTabs.request(window, joining: asTab ? keys.hostWindow : nil)
        #endif
        openWindow(value: window)
    }

    private func quoteAndReply(selectionOnly: Bool = false) {
        // Read the selection before anything steals focus.
        let selection = selectionOnly ? Platform.currentTextSelection() : nil
        Task {
            let raw: String
            if let selection {
                raw = selection
            } else {
                raw = await store.fetchRawContent(message.id) ?? content.plainText
            }
            let quote = messageQuoteBlock(message, raw: raw, store: store)
            // Cross-conversation feeds have no compose: jump to the
            // message's conversation first, then insert.
            if keys.insertIntoCompose == nil,
               let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId) {
                keys.navigate?(.conversation(key))
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Channel feed: the topic field follows the quoted message
            // (no-op elsewhere — only channel-mode compose registers).
            keys.setComposeTopic?(message.subject)
            keys.insertIntoCompose?(quote)
            keys.focusCompose?()
        }
    }
}

/// The inline message editor. Its text lives in the router
/// (`inlineEditText`), read only here — typing re-renders the editor,
/// not the row or its neighbors — and survives the lazy feed recycling
/// the row mid-edit.
///
/// Return follows the message field: it saves where it sends there, and
/// where it starts a new line there it does here too, with ⌘Return to
/// save. ⇧Return (or ⌃/⌥Return) is always a new line.
private struct InlineMessageEditor: View {
    let store: PerAccountStore
    let messageId: Int

    @Environment(KeyboardRouter.self) private var keys
    @Environment(AppModel.self) private var model: AppModel?
    @AppStorage(ComposeBar.returnSendsKey) private var returnSendsPreference = true
    @FocusState private var fieldFocused: Bool

    /// The message field's Return-sends setting (ComposeBar.returnSends).
    private var returnSaves: Bool {
        model?.returnSendsServer?.serverEnterSends ?? returnSendsPreference
    }

    var body: some View {
        @Bindable var keys = keys
        VStack(alignment: .leading, spacing: 6) {
            TextField("Message", text: $keys.inlineEditText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .padding(6)
                .background(
                    .quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 8))
                .focused($fieldFocused)
                .onChange(of: fieldFocused) { _, focused in
                    keys.inlineEditFocused = focused
                }
                // The lazy feed can recycle the row while it has focus.
                .onDisappear { keys.inlineEditFocused = false }
                // The general form: the keyed one only fires for an
                // unmodified Return (see ComposeBar's compact field).
                .onKeyPress(phases: .down, action: returnPress)
            HStack {
                Button("Cancel") { keys.endInlineEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    // ⌘Return is the field's own (returnPress), not a
                    // window-wide shortcut that would compete with Send.
                    .keyboardShortcut(returnSaves ? .defaultAction : nil)
                    .help(returnSaves
                        ? "Save (Return; ⇧Return for a new line)"
                        : "Save (⌘Return; Return for a new line)")
            }
            .controlSize(.small)
        }
    }

    private func save() {
        let content = keys.inlineEditText.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !content.isEmpty {
            store.editMessage(messageId, content: content)
        }
        keys.endInlineEdit()
    }

    /// Return and keypad Enter in the field. Left to itself the field
    /// submits on Return and ⇧Return alike, and nothing but ⌥Return makes
    /// a new line.
    private func returnPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.key == .return || press.key == "\u{3}" else { return .ignored }
        if press.modifiers.contains(.command) {
            save()
            return .handled
        }
        #if os(macOS)
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        // An input method's Return commits its marked text.
        if editor?.hasMarkedText() == true { return .ignored }
        #endif
        let modified = !press.modifiers.isDisjoint(with: [.shift, .control, .option])
        guard modified || !returnSaves else {
            save()
            return .handled
        }
        #if os(macOS)
        if let editor {
            // What ⌥Return does natively: at the caret, over any
            // selection.
            editor.insertNewlineIgnoringFieldEditor(nil)
        } else {
            keys.inlineEditText += "\n"
        }
        return .handled
        #else
        // A vertical field inserts the newline itself here.
        return .ignored
        #endif
    }
}

/// translationPresentation where the framework exists; a no-op elsewhere
/// (e.g. visionOS).
private struct TranslationSheet: ViewModifier {
    @Binding var isPresented: Bool
    let text: String

    func body(content: Content) -> some View {
        #if canImport(Translation) && !os(visionOS)
        content.translationPresentation(isPresented: $isPresented, text: text)
        #else
        content
        #endif
    }
}
