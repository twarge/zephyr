import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// Identifies a single-message window: double-clicking a message in a feed
/// opens it standalone — a small, always-current view for keeping a poll or
/// todo list in sight while working elsewhere.
struct MessageWindow: Hashable, Codable {
    var accountId: Account.ID
    var messageId: Int
}

/// Resolves the account's store (bringing it up when this window restores
/// alone at launch) and hands off to the live message view.
struct MessageWindowRootView: View {
    @Environment(AppModel.self) private var model
    let window: MessageWindow

    var body: some View {
        Group {
            if let store = model.global.stores[window.accountId] {
                MessageWindowContent(store: store, messageId: window.messageId)
            } else if !model.global.enabledAccounts.contains(where: { $0.id == window.accountId }) {
                // The account list loads synchronously at launch, so a miss
                // here is a real sign-out/disable, not a race.
                ContentUnavailableView(
                    "Server Unavailable",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("This message's server has been signed out or disabled."))
            } else {
                ProgressView()
                    .controlSize(.large)
                    .task { await model.ensureStore(window.accountId) }
            }
        }
        .frame(minWidth: 320, minHeight: 200)
    }
}

/// The message itself, rendered live off the store's canonical map — poll
/// votes, todo strikes, edits, and reactions all keep flowing in through
/// the account's event queue, and widget interactions work as in the feed.
private struct MessageWindowContent: View {
    let store: PerAccountStore
    let messageId: Int

    /// The one-shot restore fetch failed (offline, or the message was
    /// deleted); shows the unavailable state with a retry.
    @State private var fetchFailed = false

    private var message: Message? {
        store.messages[messageId]
    }

    var body: some View {
        Group {
            if let message {
                ScrollView {
                    messageBody(message)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if fetchFailed {
                ContentUnavailableView {
                    Label("Message Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text("It may have been deleted, or the server can't be reached.")
                } actions: {
                    Button("Try Again") { fetchFailed = false }
                }
            } else {
                // A window restored from a previous session can outlive the
                // in-memory map; fetch the message back into it.
                ProgressView()
                    .controlSize(.large)
                    .task { await fetchMessage() }
            }
        }
        .navigationTitle(windowTitle)
        #if os(macOS)
        .navigationSubtitle(windowSubtitle ?? "")
        #endif
    }

    private func messageBody(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(store: store, userId: message.senderId, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.senderFullName)
                        .font(.body.weight(.semibold))
                    // A standalone window floats free of the feed's day
                    // separators, so the date rides along with the time.
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                            .formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let widget = MessageWidget.parse(message) {
                    MessageWidgetView(widget: widget, store: store, messageId: message.id)
                } else {
                    MessageContentView(
                        content: ContentParser.parse(html: message.content),
                        connection: store.connection)
                }
                if !message.reactions.isEmpty {
                    ReactionsRow(store: store, message: message)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Poll question or todo title when the message is a widget (that's
    /// what the window is monitoring); the conversation otherwise.
    private var windowTitle: String {
        widgetTitle ?? conversationTitle ?? "Message"
    }

    /// Whatever the title didn't say: the conversation under a widget
    /// title, the sender under a conversation title.
    private var windowSubtitle: String? {
        widgetTitle != nil ? conversationTitle : message?.senderFullName
    }

    private var widgetTitle: String? {
        guard let message, let widget = MessageWidget.parse(message) else { return nil }
        switch widget {
        case .poll(let poll):
            return poll.question.isEmpty ? "Poll" : poll.question
        case .todoList(let list):
            guard let title = list.title, !title.isEmpty else { return "To-do list" }
            return title
        }
    }

    private var conversationTitle: String? {
        guard let message,
              let key = Unreads.conversationKey(for: message, selfUserId: store.selfUserId)
        else { return nil }
        return key.displayTitle(in: store)
    }

    private func fetchMessage() async {
        guard message == nil else { return }
        do {
            let result = try await store.connection.getMessages(
                anchor: .id(messageId), numBefore: 0, numAfter: 0)
            guard result.messages.contains(where: { $0.id == messageId }) else {
                fetchFailed = true
                return
            }
            // Through the canonical reconcile path, so the copy lands in
            // the store's map and future events keep this window live.
            store.reconcileFetchedMessages(result.messages)
        } catch {
            fetchFailed = true
        }
    }
}
