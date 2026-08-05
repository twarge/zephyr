import Foundation
import Testing
import ZulipAPI
import ZulipTestSupport
@testable import ZulipModel

/// Polls `condition` on the main actor until it holds or the timeout passes.
@MainActor
func eventually(
    timeout: Duration = .seconds(5),
    _ comment: Comment? = nil,
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), comment)
}

@MainActor
struct SyncLifecycleTests {
    private func makeGlobalStore(transport: FakeTransport) throws -> (GlobalStore, Account) {
        let global = try GlobalStore(
            accountsStore: InMemoryAccountsStore(),
            credentials: InMemoryCredentialStore(),
            transport: transport,
            enablePresencePings: false,  // pings would consume scripted responses
            persistsToDisk: false,  // never touch the real Application Support
            sleep: { _ in })  // no real waiting in tests
        let account = try global.addAccount(
            realmURL: URL(string: "https://test.example")!,
            email: "self@example.com", apiKey: "key", userId: 1)
        return (global, account)
    }

    @Test func loadRegisterPollApply() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.registerJSON(queueId: "q1")),
                .json(Fixtures.eventsJSON([
                    Fixtures.messageEventJSON(
                        eventId: 5, message: Fixtures.channelMessageJSON(id: 100), flags: []),
                ])),
            ],
            defaultResponse: .hang)
        let (global, account) = try makeGlobalStore(transport: transport)

        let store = try await global.perAccountStore(for: account.id)
        #expect(store.queueId == "q1")
        #expect(store.users.count == 2)

        try await eventually("message event applied") { store.messages[100] != nil }
        #expect(store.lastEventId == 5)
        #expect(store.unreads.totalCount == 1)

        await global.shutdown(deleteQueues: false)
    }

    @Test func queueExpiryRebuildsStore() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.registerJSON(queueId: "q1")),
                .json(Fixtures.eventsJSON([
                    Fixtures.messageEventJSON(
                        eventId: 5, message: Fixtures.channelMessageJSON(id: 100), flags: []),
                ])),
                .json(Fixtures.errorJSON(code: "BAD_EVENT_QUEUE_ID"), status: 400),
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.registerJSON(queueId: "q2")),
            ],
            defaultResponse: .hang)
        let (global, account) = try makeGlobalStore(transport: transport)

        let firstStore = try await global.perAccountStore(for: account.id)
        let firstGeneration = global.storeGeneration

        try await eventually("store rebuilt with fresh queue") {
            global.stores[account.id] !== firstStore
                && global.stores[account.id]?.queueId == "q2"
        }
        #expect(global.storeGeneration > firstGeneration)
        // The replacement store came from a fresh register, not event replay.
        #expect(global.stores[account.id]?.messages.isEmpty == true)

        await global.shutdown(deleteQueues: false)
    }

    @Test func transientErrorsRetryWithoutRebuild() async throws {
        let transport = FakeTransport(
            script: [
                .json(Fixtures.serverSettingsJSON()),
                .json(Fixtures.registerJSON(queueId: "q1")),
                .networkError,
                .networkError,
                .json(Fixtures.eventsJSON([
                    Fixtures.messageEventJSON(
                        eventId: 7, message: Fixtures.channelMessageJSON(id: 101), flags: []),
                ])),
            ],
            defaultResponse: .hang)
        let (global, account) = try makeGlobalStore(transport: transport)

        let store = try await global.perAccountStore(for: account.id)
        try await eventually("event applied after retries") { store.messages[101] != nil }
        // Same store instance: transient failures never rebuild.
        #expect(global.stores[account.id] === store)
        #expect(store.isRecoveringEventStream == false)

        await global.shutdown(deleteQueues: false)
    }

    @Test func serverBelowFloorIsRejected() async throws {
        let transport = FakeTransport(
            script: [.json(Fixtures.serverSettingsJSON(featureLevel: 200, version: "8.0"))],
            defaultResponse: .hang)
        let (global, account) = try makeGlobalStore(transport: transport)

        await #expect {
            _ = try await global.perAccountStore(for: account.id)
        } throws: { error in
            if case .serverTooOld = error as? ModelError { return true }
            return false
        }
    }
}
