import Foundation
import ZulipAPI
import os

/// Event application: the switch over every event kind, and the
/// bookkeeping moves and flag changes need.
extension PerAccountStore {
    /// A realm_emoji event changed the custom set: pickers and
    /// autocomplete follow (once the catalog has loaded).
    func realmEmojiDidChange() {
        guard emojiCatalogLoadStarted else { return }
        emojiEntries = realmEmojiEntries() + unicodeEmojiEntries
    }

    func sortChannelFolders() {
        channelFolders.sort { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    func applyUpdateMessage(_ e: UpdateMessageEvent) {
        // Content edits touch messageId; topic/channel moves touch every
        // id in messageIds (subject/new_stream_id carry the target).
        let ids = e.messageIds ?? [e.messageId]
        for id in ids {
            guard var message = messages[id] else { continue }
            if id == e.messageId, let rendered = e.renderedContent {
                message.content = rendered
                // A server re-render (link previews) is not an edit.
                if !e.isRenderingOnly {
                    message.lastEditTimestamp = e.editTimestamp ?? message.lastEditTimestamp
                }
            }
            if let newTopic = e.subject {
                message.subject = newTopic
            }
            if let newStream = e.newStreamId {
                message.streamId = newStream
            }
            messages[id] = message
        }
        let move = Self.moveEndpoints(e)
        if let move {
            applyMove(ids: ids, fromStream: move.fromStream, fromTopic: move.fromTopic,
                      toStream: move.toStream, toTopic: move.toTopic)
        }
        forEachMessageList { $0.handleChangedMessages(ids: ids) }
        scheduleMessageCacheSave(ids)
        // Stored copies not in memory are edited and moved too, so
        // transcripts, search and links follow (the ones in memory save
        // above).
        let unloaded = ids.filter { messages[$0] == nil }
        guard !unloaded.isEmpty else { return }
        if e.renderedContent != nil || e.subject != nil || e.newStreamId != nil {
            let editTimestamp = e.isRenderingOnly ? nil : e.editTimestamp
            writeUnloaded(touchedLinks: true) { database, selfId in
                if let content = e.renderedContent, unloaded.contains(e.messageId) {
                    try? database.edit(
                        id: e.messageId, content: content,
                        editTimestamp: editTimestamp, selfUserId: selfId)
                }
                try? database.move(
                    ids: unloaded, toStreamId: e.newStreamId, topic: e.subject,
                    selfUserId: selfId)
            }
        }
        if let move {
            forEachMessageList {
                $0.handleUnloadedMovedIn(ids: unloaded, streamId: move.toStream, topic: move.toTopic)
            }
        }
    }

    struct MoveEndpoints {
        var fromStream: Int
        var fromTopic: String
        var toStream: Int
        var toTopic: String
    }

    /// Where a move took its messages, when the event is one: `stream_id`
    /// and `orig_subject` name the source, `new_stream_id`/`subject` the
    /// destination (each absent when that half didn't change).
    static func moveEndpoints(_ e: UpdateMessageEvent) -> MoveEndpoints? {
        guard let fromStream = e.streamId, let fromTopic = e.origSubject ?? e.subject
        else { return nil }
        let endpoints = MoveEndpoints(
            fromStream: fromStream, fromTopic: fromTopic,
            toStream: e.newStreamId ?? fromStream, toTopic: e.subject ?? fromTopic)
        guard endpoints.toStream != fromStream || endpoints.toTopic != fromTopic
        else { return nil }
        return endpoints
    }

    /// Re-keys unread and sidebar bookkeeping for moved messages — from
    /// the event's id list, so ids never loaded move too.
    func applyMove(
        ids: [Int], fromStream: Int, fromTopic: String, toStream: Int, toTopic: String
    ) {
        let newKey = ConversationKey.topic(streamId: toStream, topic: toTopic)
        unreads.handleMove(ids: ids, to: newKey) { key in
            if case .topic(let streamId, _) = key { return streamId == fromStream }
            return false
        }
        let moved = Set(ids)
        let remainingLatest = messages.values
            .filter {
                !moved.contains($0.id) && $0.streamId == fromStream
                    && TopicName.matches($0.subject, fromTopic)
                    && !($0.flags ?? []).contains("historical")
            }
            .max { $0.id < $1.id }
        conversations.handleMove(
            movedIds: ids, from: .topic(streamId: fromStream, topic: fromTopic), to: newKey,
            lookup: { self.messages[$0] }, remainingLatest: remainingLatest,
            selfUserId: selfUserId)
    }

    func applyUpdateMessageFlags(_ e: UpdateMessageFlagsEvent) {
        guard let op = UpdateFlagsOp(rawValue: e.op) else {
            logger.error("update_message_flags with unknown op \(e.op, privacy: .public)")
            return
        }
        let isSet = op == .add
        let changed = setFlagInMemory(
            e.flag, isSet, ids: e.all ? Array(messages.keys) : e.messages)
        if e.flag == "starred" {
            switch op {
            case .add: starredMessageIds.formUnion(e.messages)
            case .remove:
                if e.all {
                    starredMessageIds = []
                } else {
                    starredMessageIds.subtract(e.messages)
                }
            }
        }
        unreads.handleFlagsEvent(
            op: op, flag: e.flag, ids: e.messages, all: e.all,
            locate: { self.messages[$0] }, detail: { e.detail(for: $0) })
        notifyFlagsChanged(changed)
        // Stored copies not in memory: pruning keeps what's starred, and an
        // offline restore shows the current read state.
        let unloaded = e.messages.filter { messages[$0] == nil }
        if !unloaded.isEmpty {
            let flag = e.flag
            writeUnloaded(touchedLinks: false) { database, selfId in
                try? database.updateFlag(flag, isSet: isSet, ids: unloaded, selfUserId: selfId)
            }
        }
    }

    func apply(_ event: Event) {
        defer {
            topicActivity.handleEvent(event)
            channelTopics.handleEvent(event)
            topicLinks.handleEvent(event)
        }
        switch event.kind {
        case .heartbeat:
            break

        case .message(let e):
            var message = e.message
            message.flags = e.flags
            messages[message.id] = message
            cachedMessageIds.remove(message.id)
            unreads.handleMessage(message, flags: e.flags)
            conversations.noteMessage(message, selfUserId: selfUserId)
            forEachMessageList { $0.handleNewMessage(message, selfUserId: selfUserId) }
            if let localId = e.localMessageId {
                deliveredSends[localId] = nil
                outbox.removeAll { $0.id == localId }
                persistOutbox()
            }
            clearDeliveredSends(messageIds: [message.id])
            scheduleEviction()
            scheduleMessageCacheSave([message.id])

        case .updateMessage(let e):
            applyUpdateMessage(e)

        case .deleteMessage(let e):
            for id in e.allIds {
                messages.removeValue(forKey: id)
                cachedMessageIds.remove(id)
            }
            unreads.removeMessages(ids: e.allIds)
            forEachMessageList { $0.handleDeletedMessages(ids: e.allIds) }
            dirtyMessageIds.subtract(e.allIds)
            let ids = e.allIds
            writeUnloaded(touchedLinks: false) { database, _ in
                try? database.delete(ids: ids)
            }

        case .updateMessageFlags(let e):
            applyUpdateMessageFlags(e)

        case .reaction(let e):
            guard var message = messages[e.messageId] else { break }
            switch e.op {
            case "add":
                if !message.reactions.contains(e.reaction) {
                    message.reactions.append(e.reaction)
                }
            case "remove":
                message.reactions.removeAll {
                    $0.userId == e.userId && $0.emojiCode == e.emojiCode
                        && $0.reactionType == e.reactionType
                }
            default:
                break
            }
            messages[e.messageId] = message
            forEachMessageList { $0.handleChangedMessages(ids: [e.messageId]) }
            scheduleMessageCacheSave([e.messageId])

        case .typing(let e):
            guard e.senderId != selfUserId else { break }
            let key: ConversationKey?
            if let streamId = e.streamId {
                key = .topic(streamId: streamId, topic: e.topic ?? "")
            } else if let recipients = e.recipients {
                key = Unreads.dmKey(
                    participantIds: recipients.map(\.userId), selfUserId: selfUserId)
            } else {
                key = nil
            }
            guard let key else { break }
            if e.op == "start" {
                typing.handleStart(
                    key: key, userId: e.senderId, expiryMilliseconds: typingStartedExpiryMs)
            } else {
                typing.handleStop(key: key, userId: e.senderId)
            }

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

        case .subscriptionUpdate(let e):
            guard var subscription = subscriptions[e.streamId] else { break }
            let wasMuted = subscription.muted
            defer {
                // After the write-back below. (The confirmation of an
                // optimistic mute finds no change, and stays quiet.)
                if let isMuted = subscriptions[e.streamId]?.muted, isMuted != wasMuted {
                    homeVisibilityDidChange(revealed: wasMuted)
                }
            }
            switch e.property {
            case "is_muted":
                subscription.isMuted = e.boolValue ?? subscription.isMuted
            case "pin_to_top":
                subscription.pinToTop = e.boolValue ?? subscription.pinToTop
            case "desktop_notifications":
                subscription.desktopNotifications =
                    e.boolValue ?? subscription.desktopNotifications
            case "color":
                subscription.color = e.stringValue ?? subscription.color
            default:
                break
            }
            subscriptions[e.streamId] = subscription

        case .streamUpdate(let e):
            switch e.property {
            case "name":
                guard let name = e.stringValue else { break }
                channels[e.streamId]?.name = name
                if var subscription = subscriptions[e.streamId] {
                    subscription.name = name
                    subscriptions[e.streamId] = subscription
                }
            case "description":
                guard let description = e.stringValue else { break }
                channels[e.streamId]?.description = description
                if var subscription = subscriptions[e.streamId] {
                    subscription.description = description
                    subscriptions[e.streamId] = subscription
                }
            case "folder_id":
                // Null (no int) files the channel back under no folder.
                channels[e.streamId]?.folderId = e.intValue
            case "is_archived":
                // Archived reads as gone, like a stream delete.
                if e.boolValue == true {
                    channels.removeValue(forKey: e.streamId)
                    subscriptions.removeValue(forKey: e.streamId)
                }
            default:
                break
            }

        case .remindersChanged:
            Task { await refreshReminders() }

        case .streamCreate(let streams):
            for stream in streams {
                channels[stream.streamId] = stream
            }

        case .streamDelete(let streamIds):
            for id in streamIds {
                channels.removeValue(forKey: id)
                subscriptions.removeValue(forKey: id)
            }

        case .submessage(let e):
            guard var message = messages[e.messageId] else { break }
            var submessages = message.submessages ?? []
            submessages.append(
                Submessage(msgType: e.msgType, content: e.content, senderId: e.senderId))
            message.submessages = submessages
            messages[e.messageId] = message
            forEachMessageList { $0.handleChangedMessages(ids: [e.messageId]) }
            scheduleMessageCacheSave([e.messageId])

        case .draftsAdd(let drafts):
            for draft in drafts {
                if let id = draft.id {
                    serverDrafts[id] = draft
                }
            }
            draftEventObserver?(.added(drafts))

        case .draftsUpdate(let draft):
            if let id = draft.id {
                serverDrafts[id] = draft
            }
            draftEventObserver?(.updated(draft))

        case .draftsRemove(let draftId):
            serverDrafts.removeValue(forKey: draftId)
            draftEventObserver?(.removed(draftId))

        case .userTopic(let item):
            applyTopicVisibility(
                streamId: item.streamId, topic: item.topicName,
                policy: TopicVisibilityPolicy(rawValue: item.visibilityPolicy) ?? .none)

        case .urlEmbedData(let e):
            previewEmbeds = PreviewEmbeds(
                eventId: event.id, content: e.content, renderedContent: e.renderedContent)

        case .userSettingsUpdate(let e):
            if e.property == "enter_sends", let enterSends = e.boolValue {
                serverEnterSends = enterSends
            }

        case .realmEmojiReplace(let all):
            realmEmoji = all
            realmEmojiDidChange()

        case .realmEmojiAdd(let emojiId, let emoji):
            realmEmoji[emojiId] = emoji
            realmEmojiDidChange()

        case .realmEmojiUpdateOne(let emojiId, let deactivated):
            if let deactivated, realmEmoji[emojiId] != nil {
                realmEmoji[emojiId]?.deactivated = deactivated
                realmEmojiDidChange()
            }

        case .channelFolderAdd(let e):
            guard !e.isArchived else { break }
            channelFolders.removeAll { $0.id == e.folder.id }
            channelFolders.append(e.folder)
            sortChannelFolders()

        case .channelFolderUpdate(let e):
            if e.isArchived == true {
                // Archived folders leave the sidebar; their channels fall
                // back to the unfiled section.
                if let folder = channelFolders.first(where: { $0.id == e.channelFolderId }) {
                    archivedChannelFolders[folder.id] = folder
                }
                channelFolders.removeAll { $0.id == e.channelFolderId }
            } else if e.isArchived == false,
                      let folder = archivedChannelFolders.removeValue(forKey: e.channelFolderId) {
                channelFolders.append(folder)
                sortChannelFolders()
            }
            if let name = e.name {
                if let index = channelFolders.firstIndex(where: { $0.id == e.channelFolderId }) {
                    channelFolders[index].name = name
                }
                archivedChannelFolders[e.channelFolderId]?.name = name
            }

        case .channelFolderReorder(let order):
            let position = Dictionary(
                order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            channelFolders = channelFolders.map { folder in
                var folder = folder
                folder.order = position[folder.id] ?? (order.count + folder.order)
                return folder
            }
            sortChannelFolders()

        case .unexpected(let type, let op):
            logger.debug(
                "ignoring unexpected event type=\(type, privacy: .public) op=\(op ?? "-", privacy: .public)")
        }
    }
}
