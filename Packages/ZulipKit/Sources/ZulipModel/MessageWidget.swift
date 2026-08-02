import Foundation
import ZulipAPI

/// Polls and todo lists aren't HTML — they're "widget" submessages: the first
/// declares the widget and its initial data, later ones are events (votes,
/// new options, strikes). This rebuilds the current state by replaying them,
/// following the web app's shared widget-data logic (option keys are
/// "\(senderId),\(idx)"; initial options use the "canned" sender).
public enum MessageWidget: Sendable, Equatable {
    case poll(Poll)
    case todoList(TodoList)

    public struct Poll: Sendable, Equatable {
        public struct Option: Sendable, Equatable {
            public var key: String
            public var text: String
            public var voterIds: [Int]
        }

        public var question: String
        public var options: [Option]
    }

    public struct TodoList: Sendable, Equatable {
        public struct Task: Sendable, Equatable {
            public var key: String
            public var title: String
            public var detail: String?
            public var completed: Bool
        }

        public var title: String?
        public var tasks: [Task]
    }

    public static func parse(_ message: Message) -> MessageWidget? {
        guard let submessages = message.submessages,
              let first = submessages.first(where: { $0.msgType == "widget" }),
              let initial = json(first.content),
              let widgetType = initial["widget_type"] as? String
        else { return nil }
        let updates = submessages.dropFirst()
        switch widgetType {
        case "poll":
            return .poll(buildPoll(initial: initial, updates: updates))
        case "todo":
            return .todoList(buildTodoList(initial: initial, updates: updates))
        default:
            return nil
        }
    }

    private static func json(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func buildPoll(
        initial: [String: Any], updates: ArraySlice<Submessage>
    ) -> Poll {
        let extra = initial["extra_data"] as? [String: Any]
        var question = extra?["question"] as? String ?? ""
        var options: [Poll.Option] = []
        var votes: [String: [Int]] = [:]

        for (index, text) in ((extra?["options"] as? [String]) ?? []).enumerated() {
            options.append(Poll.Option(key: "canned,\(index)", text: text, voterIds: []))
        }
        var newOptionCounters: [Int: Int] = [:]

        for submessage in updates where submessage.msgType == "widget" {
            guard let event = json(submessage.content),
                  let type = event["type"] as? String else { continue }
            switch type {
            case "question":
                question = event["question"] as? String ?? question
            case "new_option":
                guard let text = event["option"] as? String else { continue }
                // Keys use the sender's own per-user counter.
                let counter = event["idx"] as? Int
                    ?? newOptionCounters[submessage.senderId, default: 0]
                newOptionCounters[submessage.senderId] = counter + 1
                let key = "\(submessage.senderId),\(counter)"
                if !options.contains(where: { $0.key == key }) {
                    options.append(Poll.Option(key: key, text: text, voterIds: []))
                }
            case "vote":
                guard let key = event["key"] as? String,
                      let direction = event["vote"] as? Int else { continue }
                var voters = votes[key] ?? []
                if direction > 0 {
                    if !voters.contains(submessage.senderId) {
                        voters.append(submessage.senderId)
                    }
                } else {
                    voters.removeAll { $0 == submessage.senderId }
                }
                votes[key] = voters
            default:
                continue
            }
        }
        for index in options.indices {
            options[index].voterIds = votes[options[index].key] ?? []
        }
        return Poll(question: question, options: options)
    }

    private static func buildTodoList(
        initial: [String: Any], updates: ArraySlice<Submessage>
    ) -> TodoList {
        let extra = initial["extra_data"] as? [String: Any]
        let title = (extra?["task_list_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var tasks: [TodoList.Task] = []
        var struck: Set<String> = []

        for (index, task) in ((extra?["tasks"] as? [[String: Any]]) ?? []).enumerated() {
            guard let name = task["task"] as? String else { continue }
            tasks.append(
                TodoList.Task(
                    key: "canned,\(index)",
                    title: name,
                    detail: (task["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    completed: false))
        }

        for submessage in updates where submessage.msgType == "widget" {
            guard let event = json(submessage.content),
                  let type = event["type"] as? String else { continue }
            switch type {
            case "new_task":
                guard let name = event["task"] as? String else { continue }
                let counter = event["key"] as? Int ?? tasks.count
                let key = "\(submessage.senderId),\(counter)"
                if !tasks.contains(where: { $0.key == key }) {
                    tasks.append(
                        TodoList.Task(
                            key: key,
                            title: name,
                            detail: (event["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            completed: false))
                }
            case "strike":
                guard let key = event["key"] as? String else { continue }
                if struck.contains(key) {
                    struck.remove(key)
                } else {
                    struck.insert(key)
                }
            default:
                continue
            }
        }
        for index in tasks.indices {
            tasks[index].completed = struck.contains(tasks[index].key)
        }
        return TodoList(title: title, tasks: tasks)
    }
}
