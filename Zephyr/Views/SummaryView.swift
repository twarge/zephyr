import SwiftUI
import ZulipAPI
import ZulipModel

struct SummaryView: View {
    let store: PerAccountStore
    let search: SidebarSearchModel
    @Binding var selection: Destination?
    @Environment(KeyboardRouter.self) private var keys
    @Environment(\.scenePhase) private var scenePhase
    @State private var limit = 30

    /// How often the visible rows re-check the server while the window is
    /// frontmost. Events keep the list itself current; this pass covers
    /// what they cannot report — a reply or reaction of yours on another
    /// device, and a mention target that moved while the app was away.
    private static let refreshInterval = Duration.seconds(300)
    /// Delay before the first retry of a failed pass; each further failure
    /// doubles it, up to `refreshInterval`.
    private static let firstRetry = Duration.seconds(15)

    private var allRows: [TopicActivity] {
        let filter = search.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.topicActivity.activities.filter { activity in
            guard store.topicActivity.isVisible(activity, in: store) else { return false }
            return filter.isEmpty || activity.topic.localizedCaseInsensitiveContains(filter)
                || channelName(activity.id.streamId).localizedCaseInsensitiveContains(filter)
        }
    }

    private func channelName(_ id: Int) -> String {
        store.subscriptions[id]?.name ?? store.channels[id]?.name ?? "Channel"
    }

    /// One pass over the unread map per render rather than one per row.
    /// `unreadIds` is keyed by the server's topic spelling, so each entry
    /// has to be canonicalized before it can match a Summary row.
    private var unreadCounts: [TopicActivityID: Int] {
        store.unreads.unreadIds.reduce(into: [:]) { counts, entry in
            guard case .topic(let stream, let topic) = entry.key else { return }
            counts[TopicActivityID(streamId: stream, topic: topic), default: 0] += entry.value.count
        }
    }

    var body: some View {
        let rows = allRows
        let shown = Array(rows.prefix(limit))
        let unread = unreadCounts
        // Rows an event has un-verified re-check themselves: this set
        // grows the moment one does, which is the task's identity.
        let unverified = Set(shown.map(\.id)).subtracting(store.topicActivity.verifiedTopics)
        return VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent channel activity").font(.headline)
                    Text(TopicSummaryService.shared.availabilityMessage
                         ?? "On-device AI summaries can be wrong.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.topicActivity.refreshFailed || store.isRecoveringEventStream {
                        Text("Showing saved activity. Checking again automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if store.topicActivity.historyIsLimited {
                        Text("Some older activity isn’t included.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.topicActivity.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(16)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(
                    store.topicActivity.isLoading ? "Loading Recent Activity" : "No Recent Topics",
                    systemImage: "newspaper",
                    description: Text(search.filterText.isEmpty
                        ? "Activity from your channels and unanswered mentions will appear here."
                        : "No channels or topics match your search."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(shown) { activity in
                        SummaryTopicRow(
                            store: store, activity: activity,
                            channelName: channelName(activity.id.streamId),
                            unreadCount: unread[activity.id] ?? 0,
                            generatesSummaries: scenePhase == .active
                        ) { open(activity) }
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                    if rows.count > limit {
                        Button("More topics…") { limit += 30 }
                    }
                }
                .listStyle(.plain)
            }
        }
        .serverTitled("Summary", store: store)
        // Refreshing is the view's own job: the pass runs when Summary
        // appears, on every return to the front, and on its own clock
        // while it stays there. A failed pass retries on a backoff rather
        // than waiting for a person to ask again.
        .task(id: AutoRefresh(limit: limit, active: scenePhase == .active)) {
            guard scenePhase == .active else { return }
            var failures = 0
            while !Task.isCancelled {
                await store.topicActivity.refresh(limit: limit)
                failures = store.topicActivity.refreshFailed ? failures + 1 : 0
                let delay = failures == 0
                    ? Self.refreshInterval
                    : min(Self.refreshInterval, Self.firstRetry * (1 << min(failures - 1, 5)))
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
        .task(id: unverified) {
            guard !unverified.isEmpty else { return }
            // Rows verify in bursts as a pass lands. Letting the set settle
            // keeps that from restarting this check on every one of them.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await store.topicActivity.verifyVisible(unverified)
        }
        .onChange(of: store.isRecoveringEventStream) { wasRecovering, recovering in
            if wasRecovering && !recovering {
                Task { await store.topicActivity.refresh(limit: limit, force: true) }
            }
        }
    }

    private func open(_ activity: TopicActivity) {
        let near = activity.unansweredMentionIds.first
        if let near {
            keys.highlightMessageId = near
            keys.pendingNear = (activity.conversation, near)
        }
        // The existing transcript handles first-unread anchoring and owns
        // every reply/reaction action. Summary never marks a message read.
        selection = .conversation(activity.conversation)
    }

    /// Restarts the refresh loop when the row budget changes or the window
    /// comes back to the front; going away cancels it.
    private struct AutoRefresh: Equatable {
        let limit: Int
        let active: Bool
    }
}

private struct SummaryTopicRow: View {
    let store: PerAccountStore
    let activity: TopicActivity
    let channelName: String
    let unreadCount: Int
    let generatesSummaries: Bool
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var prepared: PreparedTopicSummary?
    @State private var preparedRevision: [SummarySourceRevision] = []

    private var sourceRevision: [SummarySourceRevision] {
        activity.messages.map(SummarySourceRevision.init)
    }

    private var currentInput: PreparedTopicSummary? {
        preparedRevision == sourceRevision ? prepared : nil
    }

    private var summaryText: String? {
        guard let input = currentInput, let summary = store.topicActivity.summaries[activity.id],
              summary.fingerprint == input.fingerprint else { return nil }
        return summary.text
    }

    private var statusText: String {
        var parts: [String] = []
        if !activity.unansweredMentionIds.isEmpty {
            if activity.needsReactionReview {
                parts.append("Check response to edited mention")
            } else {
                parts.append(store.topicActivity.verifiedTopics.contains(activity.id)
                    ? "Mention awaiting response" : "Mention · checking replies")
            }
        }
        if unreadCount > 0 { parts.append("\(unreadCount) unseen") }
        if activity.hasReplied { parts.append("You replied") }
        else if activity.hasReacted { parts.append("You reacted") }
        if parts.isEmpty { parts.append("Seen") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                indicator.frame(width: 12, height: 20)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(Text("# \(channelName) › ").foregroundStyle(.secondary))\(Text(TopicName.displayName(activity.topic)).bold())")
                        Spacer(minLength: 0)
                        Text(Date(timeIntervalSince1970: TimeInterval(activity.timestamp)), style: .relative)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(summaryText ?? currentInput.map { "Latest message: \($0.preview)" }
                         ?? "Loading recent messages…")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the conversation to reply or react")
        .task(id: WorkID(source: sourceRevision, active: generatesSummaries,
                         available: TopicSummaryService.shared.availabilityMessage == nil)) {
            let source = sourceRevision
            let language = Locale.current.identifier
            let input = await Task.detached(priority: .utility) {
                PreparedTopicSummary.prepare(source, language: language)
            }.value
            guard !Task.isCancelled else { return }
            prepared = input
            preparedRevision = source
            guard generatesSummaries, TopicSummaryService.shared.availabilityMessage == nil,
                  input.sourceIds.count > 1, summaryText == nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(400))
                let text = try await TopicSummaryService.shared.summarize(input, account: store.accountId)
                try Task.checkCancellation()
                guard preparedRevision == source else { return }
                store.topicActivity.saveSummary(TopicSummary(
                    topic: activity.id, fingerprint: input.fingerprint,
                    text: text, sourceIds: activity.messages.map(\.id)), source: activity.messages)
            } catch {
                // A useful latest-message preview remains for refusals,
                // unsupported languages, unavailable models and errors.
            }
        }
    }

    @ViewBuilder private var indicator: some View {
        switch activity.indicator(unreadCount: unreadCount) {
        case .awaitingResponse: Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
        case .unseen: Circle().fill(.blue).frame(width: 8, height: 8).accessibilityHidden(true)
        case .participated:
            Image(systemName: "checkmark").font(.caption.weight(.semibold))
                .foregroundStyle(.green).accessibilityHidden(true)
        case .seen: Color.clear.accessibilityHidden(true)
        }
    }

    private struct WorkID: Equatable {
        let source: [SummarySourceRevision]
        let active: Bool
        let available: Bool
    }
}
