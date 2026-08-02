import Foundation
import Observation
import ZulipAPI
import os

/// The consistent snapshot of one account's server state.
///
/// Invariant (the heart of the architecture): a `PerAccountStore` is only ever
/// (a) constructed from a `/register` initial snapshot, and (b) mutated by
/// `handleEvent` applying events from that snapshot's queue, in order, on the
/// main actor. On queue expiry or malformed events, the whole store is
/// discarded and rebuilt from a fresh snapshot (see `GlobalStore.rebuild`).
@MainActor
@Observable
public final class PerAccountStore {
    public let accountId: Account.ID
    public let selfUserId: Int
    public nonisolated let connection: ApiConnection
    public let queueId: String
    public var lastEventId: Int
    public let zulipFeatureLevel: Int
    public let eventQueueLongpollTimeoutSeconds: Int

    public private(set) var realmName: String?
    public private(set) var users: [Int: User] = [:]
    public private(set) var channels: [Int: ZulipStream] = [:]
    public private(set) var subscriptions: [Int: Subscription] = [:]
    /// Canonical map of every message we've seen (fetched or via events).
    public private(set) var messages: [Int: Message] = [:]
    public let unreads: Unreads
    /// The unified sidebar model.
    public let conversations: ConversationList

    private struct WeakMessageList {
        weak var value: MessageListModel?
    }
    private var messageLists: [UUID: WeakMessageList] = [:]

    /// True while the event stream is failing and being retried; UI shows a
    /// "connecting" banner.
    public var isRecoveringEventStream = false

    private let logger = Logger(subsystem: "com.twarge.zulip", category: "store")

    public init(account: Account, connection: ApiConnection, snapshot: InitialSnapshot) {
        accountId = account.id
        selfUserId = account.userId
        self.connection = connection
        queueId = snapshot.queueId
        lastEventId = snapshot.lastEventId
        zulipFeatureLevel = snapshot.zulipFeatureLevel
        eventQueueLongpollTimeoutSeconds = snapshot.eventQueueLongpollTimeoutSeconds ?? 90
        realmName = snapshot.realmName

        let allUsers = (snapshot.realmUsers ?? [])
            + (snapshot.realmNonActiveUsers ?? [])
            + (snapshot.crossRealmBots ?? [])
        users = Dictionary(allUsers.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        channels = Dictionary(
            (snapshot.streams ?? []).map { ($0.streamId, $0) },
            uniquingKeysWith: { first, _ in first })
        subscriptions = Dictionary(
            (snapshot.subscriptions ?? []).map { ($0.streamId, $0) },
            uniquingKeysWith: { first, _ in first })
        unreads = Unreads(snapshot: snapshot.unreadMsgs, selfUserId: account.userId)
        conversations = ConversationList(snapshot: snapshot, selfUserId: account.userId)
    }

    // MARK: Message-list fan-out

    /// Events are applied to the canonical message map once, then fanned out
    /// to each registered (open) message list.
    public func register(_ list: MessageListModel) {
        messageLists[list.id] = WeakMessageList(value: list)
    }

    public func unregister(_ listId: UUID) {
        messageLists.removeValue(forKey: listId)
    }

    private func forEachMessageList(_ body: (MessageListModel) -> Void) {
        for (key, ref) in messageLists {
            if let list = ref.value {
                body(list)
            } else {
                messageLists.removeValue(forKey: key)
            }
        }
    }

    /// Seeds the sidebar's topic recency from a combined-feed fetch (DM
    /// recency comes from the register snapshot).
    public func seedConversations(count: Int = 100) async {
        guard let result = try? await connection.getMessages(
            anchor: .newest, numBefore: count, numAfter: 0)
        else { return }
        reconcileFetchedMessages(result.messages)
        conversations.seed(messages: result.messages, selfUserId: selfUserId)
    }

    /// Marks a whole conversation read (the Messages-style behavior when a
    /// conversation is opened): optimistic local clear + server flag update;
    /// the resulting event confirms.
    public func markConversationRead(_ key: ConversationKey) {
        guard let ids = unreads.unreadIds[key], !ids.isEmpty else { return }
        let sorted = ids.sorted()
        unreads.removeMessages(ids: sorted)
        let connection = connection
        Task {
            try? await connection.updateMessageFlags(messages: sorted, op: .add, flag: "read")
        }
    }

    /// Adds fetched messages to the canonical map, applying zulip-flutter's
    /// reconcile rule: a message we already have wins over a fetched copy
    /// (events applied to it can't be replayed; the fetch may predate them).
    public func reconcileFetchedMessages(_ fetched: [Message]) {
        for message in fetched where messages[message.id] == nil {
            messages[message.id] = message
        }
    }

    public func handleEvent(_ event: Event) {
        switch event.kind {
        case .heartbeat:
            break

        case .message(let e):
            var message = e.message
            message.flags = e.flags
            messages[message.id] = message
            unreads.handleMessage(message, flags: e.flags)
            conversations.noteMessage(message, selfUserId: selfUserId)
            forEachMessageList { $0.handleNewMessage(message, selfUserId: selfUserId) }

        case .updateMessage(let e):
            // Content edits only for M0; topic/channel moves land with the
            // message-list model in M1.
            guard var message = messages[e.messageId] else { break }
            if let rendered = e.renderedContent {
                message.content = rendered
            }
            if let edited = e.editTimestamp {
                message.lastEditTimestamp = edited
            }
            messages[e.messageId] = message
            forEachMessageList { $0.handleChangedMessages(ids: [e.messageId]) }

        case .deleteMessage(let e):
            for id in e.allIds {
                messages.removeValue(forKey: id)
            }
            unreads.removeMessages(ids: e.allIds)
            forEachMessageList { $0.handleDeletedMessages(ids: e.allIds) }

        case .updateMessageFlags(let e):
            guard let op = UpdateFlagsOp(rawValue: e.op) else {
                logger.error("update_message_flags with unknown op \(e.op, privacy: .public)")
                break
            }
            let ids = e.all ? Array(messages.keys) : e.messages
            for id in ids {
                guard var message = messages[id] else { continue }
                var flags = Set(message.flags ?? [])
                switch op {
                case .add: flags.insert(e.flag)
                case .remove: flags.remove(e.flag)
                }
                message.flags = Array(flags)
                messages[id] = message
            }
            unreads.handleFlagsEvent(
                op: op, flag: e.flag, ids: e.messages, all: e.all,
                locate: { self.messages[$0] })
            forEachMessageList { $0.handleChangedMessages(ids: ids) }

        case .realmUserAdd(let user):
            users[user.userId] = user

        case .realmUserUpdate(let update):
            guard var user = users[update.userId] else { break }
            if let name = update.fullName { user.fullName = name }
            if let avatar = update.avatarUrl { user.avatarUrl = avatar }
            if let active = update.isActive { user.isActive = active }
            users[update.userId] = user

        case .realmUserRemove(let userId):
            users.removeValue(forKey: userId)

        case .subscriptionAdd(let subs):
            for sub in subs {
                subscriptions[sub.streamId] = sub
            }

        case .subscriptionRemove(let streamIds):
            for id in streamIds {
                subscriptions.removeValue(forKey: id)
            }

        case .streamCreate(let streams):
            for stream in streams {
                channels[stream.streamId] = stream
            }

        case .streamDelete(let streamIds):
            for id in streamIds {
                channels.removeValue(forKey: id)
                subscriptions.removeValue(forKey: id)
            }

        case .unexpected(let type, let op):
            logger.debug(
                "ignoring unexpected event type=\(type, privacy: .public) op=\(op ?? "-", privacy: .public)")
        }
    }
}
