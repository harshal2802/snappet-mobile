import XCTest
import SwiftData
import Network
@testable import Snappet

/// Household P2 (prompt 157): a full join and sync over real TCP sockets on 127.0.0.1, through the same
/// `HouseholdConnection` pipe the app uses. Bonjour is left out (discovery needs a network, the pipe
/// doesn't).
@MainActor
final class HouseholdLoopbackSyncTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var listener: NWListener?
    private let box = SessionBox()

    override func tearDown() async throws {
        listener?.cancel()
        box.sessions = []
        containers = []
        HouseholdXP.shared.publish([])
    }

    private func newStore() throws -> HouseholdStore {
        let c = try ModelContainer(for: Schema(SnappetSchema.models),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return HouseholdStore(context: c.mainContext)
    }

    /// A listener on an ephemeral port that answers with `makeMachine()`; returns the port once ready.
    private func listen(_ makeMachine: @escaping @MainActor () -> HouseholdSyncMachine,
                        finished: XCTestExpectation) async throws -> NWEndpoint.Port {
        let l = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "listening")
        l.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        let box = box
        l.newConnectionHandler = { connection in
            MainActor.assumeIsolated {
                let session = HouseholdConnection(connection: connection, machine: makeMachine())
                session.onFinish = { _, _ in finished.fulfill() }
                box.sessions.append(session)
                session.start(timeout: .seconds(10))
            }
        }
        l.start(queue: .main)
        listener = l
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(l.port)
    }

    private func dial(port: NWEndpoint.Port, machine: HouseholdSyncMachine, finished: XCTestExpectation) {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let session = HouseholdConnection(connection: connection, machine: machine)
        session.onFinish = { _, _ in finished.fulfill() }
        box.sessions.append(session)
        session.start(timeout: .seconds(10))
    }

    func testJoinThenSyncOverRealSockets() async throws {
        let alex = try newStore(), sam = try newStore()
        alex.setMyName("Alex")
        alex.create(ChoreFields(name: "Dishes", repeats: .daily, assignment: .rotate([alex.me])))
        let key = alex.ensureKey()
        let invite = HouseholdInvite.make(householdID: alex.household.id, name: "Flat 4B")

        // 1. Sam joins with the invite.
        var listenerMachine: HouseholdSyncMachine?
        let listenerDone = expectation(description: "listener finished"), dialerDone = expectation(description: "dialer finished")
        let port = try await listen({
            var secrets = HouseholdSyncMachine.ListenerSecrets(householdKey: key, log: alex.syncLog)
            secrets.invite = (invite.token, HouseholdWelcome(householdID: alex.household.id, name: "Flat 4B", key: key))
            let m = HouseholdSyncMachine(listening: alex.identity, secrets: secrets)
            listenerMachine = m
            return m
        }, finished: listenerDone)
        let me = HouseholdSyncMachine.Identity(device: UUID(), member: UUID(), name: "Sam")
        let joiner = HouseholdSyncMachine(dialing: .join, identity: me, secret: invite.token, log: nil,
                                          onWelcome: { sam.join($0, as: me, bringChores: false) })
        dial(port: port, machine: joiner, finished: dialerDone)
        await fulfillment(of: [dialerDone, listenerDone], timeout: 10)

        guard case .completed = joiner.outcome else { return XCTFail("join: \(String(describing: joiner.outcome))") }
        XCTAssertEqual(listenerMachine?.sentWelcome, true)
        XCTAssertEqual(sam.household.id, alex.household.id)
        XCTAssertEqual(sam.board.activeChores.map(\.name), ["Dishes"])
        XCTAssertTrue(alex.board.members.contains { $0.name == "Sam" })

        // 2. Sam ticks the dishes; a normal sync carries it back to Alex.
        sam.complete(try XCTUnwrap(sam.board.activeChores.first))
        listener?.cancel()
        let l2 = expectation(description: "listener 2"), d2 = expectation(description: "dialer 2")
        let port2 = try await listen({
            HouseholdSyncMachine(listening: alex.identity, secrets: .init(householdKey: key, log: alex.syncLog))
        }, finished: l2)
        let syncer = HouseholdSyncMachine(dialing: .sync, identity: sam.identity, secret: sam.household.key, log: sam.syncLog)
        dial(port: port2, machine: syncer, finished: d2)
        await fulfillment(of: [d2, l2], timeout: 10)

        guard case .completed(let summary) = syncer.outcome else { return XCTFail("sync: \(String(describing: syncer.outcome))") }
        XCTAssertGreaterThanOrEqual(summary.sent, 1)
        XCTAssertEqual(alex.board, sam.board)
        XCTAssertEqual(alex.board.completions.count, 1)
    }
}

/// Keeps the connections alive for the test (a main-actor class, so the listener's handler may hold it).
@MainActor
private final class SessionBox {
    var sessions: [HouseholdConnection] = []
}
