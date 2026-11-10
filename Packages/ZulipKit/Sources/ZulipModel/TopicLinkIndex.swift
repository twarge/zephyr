import Foundation
import Observation
import ZulipAPI

/// The topic menu's View Links, account-wide. The web app builds its lists
/// from the messages loaded in the current session; these come from the
/// message database's link index — every channel message ever stored, so
/// the full retained history — and opening the lists also asks the server
/// for linking messages the database has never seen.
///
/// Which topics offer View Links is held in memory (menus can't wait on a
/// query) and recomputed off the main actor once writes that may have
/// changed it reach the database.
@MainActor @Observable
public final class TopicLinkIndex {
    public typealias TopicKey = PerAccountStore.TopicKey

    /// Topics with a link to or from another conversation, each with the
    /// channels at the other ends (visibility is checked when asked).
    public private(set) var linkedTopics: [TopicKey: Set<Int>] = [:]

    @ObservationIgnored private weak var store: PerAccountStore?
    @ObservationIgnored private var backfillTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// An event since the last refresh may have changed which links exist.
    @ObservationIgnored private var stale = false
    /// When each topic last asked the server, so reopening the lists
    /// doesn't repeat the searches.
    @ObservationIgnored private var serverChecked: [TopicKey: ContinuousClock.Instant] = [:]

    /// How long a topic's server check stands before another is made.
    private static let serverRecheckInterval: Duration = .seconds(600)
    /// Linking messages fetched per server query, newest first.
    private static let serverFetchLimit = 200
    /// Messages of the topic itself fetched for its outgoing links.
    private static let serverTopicFetchLimit = 1000

    init() {}

    func attach(to store: PerAccountStore) { self.store = store }

    public nonisolated static func key(streamId: Int, topic: String) -> TopicKey {
        TopicKey(streamId: streamId, topic: TopicName.canonical(topic))
    }

    /// Whether View Links has anything to list: a link to or from another
    /// conversation, at a channel this account can still see.
    public func hasLinks(streamId: Int, topic: String) -> Bool {
        guard let store,
              let ends = linkedTopics[Self.key(streamId: streamId, topic: topic)]
        else { return false }
        return ends.contains { store.channels[$0] != nil || store.subscriptions[$0] != nil }
    }

    // MARK: Lists

    /// The lists from stored history, after any messages still waiting to
    /// be written have reached the database.
    public func lists(streamId: Int, topic: String) async -> TopicLinkLists {
        guard let store, let database = store.database else { return .empty }
        await store.flushMessageCache()
        let records = await Task.detached(priority: .userInitiated) {
            let outgoing = (try? database.links(from: streamId, topic: topic)) ?? []
            let incoming = (try? database.links(to: streamId, topic: topic)) ?? []
            return (outgoing, incoming)
        }.value
        return TopicLinkLists(
            streamId: streamId, topic: topic,
            outgoing: records.0, incoming: records.1,
            isVisible: { store.channels[$0] != nil || store.subscriptions[$0] != nil })
    }

    /// Asks the server for what the database may lack — the topic's own
    /// messages that carry links, and messages elsewhere that link here —
    /// stores the ones with conversation links, and returns the lists
    /// again. Nil when nothing was asked (checked recently) or nothing
    /// could be fetched.
    ///
    /// The topic's linked messages are one exact query (`has:link` in the
    /// topic). Messages linking here can't be asked for by target, so the
    /// search is for linked messages that mention the channel and topic
    /// names — how a topic or message link renders — in the user's own
    /// history and in public channels'; the lists keep only those that
    /// really link here. A link whose text is something else entirely, or
    /// past the newest few hundred matches, is found only once its message
    /// is stored some other way.
    public func listsIncludingServer(streamId: Int, topic: String) async -> TopicLinkLists? {
        guard let store, let database = store.database else { return nil }
        let key = Self.key(streamId: streamId, topic: topic)
        if let checked = serverChecked[key],
           ContinuousClock.now - checked < Self.serverRecheckInterval {
            return nil
        }
        let connection = store.connection
        var queries: [(narrow: [NarrowElement], limit: Int)] = [(
            [
                NarrowElement("channel", .int(streamId)),
                NarrowElement("topic", .string(topic)),
                NarrowElement("has", .string("link")),
            ],
            Self.serverTopicFetchLimit
        )]
        let channelName = store.channels[streamId]?.name
            ?? store.subscriptions[streamId]?.name ?? ""
        if let words = Self.searchWords(channel: channelName, topic: topic) {
            let search = [
                NarrowElement("has", .string("link")),
                NarrowElement("search", .string(words)),
            ]
            queries.append((search, Self.serverFetchLimit))
            queries.append((
                [NarrowElement("channels", .string("public"))] + search,
                Self.serverFetchLimit))
        }
        let fetched = await withTaskGroup(of: [Message]?.self) { group in
            for query in queries {
                group.addTask {
                    try? await connection.getMessages(
                        anchor: .newest, numBefore: query.limit, numAfter: 0,
                        narrow: query.narrow
                    ).messages
                }
            }
            var all: [Int: Message] = [:]
            var anySucceeded = false
            for await result in group {
                guard let result else { continue }
                anySucceeded = true
                for message in result { all[message.id] = message }
            }
            return anySucceeded ? Array(all.values) : nil
        }
        guard let fetched else { return nil }
        serverChecked[key] = .now

        // Search results carry highlight markup; the stored copy is the
        // plain message. Copies in memory save through the store as usual.
        let realmURL = connection.realmURL
        let relevant = fetched.compactMap { message -> Message? in
            guard message.streamId != nil, store.messages[message.id] == nil else { return nil }
            let links = TopicLink.links(inHTML: message.content, realmURL: realmURL)
            guard !links.isEmpty else { return nil }
            var plain = message
            plain.matchContent = nil
            plain.matchSubject = nil
            return plain
        }
        if !relevant.isEmpty {
            let selfId = store.selfUserId
            await database.enqueueWrite { try? $0.upsert(relevant, selfUserId: selfId) }.value
            scheduleRefresh()
        }
        return await lists(streamId: streamId, topic: topic)
    }

    /// The `search` operand for messages linking to a topic: its channel
    /// and topic names as words, which a rendered link's text holds
    /// ("#channel > topic"). Nil when the topic name has nothing to search
    /// by (the empty topic, punctuation or emoji alone).
    nonisolated static func searchWords(channel: String, topic: String) -> String? {
        func words(_ text: String) -> [String] {
            text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        let topicWords = words(TopicName.displayName(TopicName.canonical(topic)))
        guard !topicWords.isEmpty else { return nil }
        return (words(channel) + topicWords).joined(separator: " ")
    }

    // MARK: Keeping current

    /// Indexes what was stored before the link index existed — a batch at
    /// a time, at background priority, pausing between batches so other
    /// database work interleaves — then computes which topics have links.
    /// Once per store instance; a later instance resumes where it left off.
    func start() {
        guard backfillTask == nil, let database = store?.database else { return }
        backfillTask = Task { [weak self] in
            while true {
                let more = await Task.detached(priority: .utility) {
                    (try? database.backfillLinks()) ?? false
                }.value
                guard more, !Task.isCancelled, self != nil else { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            self?.scheduleRefresh(after: .zero)
        }
    }

    /// A replacement store instance starts from what this one knew, and
    /// the old one's backfill stops (this one's `start` resumes it).
    func adopt(from previous: TopicLinkIndex) {
        linkedTopics = previous.linkedTopics
        serverChecked = previous.serverChecked
        previous.backfillTask?.cancel()
    }

    func handleEvent(_ event: Event) {
        switch event.kind {
        case .message(let e):
            if e.message.streamId != nil, TopicLink.mentionsNarrow(e.message.content) {
                stale = true
            }
        case .updateMessage(let e):
            // Edits can add or drop links; moves change where links start
            // and where links to the moved messages land.
            if e.renderedContent != nil || e.subject != nil || e.newStreamId != nil {
                stale = true
            }
        case .deleteMessage:
            stale = true
        default:
            break
        }
    }

    /// A write reached the database; `touchedLinks` when it held messages
    /// with narrow links. Refreshes when that, or an event since the last
    /// refresh, may have changed the links.
    func databaseDidChange(touchedLinks: Bool) {
        guard touchedLinks || stale else { return }
        scheduleRefresh()
    }

    private func scheduleRefresh(after delay: Duration = .seconds(1)) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.stale = false
            self.refreshTask = nil
            await self.refresh()
        }
    }

    private func refresh() async {
        guard let database = store?.database else { return }
        let linked = await Task.detached(priority: .utility) {
            Self.linkedTopics(from: (try? database.allLinks()) ?? [])
        }.value
        if linked != linkedTopics {
            linkedTopics = linked
        }
    }

    /// Both ends of every link between two different conversations.
    nonisolated static func linkedTopics(
        from records: [TopicLinkRecord]
    ) -> [TopicKey: Set<Int>] {
        var linked: [TopicKey: Set<Int>] = [:]
        for record in records {
            let target = record.target
            if record.fromStreamId == target.streamId,
               TopicName.matches(record.fromTopic, target.topic) {
                continue
            }
            linked[key(streamId: record.fromStreamId, topic: record.fromTopic), default: []]
                .insert(target.streamId)
            linked[key(streamId: target.streamId, topic: target.topic), default: []]
                .insert(record.fromStreamId)
        }
        return linked
    }
}
