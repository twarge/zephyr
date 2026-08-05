import SwiftUI
import ZulipModel

/// Poll and todo-list widgets: live-updating (submessage events) and
/// interactive — tap an option to vote, a checkbox to strike.
struct MessageWidgetView: View {
    let widget: MessageWidget
    let store: PerAccountStore
    let messageId: Int

    var body: some View {
        switch widget {
        case .poll(let poll):
            PollView(poll: poll, store: store, messageId: messageId)
        case .todoList(let list):
            TodoListView(list: list, store: store, messageId: messageId)
        }
    }
}

private struct PollView: View {
    let poll: MessageWidget.Poll
    let store: PerAccountStore
    let messageId: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                poll.question.isEmpty ? "Poll" : poll.question,
                systemImage: "chart.bar.xaxis")
                .font(.callout.weight(.semibold))
            ForEach(poll.options, id: \.key) { option in
                let voted = option.voterIds.contains(store.selfUserId)
                Button {
                    store.voteInPoll(
                        messageId: messageId, optionKey: option.key, vote: !voted)
                } label: {
                    HStack(spacing: 8) {
                        Text("\(option.voterIds.count)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 22)
                            .padding(.vertical, 2)
                            .background(
                                voted
                                    ? AnyShapeStyle(.tint.opacity(0.3))
                                    : AnyShapeStyle(.quaternary),
                                in: .capsule)
                        Text(option.text)
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(voted ? "Retract your vote" : "Vote for this option")
            }
            if poll.options.isEmpty {
                Text("No options yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TodoListView: View {
    let list: MessageWidget.TodoList
    let store: PerAccountStore
    let messageId: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(list.title ?? "To-do list", systemImage: "checklist")
                .font(.callout.weight(.semibold))
            ForEach(list.tasks, id: \.key) { task in
                Button {
                    store.strikeTodoTask(messageId: messageId, taskKey: task.key)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                task.completed
                                    ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title)
                                .font(.callout)
                                .strikethrough(task.completed)
                                .foregroundStyle(task.completed ? .secondary : .primary)
                            if let detail = task.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(task.completed ? "Mark as not done" : "Mark as done")
            }
            if list.tasks.isEmpty {
                Text("No tasks yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
