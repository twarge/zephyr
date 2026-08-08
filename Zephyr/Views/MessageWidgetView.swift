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

    @State private var newOption = ""
    @State private var editedQuestion = ""
    @State private var showQuestionEditor = false

    /// Only the poll's author can set or change the question (web parity).
    private var isAuthor: Bool {
        store.messages[messageId]?.senderId == store.selfUserId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(poll.question.isEmpty ? "Poll" : poll.question)
                    .font(.body.weight(.semibold))
                if isAuthor {
                    Button {
                        editedQuestion = poll.question
                        showQuestionEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(poll.question.isEmpty ? "Add a question" : "Edit the question")
                    .popover(isPresented: $showQuestionEditor) {
                        HStack(spacing: 8) {
                            TextField("Question", text: $editedQuestion)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .onSubmit(saveQuestion)
                            Button("Save", action: saveQuestion)
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(10)
                    }
                }
            }
            ForEach(poll.options, id: \.key) { option in
                let voted = option.voterIds.contains(store.selfUserId)
                Button {
                    store.voteInPoll(
                        messageId: messageId, optionKey: option.key, vote: !voted)
                } label: {
                    HStack(spacing: 8) {
                        Text("\(option.voterIds.count)")
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 22)
                            .padding(.vertical, 2)
                            .background(
                                voted
                                    ? AnyShapeStyle(.tint.opacity(0.3))
                                    : AnyShapeStyle(.quaternary),
                                in: .capsule)
                        Text(option.text)
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(helpText(option: option, voted: voted))
            }
            if poll.options.isEmpty {
                Text("No options yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            // Anyone can extend the poll, like the web widget.
            HStack(spacing: 6) {
                TextField("New option", text: $newOption)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addOption)
                Button("Add", action: addOption)
                    .disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func helpText(option: MessageWidget.Poll.Option, voted: Bool) -> String {
        let action = voted ? "Retract your vote" : "Vote for this option"
        guard !option.voterIds.isEmpty else { return action }
        let names = option.voterIds
            .map { store.users[$0]?.fullName ?? "User \($0)" }
            .joined(separator: ", ")
        return "\(names) — \(action.lowercased())"
    }

    private func addOption() {
        let trimmed = newOption.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.addPollOption(messageId: messageId, option: trimmed)
        newOption = ""
    }

    private func saveQuestion() {
        store.setPollQuestion(
            messageId: messageId,
            question: editedQuestion.trimmingCharacters(in: .whitespaces))
        showQuestionEditor = false
    }
}

private struct TodoListView: View {
    let list: MessageWidget.TodoList
    let store: PerAccountStore
    let messageId: Int

    @State private var newTask = ""
    @State private var newTaskNote = ""
    @State private var editedTitle = ""
    @State private var showTitleEditor = false

    /// Only the list's author can rename it (web parity).
    private var isAuthor: Bool {
        store.messages[messageId]?.senderId == store.selfUserId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(list.title ?? "To-do list")
                    .font(.body.weight(.semibold))
                if isAuthor {
                    Button {
                        editedTitle = list.title ?? ""
                        showTitleEditor = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit the title")
                    .popover(isPresented: $showTitleEditor) {
                        HStack(spacing: 8) {
                            TextField("Title", text: $editedTitle)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .onSubmit(saveTitle)
                            Button("Save", action: saveTitle)
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(10)
                    }
                }
            }
            ForEach(list.tasks, id: \.key) { task in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // The native checkbox (system control colors); the
                    // binding's set is the strike toggle.
                    #if os(macOS)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { task.completed },
                            set: { _ in
                                store.strikeTodoTask(messageId: messageId, taskKey: task.key)
                            }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    #else
                    Image(systemName: task.completed ? "checkmark.square.fill" : "square")
                        .foregroundStyle(.tint)
                    #endif
                    // One line, web-style: "Title: note".
                    taskLine(task)
                        .font(.body)
                        .strikethrough(task.completed)
                        .foregroundStyle(task.completed ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
                .onTapGesture {
                    store.strikeTodoTask(messageId: messageId, taskKey: task.key)
                }
                .help(task.completed ? "Mark as not done" : "Mark as done")
            }
            if list.tasks.isEmpty {
                Text("No tasks yet")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            // Anyone can extend the list, like the web widget.
            HStack(spacing: 6) {
                TextField("New task", text: $newTask)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)
                TextField("Note (optional)", text: $newTaskNote)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                    .onSubmit(addTask)
                Button("Add", action: addTask)
                    .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func taskLine(_ task: MessageWidget.TodoList.Task) -> Text {
        var line = Text(task.title).fontWeight(.semibold)
        if let detail = task.detail {
            line = line + Text(": \(detail)")
        }
        return line
    }

    private func addTask() {
        let trimmed = newTask.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let note = newTaskNote.trimmingCharacters(in: .whitespaces)
        store.addTodoTask(
            messageId: messageId, task: trimmed, detail: note.isEmpty ? nil : note)
        newTask = ""
        newTaskNote = ""
    }

    private func saveTitle() {
        store.setTodoListTitle(
            messageId: messageId,
            title: editedTitle.trimmingCharacters(in: .whitespaces))
        showTitleEditor = false
    }
}
