import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

@MainActor
struct DeletePermissionTests {
    /// The fixture snapshot (self is user 1) plus extra register fields.
    private func store(_ extra: String, streamExtra: String = "") throws -> PerAccountStore {
        var json = Fixtures.registerJSON(queueId: "q1")
        json = json.replacingOccurrences(
            of: #""invite_only": false}"#, with: #""invite_only": false\#(streamExtra)}"#)
        json = json.replacingOccurrences(of: #"{"result""#, with: "{\(extra) \"result\"")
        let account = Account(
            realmURL: URL(string: "https://test.example")!, email: "self@example.com", userId: 1)
        let connection = ApiConnection(
            realmURL: account.realmURL, email: account.email, apiKey: "key",
            transport: FakeTransport(defaultResponse: .hang))
        return PerAccountStore(
            account: account, connection: connection,
            snapshot: try ZulipJSON.decoder.decode(InitialSnapshot.self, from: Data(json.utf8)))
    }

    private func message(senderId: Int, timestamp: Int = 1_750_000_000) throws -> Message {
        try ZulipJSON.decoder.decode(
            Message.self,
            from: Data(Fixtures.channelMessageJSON(
                id: 100, senderId: senderId, timestamp: timestamp).utf8))
    }

    private let sent = Date(timeIntervalSince1970: 1_750_000_000)
    private let groups = #"""
        "realm_user_groups": [
            {"id": 1, "members": [1], "direct_subgroup_ids": []},
            {"id": 2, "members": [], "direct_subgroup_ids": [1]},
            {"id": 3, "members": [2], "direct_subgroup_ids": []}],
        """#

    @Test func legacyServerOwnMessagesOnlyUnlessAdmin() throws {
        let member = try store("")
        #expect(member.canDeleteMessage(try message(senderId: 1)))
        #expect(!member.canDeleteMessage(try message(senderId: 2)))
        let admin = try store(#""is_admin": true,"#)
        #expect(admin.canDeleteMessage(try message(senderId: 2)))
    }

    @Test func deleteAnyThroughSubgroupMembership() throws {
        let allowed = try store(groups + #""realm_can_delete_any_message_group": 2,"#)
        #expect(allowed.canDeleteMessage(try message(senderId: 2)))
        // Admin status doesn't count once the realm names a group.
        let denied = try store(
            groups + #""is_admin": true, "realm_can_delete_any_message_group": 3,"#)
        #expect(!denied.canDeleteMessage(try message(senderId: 2)))
    }

    @Test func anonymousGroupAndChannelGrant() throws {
        let direct = try store(
            groups + #""realm_can_delete_any_message_group": {"direct_members": [1], "direct_subgroups": []},"#)
        #expect(direct.canDeleteMessage(try message(senderId: 2)))
        let channel = try store(
            groups + #""realm_can_delete_any_message_group": 3,"#,
            streamExtra: #", "can_delete_any_message_group": 1"#)
        #expect(channel.canDeleteMessage(try message(senderId: 2)))
    }

    @Test func ownMessagesHonorGroupAndTimeLimit() throws {
        let denied = try store(
            groups + #""realm_can_delete_any_message_group": 3, "realm_can_delete_own_message_group": 3,"#)
        #expect(!denied.canDeleteMessage(try message(senderId: 1)))
        let limited = try store(
            groups + #""realm_can_delete_any_message_group": 3, "realm_can_delete_own_message_group": 1, "realm_message_content_delete_limit_seconds": 600,"#)
        #expect(limited.canDeleteMessage(try message(senderId: 1), now: sent + 300))
        #expect(!limited.canDeleteMessage(try message(senderId: 1), now: sent + 900))
    }
}
