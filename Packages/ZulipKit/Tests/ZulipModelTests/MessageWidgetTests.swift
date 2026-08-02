import Foundation
import Testing
import ZulipAPI
@testable import ZulipModel

struct MessageWidgetTests {
    private func message(submessages: [(senderId: Int, content: String)]) throws -> Message {
        let subs = submessages
            .map { entry in
                let escaped = entry.content
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return #"{"msg_type": "widget", "sender_id": \#(entry.senderId), "content": "\#(escaped)"}"#
            }
            .joined(separator: ", ")
        let json = """
            {"id": 1, "sender_id": 5, "sender_full_name": "Poller", "timestamp": 1750000000,
             "type": "stream", "content": "<p>/poll</p>", "stream_id": 10, "subject": "t",
             "display_recipient": "general", "reactions": [], "submessages": [\(subs)]}
            """
        return try ZulipJSON.decoder.decode(Message.self, from: Data(json.utf8))
    }

    @Test func pollWithVotesAndNewOptions() throws {
        let msg = try message(submessages: [
            (5, #"{"widget_type": "poll", "extra_data": {"question": "Lunch?", "options": ["Pizza", "Sushi"]}}"#),
            (7, #"{"type": "vote", "key": "canned,0", "vote": 1}"#),
            (8, #"{"type": "vote", "key": "canned,0", "vote": 1}"#),
            (7, #"{"type": "new_option", "idx": 0, "option": "Salad"}"#),
            (8, #"{"type": "vote", "key": "7,0", "vote": 1}"#),
            (7, #"{"type": "vote", "key": "canned,0", "vote": -1}"#),
        ])
        guard case .poll(let poll) = MessageWidget.parse(msg) else {
            Issue.record("expected poll")
            return
        }
        #expect(poll.question == "Lunch?")
        #expect(poll.options.map(\.text) == ["Pizza", "Sushi", "Salad"])
        #expect(poll.options[0].voterIds == [8])  // 7 voted then retracted
        #expect(poll.options[1].voterIds.isEmpty)
        #expect(poll.options[2].voterIds == [8])
    }

    @Test func todoListWithStrikes() throws {
        let msg = try message(submessages: [
            (5, #"{"widget_type": "todo", "extra_data": {"task_list_title": "Release", "tasks": [{"task": "Tag build", "desc": ""}, {"task": "Write notes", "desc": "changelog"}]}}"#),
            (5, #"{"type": "strike", "key": "canned,0"}"#),
        ])
        guard case .todoList(let list) = MessageWidget.parse(msg) else {
            Issue.record("expected todo list")
            return
        }
        #expect(list.title == "Release")
        #expect(list.tasks.count == 2)
        #expect(list.tasks[0].completed)
        #expect(!list.tasks[1].completed)
        #expect(list.tasks[1].detail == "changelog")
    }

    @Test func nonWidgetMessagesParseAsNil() throws {
        let plain = try message(submessages: [])
        #expect(MessageWidget.parse(plain) == nil)
    }
}
