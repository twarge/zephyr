import SwiftUI
import ZulipAPI
import ZulipContent
import ZulipModel

/// The monitor: pick a channel once, then a big-type live feed. Polls
/// render as tally boards; nothing is marked read.
struct TVMonitorView: View {
    let store: PerAccountStore

    @Environment(TVSession.self) private var session
    @AppStorage("tvChannelId") private var channelId = 0

    private var channel: Subscription? {
        store.subscriptions[channelId]
    }

    var body: some View {
        if let channel {
            TVChannelFeed(store: store, channel: channel) {
                channelId = 0
            } signOut: {
                session.signOut()
            }
        } else {
            TVChannelPicker(store: store) { picked in
                channelId = picked
            }
        }
    }
}

private struct TVChannelPicker: View {
    let store: PerAccountStore
    var pick: (Int) -> Void

    private var channels: [Subscription] {
        store.subscriptions.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a channel to monitor")
                .font(.title2.weight(.semibold))
            List(channels, id: \.streamId) { subscription in
                Button {
                    pick(subscription.streamId)
                } label: {
                    HStack {
                        Text("#\(subscription.name)")
                        Spacer()
                        if let count = store.unreads.unreadIds.reduce(0, { total, entry in
                            if case .topic(let id, _) = entry.key, id == subscription.streamId {
                                return total + entry.value.count
                            }
                            return total
                        }) as Int?, count > 0 {
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(48)
    }
}

private struct TVChannelFeed: View {
    let store: PerAccountStore
    let channel: Subscription
    var changeChannel: () -> Void
    var signOut: () -> Void

    @State private var model: MessageListModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(channel.name)")
                    .font(.largeTitle.weight(.semibold))
                Text(store.realmName ?? "")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Channel", action: changeChannel)
                Button("Sign Out", action: signOut)
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 24)
            if let model, model.didInitialFetch {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(model.messages.suffix(40)) { message in
                            TVMessageRow(store: store, message: message)
                        }
                    }
                    .padding(.horizontal, 64)
                    .padding(.bottom, 48)
                }
                .defaultScrollAnchor(.bottom)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: channel.streamId) {
            let list = MessageListModel(
                store: store, narrow: .channel(streamId: channel.streamId))
            model = list
            await list.fetchInitial(count: 60)
        }
    }
}

private struct TVMessageRow: View {
    let store: PerAccountStore
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(message.senderFullName)
                    .font(.title3.weight(.semibold))
                Text(TopicName.displayName(message.topic))
                    .font(.title3)
                    .foregroundStyle(.tint)
                Spacer()
                Text(
                    Date(timeIntervalSince1970: TimeInterval(message.timestamp))
                        .formatted(date: .omitted, time: .shortened))
                    .font(.title3.smallCaps())
                    .foregroundStyle(.secondary)
            }
            if let widget = MessageWidget.parse(message) {
                switch widget {
                case .poll(let poll):
                    TVPollBoard(poll: poll)
                case .todoList(let list):
                    TVTodoBoard(list: list)
                }
            } else {
                Text(ContentParser.parse(html: message.content).plainText)
                    .font(.title2)
                    .lineLimit(8)
            }
        }
    }
}

/// A poll as a live tally board: counts and proportional bars.
private struct TVPollBoard: View {
    let poll: MessageWidget.Poll

    private var maxVotes: Int {
        max(poll.options.map(\.voterIds.count).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !poll.question.isEmpty {
                Text(poll.question)
                    .font(.title.weight(.semibold))
            }
            ForEach(poll.options, id: \.key) { option in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(option.text)
                            .font(.title2)
                        Spacer()
                        Text("\(option.voterIds.count)")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)
                            Capsule()
                                .fill(.tint)
                                .frame(
                                    width: proxy.size.width
                                        * CGFloat(option.voterIds.count) / CGFloat(maxVotes))
                        }
                    }
                    .frame(height: 14)
                }
            }
        }
        .padding(28)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct TVTodoBoard: View {
    let list: MessageWidget.TodoList

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(list.title ?? "To-do list")
                .font(.title.weight(.semibold))
            ForEach(list.tasks, id: \.key) { task in
                HStack(spacing: 12) {
                    Image(systemName: task.completed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(task.completed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(task.title)
                        .font(.title2)
                        .strikethrough(task.completed)
                        .foregroundStyle(task.completed ? .secondary : .primary)
                }
            }
        }
        .padding(28)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }
}
