import Foundation
import ZulipAPI
import ZulipModel

/// Two-way sync between the local DraftStore and the server's /drafts API
/// for one account: reconcile at connect, debounce local edits up, apply
/// remote events down. Newer edit wins on conflict; ambiguity never
/// destroys local text.
@MainActor
final class DraftSyncEngine {
    private let accountId: Account.ID
    private weak var store: PerAccountStore?
    private var pushTasks: [SendDestination: Task<Void, Never>] = [:]
    /// Last text pushed or adopted per destination — distinguishes echoes
    /// of our own writes from genuine remote edits.
    private var lastSynced: [SendDestination: String] = [:]

    init(accountId: Account.ID, store: PerAccountStore) {
        self.accountId = accountId
        self.store = store
        store.draftEventObserver = { [weak self] change in
            self?.apply(change)
        }
        reconcile()
    }

    static func destination(of draft: ServerDraft) -> SendDestination? {
        switch draft.type {
        case "stream":
            guard let streamId = draft.to.first else { return nil }
            return .topic(streamId: streamId, topic: draft.topic)
        case "private":
            guard !draft.to.isEmpty else { return nil }
            return .dm(userIds: draft.to)
        default:
            return nil
        }
    }

    private func payload(_ destination: SendDestination, text: String) -> ServerDraft {
        switch destination {
        case .topic(let streamId, let topic):
            ServerDraft(type: "stream", to: [streamId], topic: topic, content: text)
        case .dm(let userIds):
            ServerDraft(type: "private", to: userIds, topic: "", content: text)
        }
    }

    /// Connect-time reconcile: per destination, the newer edit wins;
    /// local-only drafts push up; unknown server drafts adopt down.
    private func reconcile() {
        guard let store else { return }
        let drafts = DraftStore.shared
        var seen: Set<SendDestination> = []
        for (id, serverDraft) in store.serverDrafts {
            guard let destination = Self.destination(of: serverDraft) else { continue }
            seen.insert(destination)
            let serverDate = Date(timeIntervalSince1970: serverDraft.timestamp ?? 0)
            if let local = drafts.entries(account: accountId)[destination] {
                if local.text == serverDraft.content {
                    drafts.setServerId(id, for: destination, account: accountId)
                    lastSynced[destination] = local.text
                } else if local.updatedAt > serverDate {
                    drafts.setServerId(id, for: destination, account: accountId)
                    schedulePush(destination, text: local.text, delay: .milliseconds(100))
                } else {
                    drafts.adoptServer(
                        serverDraft.content, serverId: id, updatedAt: serverDate,
                        for: destination, account: accountId)
                    lastSynced[destination] = serverDraft.content
                }
            } else {
                drafts.adoptServer(
                    serverDraft.content, serverId: id, updatedAt: serverDate,
                    for: destination, account: accountId)
                lastSynced[destination] = serverDraft.content
            }
        }
        // Local drafts the server doesn't know: push. A stale server id
        // (deleted elsewhere) is dropped but the text re-creates — data
        // safety over dedup.
        for (destination, entry) in drafts.entries(account: accountId)
        where !seen.contains(destination) {
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                drafts.removeEntry(for: destination, account: accountId)
                continue
            }
            if entry.serverId != nil {
                drafts.setServerId(nil, for: destination, account: accountId)
            }
            schedulePush(destination, text: entry.text, delay: .milliseconds(100))
        }
    }

    func localEdited(_ destination: SendDestination, text: String) {
        schedulePush(destination, text: text, delay: .seconds(1.5))
    }

    private func schedulePush(
        _ destination: SendDestination, text: String, delay: Duration
    ) {
        pushTasks[destination]?.cancel()
        pushTasks[destination] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.push(destination, text: text)
        }
    }

    private func push(_ destination: SendDestination, text: String) async {
        guard let store else { return }
        let drafts = DraftStore.shared
        let serverId = drafts.entries(account: accountId)[destination]?.serverId
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let serverId {
                try? await store.connection.deleteDraft(id: serverId)
            }
            drafts.removeEntry(for: destination, account: accountId)
            lastSynced[destination] = nil
            return
        }
        lastSynced[destination] = text
        if let serverId {
            try? await store.connection.editDraft(
                id: serverId, payload(destination, text: text))
        } else if let id = try? await store.connection.createDraft(
            payload(destination, text: text)) {
            drafts.setServerId(id, for: destination, account: accountId)
        }
    }

    /// Remote changes (including echoes of our own pushes).
    private func apply(_ change: PerAccountStore.DraftChange) {
        let drafts = DraftStore.shared
        switch change {
        case .added(let added):
            for draft in added {
                applyUpsert(draft)
            }
        case .updated(let draft):
            applyUpsert(draft)
        case .removed(let id):
            guard let (destination, entry) = drafts.entries(account: accountId)
                .first(where: { $0.value.serverId == id })
            else { return }
            // Recent local typing survives a remote delete (re-created).
            if entry.updatedAt > Date.now.addingTimeInterval(-3), !entry.text.isEmpty {
                drafts.setServerId(nil, for: destination, account: accountId)
                schedulePush(destination, text: entry.text, delay: .seconds(1.5))
            } else {
                drafts.removeEntry(for: destination, account: accountId)
                lastSynced[destination] = nil
            }
        }
    }

    private func applyUpsert(_ draft: ServerDraft) {
        guard let id = draft.id, let destination = Self.destination(of: draft)
        else { return }
        let drafts = DraftStore.shared
        if lastSynced[destination] == draft.content {
            drafts.setServerId(id, for: destination, account: accountId)
            return  // Echo of our own push.
        }
        if let local = drafts.entries(account: accountId)[destination],
           local.updatedAt > Date.now.addingTimeInterval(-3),
           local.text != draft.content {
            // Mid-typing here: keep ours, push it over the remote edit.
            drafts.setServerId(id, for: destination, account: accountId)
            schedulePush(destination, text: local.text, delay: .seconds(1.5))
            return
        }
        drafts.adoptServer(
            draft.content, serverId: id,
            updatedAt: Date(
                timeIntervalSince1970: draft.timestamp ?? Date.now.timeIntervalSince1970),
            for: destination, account: accountId)
        lastSynced[destination] = draft.content
    }
}
