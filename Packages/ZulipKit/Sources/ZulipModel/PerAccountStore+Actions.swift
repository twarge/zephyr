import Foundation
import ZulipAPI
import os

/// User actions: reactions, flags, subscriptions, channel and topic
/// edits, widgets and reminders — optimistic where possible, failures
/// surfaced through `lastActionFailure`.
extension PerAccountStore {
    // MARK: Reminders

    /// Whether this realm's server has the reminders API (Zulip 11+).
    public var supportsReminders: Bool {
        zulipFeatureLevel >= ApiConnection.remindersFeatureLevel
    }

    /// Schedules a server-side reminder about a message, delivered as a DM
    /// from the reminders bot at the given time. The refetch that follows
    /// is the creation feedback — the message's clock icon appears.
    public func remindAboutMessage(_ messageId: Int, at date: Date) {
        runAction("Couldn't set the reminder") { connection in
            try await connection.createReminder(
                messageId: messageId, deliveryTimestamp: Int(date.timeIntervalSince1970))
        } completion: { [weak self] in
            await self?.refreshReminders()
        }
    }

    public func cancelReminder(_ reminderId: Int) {
        // Optimistic; the refetch confirms.
        reminders.removeValue(forKey: reminderId)
        runAction("Couldn't cancel the reminder") { connection in
            try await connection.deleteReminder(reminderId: reminderId)
        } completion: { [weak self] in
            await self?.refreshReminders()
        }
    }

    /// Refetches pending reminders — the register snapshot doesn't carry
    /// them, so launch, creation, cancellation, and reminder events all
    /// funnel through here.
    public func refreshReminders() async {
        guard supportsReminders,
              let fetched = try? await connection.getReminders() else { return }
        reminders = Dictionary(uniqueKeysWithValues: fetched.map { ($0.reminderId, $0) })
    }

    public func reminderForMessage(_ messageId: Int) -> Reminder? {
        reminders.values.first { $0.reminderTargetMessageId == messageId }
    }

    // MARK: Message actions

    public func toggleReaction(message: Message, emojiName: String, emojiCode: String, reactionType: String) {
        let mine = message.reactions.contains {
            $0.userId == selfUserId && $0.emojiCode == emojiCode
                && $0.reactionType == reactionType
        }
        // Optimistic local apply; the server's reaction event confirms
        // idempotently (its add/remove handlers tolerate the echo).
        if var current = messages[message.id] {
            if mine {
                current.reactions.removeAll {
                    $0.userId == selfUserId && $0.emojiCode == emojiCode
                        && $0.reactionType == reactionType
                }
            } else {
                current.reactions.append(
                    Reaction(
                        emojiName: emojiName, emojiCode: emojiCode,
                        reactionType: reactionType, userId: selfUserId))
            }
            messages[message.id] = current
            forEachMessageList { $0.handleChangedMessages(ids: [message.id]) }
            scheduleMessageCacheSave([message.id])
        }
        performOrQueue(
            .reaction(
                messageId: message.id, add: !mine,
                emojiName: emojiName, emojiCode: emojiCode, reactionType: reactionType))
    }

    public func setStarred(_ starred: Bool, messageId: Int) {
        // Optimistic; the flags event confirms.
        if starred {
            starredMessageIds.insert(messageId)
        } else {
            starredMessageIds.remove(messageId)
        }
        setFlagLocally("starred", starred, messageId: messageId)
        performOrQueue(.updateFlags(messageIds: [messageId], add: starred, flag: "starred"))
    }

    /// Whether this realm's server has the per-message `hide_link_previews`
    /// flag (Zulip 13+).
    public var supportsHidingLinkPreviews: Bool {
        zulipFeatureLevel >= ApiConnection.hideLinkPreviewsFeatureLevel
    }

    /// Hides or restores one message's website cards and video embeds, for
    /// this user on every client (web parity: Shift+L).
    public func setLinkPreviewsHidden(_ hidden: Bool, messageId: Int) {
        guard supportsHidingLinkPreviews else { return }
        // Optimistic; the flags event confirms.
        setFlagLocally(Message.hideLinkPreviewsFlag, hidden, messageId: messageId)
        performOrQueue(
            .updateFlags(
                messageIds: [messageId], add: hidden, flag: Message.hideLinkPreviewsFlag))
    }

    func setFlagLocally(_ flag: String, _ isSet: Bool, messageId: Int) {
        notifyFlagsChanged(setFlagInMemory(flag, isSet, ids: [messageId]))
    }

    /// Whether the server would let the user delete this message (the web
    /// app's rule): anyone with the realm's or the channel's delete-any
    /// permission; otherwise the sender, when allowed to delete their own
    /// and within the realm's time limit.
    public func canDeleteMessage(_ message: Message, now: Date = .now) -> Bool {
        func holds(_ setting: GroupSettingValue?) -> Bool? {
            setting?.contains(userId: selfUserId, groupIds: selfGroupIds)
        }
        let channel = message.streamId.flatMap { channels[$0] }
        // Servers without the group setting let administrators delete.
        if holds(canDeleteAnyMessageGroup) ?? isAdmin { return true }
        if holds(channel?.canDeleteAnyMessageGroup) == true { return true }
        guard message.senderId == selfUserId else { return false }
        guard holds(canDeleteOwnMessageGroup) ?? true
            || holds(channel?.canDeleteOwnMessageGroup) == true
        else { return false }
        guard let limit = messageDeleteLimitSeconds else { return true }
        return now.timeIntervalSince1970 - TimeInterval(message.timestamp) <= TimeInterval(limit)
    }

    static func groupIds(containing userId: Int, in groups: [UserGroup]) -> Set<Int> {
        var ids = Set(groups.filter { $0.members?.contains(userId) == true }.map(\.id))
        var grew = true
        while grew {
            grew = false
            for group in groups where !ids.contains(group.id)
                && !ids.isDisjoint(with: group.directSubgroupIds ?? []) {
                ids.insert(group.id)
                grew = true
            }
        }
        return ids
    }

    public func deleteMessage(_ messageId: Int) {
        // Not optimistic: the delete event removes it.
        runAction("Couldn't delete the message") { connection in
            try await connection.deleteMessage(messageId: messageId)
        }
    }

    public func setChannelMuted(_ streamId: Int, muted: Bool) {
        // Optimistic; the subscription/update event confirms.
        let previous = subscriptions[streamId]?.isMuted
        applyChannelMuted(streamId, muted: muted)
        runAction("Couldn't \(muted ? "mute" : "unmute") \(channelLabel(streamId))") { connection in
            try await connection.setSubscriptionProperty(
                streamId: streamId, property: "is_muted", value: muted)
        } rollback: { [weak self] in
            guard let self, self.subscriptions[streamId]?.muted == muted else { return }
            self.applyChannelMuted(streamId, muted: previous ?? false)
        }
    }

    func applyChannelMuted(_ streamId: Int, muted: Bool) {
        guard var subscription = subscriptions[streamId] else { return }
        let wasMuted = subscription.muted
        subscription.isMuted = muted
        subscriptions[streamId] = subscription
        if wasMuted != muted { homeVisibilityDidChange(revealed: !muted) }
    }

    /// "#name" for failure messages.
    func channelLabel(_ streamId: Int) -> String {
        (channels[streamId]?.name ?? subscriptions[streamId]?.name).map { "#\($0)" }
            ?? "the channel"
    }

    /// An optimistic subscription-property write: applied now, rolled back
    /// (unless an event changed it meanwhile) if the server refuses.
    func updateSubscription<Value: Equatable>(
        _ streamId: Int, _ keyPath: WritableKeyPath<Subscription, Value>, to value: Value,
        failure: String, send: @escaping @Sendable (ApiConnection) async throws -> Void
    ) {
        guard var subscription = subscriptions[streamId] else {
            runAction(failure, send)
            return
        }
        let previous = subscription[keyPath: keyPath]
        subscription[keyPath: keyPath] = value
        subscriptions[streamId] = subscription
        runAction(failure, send) { [weak self] in
            guard let self, var current = self.subscriptions[streamId],
                  current[keyPath: keyPath] == value else { return }
            current[keyPath: keyPath] = previous
            self.subscriptions[streamId] = current
        }
    }

    // MARK: Action failures

    public func clearActionFailure() {
        lastActionFailure = nil
    }

    /// Runs a server mutation the UI already reflects (or awaits an event
    /// for). On failure `rollback` undoes the optimistic change and the
    /// failure surfaces as `lastActionFailure`; `completion` runs either
    /// way.
    func runAction(
        _ failure: String,
        _ work: @escaping @Sendable (ApiConnection) async throws -> Void,
        rollback: (@MainActor () -> Void)? = nil,
        completion: (@MainActor () async -> Void)? = nil
    ) {
        let connection = connection
        Task {
            let endActivity = BackgroundActivity.begin("action")
            defer { endActivity() }
            do {
                try await work(connection)
            } catch is CancellationError {
            } catch {
                rollback?()
                reportActionFailure(failure, error)
            }
            await completion?()
        }
    }

    func reportActionFailure(_ failure: String, _ error: any Error) {
        let reason = isTransientNetworkError(error)
            ? "you appear to be offline." : error.localizedDescription
        lastActionFailure = ActionFailure(message: "\(failure): \(reason)")
        logger.error("\(failure, privacy: .public): \(error)")
    }

    /// Per-user pin: pinned channels sort to the top of their section.
    public func setChannelPinned(_ streamId: Int, pinned: Bool) {
        // Optimistic; the subscription/update event confirms.
        updateSubscription(
            streamId, \.pinToTop, to: pinned,
            failure: "Couldn't \(pinned ? "pin" : "unpin") \(channelLabel(streamId))"
        ) { connection in
            try await connection.setSubscriptionProperty(
                streamId: streamId, property: "pin_to_top", value: pinned)
        }
    }

    /// Per-user "notify on all messages" in a channel.
    public func setChannelNotifies(_ streamId: Int, notifies: Bool) {
        updateSubscription(
            streamId, \.desktopNotifications, to: notifies,
            failure: "Couldn't change notifications for \(channelLabel(streamId))"
        ) { connection in
            try await connection.setSubscriptionProperty(
                streamId: streamId, property: "desktop_notifications", value: notifies)
        }
    }

    /// Per-user channel color ("#rrggbb").
    public func setChannelColor(_ streamId: Int, hex: String) {
        updateSubscription(
            streamId, \.color, to: hex,
            failure: "Couldn't change the color of \(channelLabel(streamId))"
        ) { connection in
            try await connection.setSubscriptionProperty(
                streamId: streamId, property: "color", value: hex)
        }
    }

    /// Toggle a poll vote (vote true adds, false retracts).
    public func voteInPoll(messageId: Int, optionKey: String, vote: Bool) {
        sendWidgetEvent(
            messageId: messageId,
            content: #"{"type":"vote","key":"\#(optionKey)","vote":\#(vote ? 1 : -1)}"#)
    }

    /// Appends an option to a poll (anyone may). The event's idx is this
    /// user's per-poll counter — replayed from the existing submessages so
    /// the option key ("\(selfUserId),\(idx)") never collides.
    public func addPollOption(messageId: Int, option: String) {
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextIdx = nextWidgetCounter(messageId: messageId, eventType: "new_option", field: "idx")
        sendWidgetEventJSON(
            messageId: messageId,
            ["type": "new_option", "option": trimmed, "idx": nextIdx])
    }

    /// Sets a poll's question (the web app allows only the poll's author).
    public func setPollQuestion(messageId: Int, question: String) {
        sendWidgetEventJSON(
            messageId: messageId,
            ["type": "question", "question": question])
    }

    /// This user's next per-widget counter for `eventType` events: one past
    /// the highest `field` among their earlier ones (submessage 0 is the
    /// widget's setup, not an event).
    func nextWidgetCounter(messageId: Int, eventType: String, field: String) -> Int {
        var next = 1
        for submessage in messages[messageId]?.submessages?.dropFirst() ?? [] {
            guard submessage.senderId == selfUserId,
                  let data = submessage.content.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  event["type"] as? String == eventType else { continue }
            next = max(next, (event[field] as? Int ?? 0) + 1)
        }
        return next
    }

    func sendWidgetEventJSON(messageId: Int, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let content = String(data: data, encoding: .utf8) else { return }
        sendWidgetEvent(messageId: messageId, content: content)
    }

    /// Appends a task to a to-do list (anyone may); keys are per-sender
    /// counters like poll options.
    public func addTodoTask(messageId: Int, task: String, detail: String? = nil) {
        let trimmed = task.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let nextKey = nextWidgetCounter(messageId: messageId, eventType: "new_task", field: "key")
        sendWidgetEventJSON(
            messageId: messageId,
            [
                "type": "new_task", "key": nextKey, "task": trimmed,
                "desc": detail?.trimmingCharacters(in: .whitespaces) ?? "",
                "completed": false,
            ])
    }

    /// Sets a to-do list's title (the web app allows only the author).
    public func setTodoListTitle(messageId: Int, title: String) {
        sendWidgetEventJSON(
            messageId: messageId,
            ["type": "new_task_list_title", "title": title])
    }

    /// Toggle a todo task's completion.
    public func strikeTodoTask(messageId: Int, taskKey: String) {
        sendWidgetEvent(
            messageId: messageId, content: #"{"type":"strike","key":"\#(taskKey)"}"#)
    }

    func sendWidgetEvent(messageId: Int, content: String) {
        runAction("Couldn't update the widget") { connection in
            try await connection.sendSubmessage(messageId: messageId, content: content)
        }
    }

    public func subscribe(toChannel name: String) {
        runAction("Couldn't subscribe to #\(name)") { connection in
            try await connection.subscribe(toChannel: name)
        }
    }

    public func unsubscribe(fromChannel name: String) {
        runAction("Couldn't unsubscribe from #\(name)") { connection in
            try await connection.unsubscribe(fromChannel: name)
        }
    }

    /// Creates a channel and subscribes to it. Throws so creation UI can
    /// surface refusals (name taken, no permission); the subscription
    /// event delivers the new channel to the sidebar.
    public func createChannel(
        name: String, description: String, inviteOnly: Bool, announce: Bool
    ) async throws {
        try await connection.createChannel(
            name: name, description: description, inviteOnly: inviteOnly,
            announce: announce)
    }

    /// Archives a channel for everyone (admin-gated server-side; history
    /// is preserved). The stream delete/archived event removes it locally.
    public func archiveChannel(_ streamId: Int) {
        runAction("Couldn't archive \(channelLabel(streamId))") { connection in
            try await connection.archiveStream(streamId: streamId)
        }
    }

    // MARK: Subscriber management (throws so sheets can surface refusals)

    public func fetchSubscribers(streamId: Int) async throws -> [Int] {
        try await connection.getSubscribers(streamId: streamId)
    }

    public func addSubscriber(userId: Int, toChannel streamId: Int) async throws {
        guard let name = channels[streamId]?.name ?? subscriptions[streamId]?.name
        else { return }
        try await connection.subscribe(userIds: [userId], toChannel: name)
    }

    public func removeSubscriber(userId: Int, fromChannel streamId: Int) async throws {
        guard let name = channels[streamId]?.name ?? subscriptions[streamId]?.name
        else { return }
        try await connection.unsubscribe(userIds: [userId], fromChannel: name)
    }

    /// Restores an archived channel (admin-gated; feature level 388).
    /// Throws so the channel browser can surface refusals.
    public func unarchiveChannel(_ streamId: Int) async throws {
        try await connection.updateStream(streamId: streamId, isArchived: false)
    }

    /// Edits a channel's description for everyone. Optimistic; the
    /// stream/update event confirms.
    public func setChannelDescription(_ streamId: Int, description: String) {
        let previous = channels[streamId]?.description ?? subscriptions[streamId]?.description
        applyChannelDescription(streamId, description)
        runAction("Couldn't change the description of \(channelLabel(streamId))") { connection in
            try await connection.updateStream(streamId: streamId, description: description)
        } rollback: { [weak self] in
            guard let self, let previous,
                  (self.channels[streamId]?.description ?? self.subscriptions[streamId]?.description)
                    == description
            else { return }
            self.applyChannelDescription(streamId, previous)
        }
    }

    func applyChannelDescription(_ streamId: Int, _ description: String) {
        channels[streamId]?.description = description
        if var subscription = subscriptions[streamId] {
            subscription.description = description
            subscriptions[streamId] = subscription
        }
    }

    func applyChannelName(_ streamId: Int, _ name: String) {
        channels[streamId]?.name = name
        if var subscription = subscriptions[streamId] {
            subscription.name = name
            subscriptions[streamId] = subscription
        }
    }

    /// Renames a channel for everyone. Optimistic; the stream/update event
    /// confirms, and a refusal (permissions are server-side) rolls back.
    public func renameChannel(_ streamId: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let previous = channels[streamId]?.name ?? subscriptions[streamId]?.name
        let label = channelLabel(streamId)
        applyChannelName(streamId, trimmed)
        runAction("Couldn't rename \(label)") { connection in
            try await connection.updateStream(streamId: streamId, newName: trimmed)
        } rollback: { [weak self] in
            guard let self, let previous,
                  (self.channels[streamId]?.name ?? self.subscriptions[streamId]?.name) == trimmed
            else { return }
            self.applyChannelName(streamId, previous)
        }
    }

    /// Not optimistic: the update_message event applies the edit.
    public func editMessage(_ messageId: Int, content: String) {
        runAction("Couldn't save the edit") { connection in
            try await connection.editMessage(messageId: messageId, content: content)
        }
    }

    /// The raw Zulip markdown of a message (to prefill an edit).
    public func fetchRawContent(_ messageId: Int) async -> String? {
        try? await connection.getRawMessageContent(messageId: messageId)
    }

    /// Moves a message (and, per `propagateMode`, its topic neighbors) to
    /// another topic — and optionally another channel. Moving onto a topic
    /// that already exists merges into it.
    public func moveMessage(
        _ messageId: Int, toTopic topic: String, toChannel newStreamId: Int? = nil,
        propagateMode: String
    ) {
        runAction("Couldn't move the message") { connection in
            try await connection.moveMessage(
                messageId: messageId, newTopic: topic, newStreamId: newStreamId,
                propagateMode: propagateMode)
        }
    }

    func newestCachedMessageId(streamId: Int, topic: String) -> Int? {
        messages.values
            .filter { $0.streamId == streamId && $0.subject == topic }
            .map(\.id).max()
    }

    /// Resolves or unresolves a topic (web parity: a whole-topic move that
    /// adds or strips the ✔ prefix), anchored at its newest cached message.
    public func setTopicResolved(streamId: Int, topic: String, resolved: Bool) {
        guard TopicName.isResolved(topic) != resolved,
              let anchor = newestCachedMessageId(streamId: streamId, topic: topic)
        else { return }
        let newName = resolved
            ? TopicName.resolvedPrefix + TopicName.displayName(topic)
            : TopicName.displayName(topic)
        moveMessage(anchor, toTopic: newName, propagateMode: "change_all")
    }

    /// Renames a topic wholesale, anchored at its newest cached message; a
    /// resolved topic stays resolved under its new name.
    public func renameTopic(streamId: Int, topic: String, to newDisplayName: String) {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != TopicName.displayName(topic),
              let anchor = newestCachedMessageId(streamId: streamId, topic: topic)
        else { return }
        let newName = TopicName.isResolved(topic)
            ? TopicName.resolvedPrefix + trimmed : trimmed
        moveMessage(anchor, toTopic: newName, propagateMode: "change_all")
    }

    public func fetchReadReceipts(_ messageId: Int) async -> [Int]? {
        try? await connection.getReadReceipts(messageId: messageId)
    }

    public func fetchEditHistory(_ messageId: Int) async -> [EditHistoryEntry]? {
        try? await connection.getMessageHistory(messageId: messageId)
    }
}
