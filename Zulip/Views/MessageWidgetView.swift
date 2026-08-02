import SwiftUI
import ZulipModel

/// Read-only rendering of poll and todo-list widgets (voting/editing is a
/// later milestone).
struct MessageWidgetView: View {
    let widget: MessageWidget
    let store: PerAccountStore

    var body: some View {
        switch widget {
        case .poll(let poll):
            PollView(poll: poll, store: store)
        case .todoList(let list):
            TodoListView(list: list)
        }
    }
}

private struct PollView: View {
    let poll: MessageWidget.Poll
    let store: PerAccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                poll.question.isEmpty ? "Poll" : poll.question,
                systemImage: "chart.bar.xaxis")
                .font(.callout.weight(.semibold))
            ForEach(poll.options, id: \.key) { option in
                HStack(spacing: 8) {
                    Text("\(option.voterIds.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(minWidth: 22)
                        .padding(.vertical, 2)
                        .background(
                            option.voterIds.contains(store.selfUserId)
                                ? AnyShapeStyle(.tint.opacity(0.3))
                                : AnyShapeStyle(.quaternary),
                            in: .capsule)
                    Text(option.text)
                        .font(.callout)
                    Spacer(minLength: 0)
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(list.title ?? "To-do list", systemImage: "checklist")
                .font(.callout.weight(.semibold))
            ForEach(list.tasks, id: \.key) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.completed ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
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
