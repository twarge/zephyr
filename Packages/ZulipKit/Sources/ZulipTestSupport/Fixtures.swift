import Foundation

/// Canned server responses for tests. Conventions: self user is id 1
/// ("Self"), a second user is id 2 ("Other"), channel 10 is #general.
public enum Fixtures {
    public static func serverSettingsJSON(featureLevel: Int = 400, version: String = "12.0") -> String {
        """
        {"result": "success", "msg": "",
         "zulip_version": "\(version)", "zulip_feature_level": \(featureLevel),
         "realm_url": "https://test.example", "realm_name": "Test Realm",
         "email_auth_enabled": true, "external_authentication_methods": []}
        """
    }

    public static func registerJSON(
        queueId: String,
        lastEventId: Int = -1,
        featureLevel: Int = 400,
        unreadMsgs: String = emptyUnreadsJSON
    ) -> String {
        """
        {"result": "success", "msg": "",
         "queue_id": "\(queueId)", "last_event_id": \(lastEventId),
         "zulip_version": "12.0", "zulip_feature_level": \(featureLevel),
         "event_queue_longpoll_timeout_seconds": 90,
         "realm_name": "Test Realm", "max_message_length": 10000,
         "realm_users": [
            {"user_id": 1, "email": "self@example.com", "full_name": "Self", "is_bot": false, "is_active": true},
            {"user_id": 2, "email": "other@example.com", "full_name": "Other", "is_bot": false, "is_active": true}
         ],
         "streams": [
            {"stream_id": 10, "name": "general", "description": "", "invite_only": false}
         ],
         "subscriptions": [
            {"stream_id": 10, "name": "general", "description": "", "color": "#c2c2c2", "is_muted": false}
         ],
         "unread_msgs": \(unreadMsgs)}
        """
    }

    public static let emptyUnreadsJSON = """
        {"count": 0, "pms": [], "streams": [], "huddles": [], "mentions": [],
         "old_unreads_missing": false}
        """

    public static func channelMessageJSON(
        id: Int,
        senderId: Int = 2,
        senderName: String = "Other",
        streamId: Int = 10,
        channelName: String = "general",
        topic: String = "greetings",
        content: String = "<p>hello</p>",
        flags: [String]? = nil
    ) -> String {
        let flagsField = flags.map { ", \"flags\": \(jsonStringArray($0))" } ?? ""
        return """
        {"id": \(id), "sender_id": \(senderId), "sender_full_name": "\(senderName)",
         "timestamp": 1750000000, "type": "stream",
         "content": "\(content.replacingOccurrences(of: "\"", with: "\\\""))",
         "content_type": "text/html",
         "stream_id": \(streamId), "subject": "\(topic)",
         "display_recipient": "\(channelName)", "reactions": []\(flagsField)}
        """
    }

    public static func dmMessageJSON(
        id: Int,
        senderId: Int = 2,
        senderName: String = "Other",
        recipientIds: [Int] = [1, 2],
        content: String = "<p>psst</p>",
        flags: [String]? = nil
    ) -> String {
        let recipients = recipientIds
            .map { "{\"id\": \($0), \"email\": \"u\($0)@example.com\", \"full_name\": \"U\($0)\"}" }
            .joined(separator: ", ")
        let flagsField = flags.map { ", \"flags\": \(jsonStringArray($0))" } ?? ""
        return """
        {"id": \(id), "sender_id": \(senderId), "sender_full_name": "\(senderName)",
         "timestamp": 1750000000, "type": "private",
         "content": "\(content.replacingOccurrences(of: "\"", with: "\\\""))",
         "content_type": "text/html",
         "subject": "", "display_recipient": [\(recipients)], "reactions": []\(flagsField)}
        """
    }

    public static func messageEventJSON(eventId: Int, message: String, flags: [String] = []) -> String {
        """
        {"id": \(eventId), "type": "message", "message": \(message),
         "flags": \(jsonStringArray(flags))}
        """
    }

    public static func flagsEventJSON(
        eventId: Int, op: String, flag: String, messages: [Int], all: Bool = false
    ) -> String {
        """
        {"id": \(eventId), "type": "update_message_flags", "op": "\(op)",
         "flag": "\(flag)", "messages": [\(messages.map(String.init).joined(separator: ", "))],
         "all": \(all)}
        """
    }

    public static func heartbeatJSON(eventId: Int) -> String {
        #"{"id": \#(eventId), "type": "heartbeat"}"#
    }

    public static func eventsJSON(_ events: [String]) -> String {
        """
        {"result": "success", "msg": "", "events": [\(events.joined(separator: ", "))]}
        """
    }

    public static func errorJSON(code: String, msg: String = "error") -> String {
        """
        {"result": "error", "code": "\(code)", "msg": "\(msg)"}
        """
    }

    public static func getMessagesJSON(_ messages: [String], foundNewest: Bool = true) -> String {
        """
        {"result": "success", "msg": "", "messages": [\(messages.joined(separator: ", "))],
         "found_newest": \(foundNewest), "found_oldest": false, "history_limited": false}
        """
    }

    private static func jsonStringArray(_ strings: [String]) -> String {
        "[\(strings.map { "\"\($0)\"" }.joined(separator: ", "))]"
    }
}
