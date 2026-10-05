import XCTest
import SwiftData
import CryptoKit
@testable import Snappet

/// Household P2 (prompt 157): the protocol pieces, invites, and whole conversations between two
/// `HouseholdSyncMachine`s wired back to back over real (in-memory) stores.
@MainActor
final class HouseholdSyncTests: XCTestCase {
    private var containers: [ModelContainer] = []

    override func tearDown() async throws {
        HouseholdXP.shared.publish([])
        containers = []
    }

    private func newStore() throws -> HouseholdStore {
        let c = try ModelContainer(for: Schema(SnappetSchema.models),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        return HouseholdStore(context: c.mainContext)
    }

    /// Delivers frames both ways until both sides go quiet.
    private func pump(_ dialer: HouseholdSyncMachine, _ listener: HouseholdSyncMachine) {
        var toListener = dialer.start(), toDialer: [Data] = []
        var rounds = 0
        while (!toListener.isEmpty || !toDialer.isEmpty) && rounds < 200 {
            let a = toListener; toListener = []
            for f in a { toDialer += listener.receive(f) }
            let b = toDialer; toDialer = []
            for f in b { toListener += dialer.receive(f) }
            rounds += 1
        }
    }

    private func sync(_ a: HouseholdStore, _ b: HouseholdStore) -> (HouseholdSyncMachine, HouseholdSyncMachine) {
        let dialer = HouseholdSyncMachine(dialing: .sync, identity: a.identity, secret: a.household.key, log: a.syncLog)
        let listener = HouseholdSyncMachine(listening: b.identity,
                                            secrets: .init(householdKey: b.household.key, log: b.syncLog))
        pump(dialer, listener)
        if case .completed(let s) = dialer.outcome { a.recordSync(s) }
        if case .completed(let s) = listener.outcome { b.recordSync(s) }
        return (dialer, listener)
    }

    /// B joins A's household with an invite, over a machine pair.
    @discardableResult
    private func join(_ joiner: HouseholdStore, to inviter: HouseholdStore, name: String = "Sam",
                      bringChores: Bool = false, token: Data? = nil, open invite: HouseholdInvite? = nil)
    -> (HouseholdSyncMachine, HouseholdSyncMachine) {
        inviter.ensureKey()
        let inv = invite ?? HouseholdInvite.make(householdID: inviter.household.id, name: inviter.displayName)
        let me = HouseholdSyncMachine.Identity(device: UUID(), member: UUID(), name: name)
        let dialer = HouseholdSyncMachine(dialing: .join, identity: me, secret: token ?? inv.token, log: nil,
                                          onWelcome: { joiner.join($0, as: me, bringChores: bringChores) })
        var secrets = HouseholdSyncMachine.ListenerSecrets(householdKey: inviter.household.key, log: inviter.syncLog)
        secrets.invite = (inv.token, HouseholdWelcome(householdID: inviter.household.id, name: inviter.displayName,
                                                      key: inviter.household.key))
        let listener = HouseholdSyncMachine(listening: inviter.identity, secrets: secrets)
        pump(dialer, listener)
        if case .completed(let s) = dialer.outcome { joiner.recordSync(s) }
        if case .completed(let s) = listener.outcome { inviter.recordSync(s) }
        return (dialer, listener)
    }

    private func isCompleted(_ m: HouseholdSyncMachine) -> Bool {
        if case .completed = m.outcome { return true } else { return false }
    }

    // MARK: - Framing and crypto

    func testFramesSurviveSplittingAndCoalescing() throws {
        let payloads = [Data("one".utf8), Data(), Data(repeating: 7, count: 70_000)]
        let stream = payloads.map(HouseholdFrame.encode).reduce(Data(), +)
        var reader = HouseholdFrame.Reader()
        var got: [Data] = []
        var i = 0
        while i < stream.count {   // dribble it in 3-byte then 50k chunks
            let n = i < 10 ? 3 : 50_000
            got += try reader.push(stream.subdata(in: i..<min(stream.count, i + n)))
            i += n
        }
        XCTAssertEqual(got, payloads)
    }

    func testAnOversizedFrameIsRefused() {
        var reader = HouseholdFrame.Reader()
        XCTAssertThrowsError(try reader.push(Data([0x7f, 0xff, 0xff, 0xff])))
    }

    func testSessionKeysPairUpAndDifferPerDirectionAndSession() throws {
        let secret = HouseholdCrypto.randomBytes(32), n1 = HouseholdCrypto.randomBytes(32), n2 = HouseholdCrypto.randomBytes(32)
        let dialer = HouseholdCrypto.sessionKeys(secret: secret, dialerNonce: n1, listenerNonce: n2, isDialer: true)
        let listener = HouseholdCrypto.sessionKeys(secret: secret, dialerNonce: n1, listenerNonce: n2, isDialer: false)
        let box = try HouseholdCrypto.seal(Data("hi".utf8), key: dialer.send)
        XCTAssertEqual(try HouseholdCrypto.open(box, key: listener.receive), Data("hi".utf8))
        XCTAssertThrowsError(try HouseholdCrypto.open(box, key: listener.send), "directions use different keys")
        let other = HouseholdCrypto.sessionKeys(secret: secret, dialerNonce: n2, listenerNonce: n1, isDialer: false)
        XCTAssertThrowsError(try HouseholdCrypto.open(box, key: other.receive), "new nonces, new keys")
        var tampered = box
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try HouseholdCrypto.open(tampered, key: listener.receive))
    }

    func testKDFAndTagMatchTheSpecVector() {
        // Pinned in household-wire-format.md § Sync protocol (cross-checked against an independent Python
        // HKDF), so another implementation can check itself.
        let secret = Data(repeating: 0x01, count: 32)
        let n1 = Data(repeating: 0x02, count: 32), n2 = Data(repeating: 0x03, count: 32)
        let keys = HouseholdCrypto.sessionKeys(secret: secret, dialerNonce: n1, listenerNonce: n2, isDialer: true)
        func hex(_ k: SymmetricKey) -> String { k.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(keys.send), "42473905e765b737085a5f6d37b5644405dd34f767ae769f0224bc3e9025010e")
        XCTAssertEqual(hex(keys.receive), "fdc39f71f0d96562ae664017149b9ddde56f926584971dfdd7844b8f9d964d27")
        XCTAssertEqual(HouseholdCrypto.tag(secret: secret, label: HouseholdCrypto.householdTagLabel), "04c02450e3f9af29")
    }

    // MARK: - Invites

    func testInviteLinkRoundTripsAndForeignLinksAreRejected() {
        let i = HouseholdInvite.make(householdID: UUID(), name: "Flat 4B & co")
        XCTAssertEqual(HouseholdInvite(url: i.url), i.with(expiresTruncated: true))
        XCTAssertEqual(SnappetDeepLink.route(for: i.url), .householdJoin(i.with(expiresTruncated: true)))
        XCTAssertNil(HouseholdInvite(string: "snappet://household/join?v=2&h=\(UUID())&t=AAAA&e=1"))
        XCTAssertNil(HouseholdInvite(string: "snappet://festival/v1/abc"))
        XCTAssertNil(HouseholdInvite(string: "https://example.com/join"))
        XCTAssertFalse(i.url.absoluteString.contains("key"), "the household key never rides a link")
    }

    // MARK: - Conversations

    func testJoinHandsOverTheHouseholdAndTheWholeLog() throws {
        let alex = try newStore(), sam = try newStore()
        alex.setMyName("Alex")
        alex.create(ChoreFields(name: "Dishes", repeats: .daily, assignment: .rotate([alex.me])))
        alex.complete(try XCTUnwrap(alex.board.activeChores.first))

        let (dialer, listener) = join(sam, to: alex)
        XCTAssertTrue(isCompleted(dialer), "\(String(describing: dialer.outcome))")
        XCTAssertTrue(listener.sentWelcome)
        XCTAssertEqual(sam.household.id, alex.household.id)
        XCTAssertEqual(sam.household.key, alex.household.key)
        XCTAssertEqual(sam.board.activeChores.map(\.name), ["Dishes"])
        XCTAssertEqual(alex.board.members.map(\.name).sorted(), ["Alex", "Sam"], "Sam's add_member reached Alex")
        XCTAssertEqual(alex.board, sam.board)
        XCTAssertEqual(alex.peers.first?.name, "Sam")
        XCTAssertEqual(sam.peers.first?.deviceID, alex.myDevice)
        XCTAssertEqual(alex.peers.first?.deviceID, sam.myDevice, "the inviter records the joiner's real device")
    }

    func testConcurrentChangesOnBothPhonesConvergeAndResyncSendsNothing() throws {
        let alex = try newStore(), sam = try newStore()
        join(sam, to: alex)
        alex.create(ChoreFields(name: "Fridge", effort: .l, repeats: .afterDone(days: 14), assignment: .upForGrabs))
        sam.create(ChoreFields(name: "Bins", repeats: .weekly, assignment: .upForGrabs))
        let (d, l) = sync(alex, sam)
        XCTAssertTrue(isCompleted(d) && isCompleted(l))
        XCTAssertEqual(alex.board, sam.board)
        XCTAssertEqual(Set(alex.board.activeChores.map(\.name)), ["Fridge", "Bins"])

        // Both do the fridge while apart: both credited, one round.
        let fridgeA = try XCTUnwrap(alex.board.activeChores.first { $0.name == "Fridge" })
        alex.complete(fridgeA)
        sam.complete(try XCTUnwrap(sam.board.activeChores.first { $0.name == "Fridge" }))
        sync(alex, sam)
        XCTAssertEqual(alex.board, sam.board)
        XCTAssertEqual(alex.board.rounds(of: fridgeA).count, 1)
        XCTAssertEqual(alex.board.rounds(of: fridgeA).first?.members.count, 2)

        let (again, _) = sync(alex, sam)
        guard case .completed(let s) = again.outcome else { return XCTFail("resync") }
        XCTAssertEqual(s.sent, 0)
        XCTAssertEqual(s.received, 0)
        XCTAssertEqual(alex.changesWaiting, 0)
    }

    func testChangesRelayThroughAThirdPhone() throws {
        let alex = try newStore(), sam = try newStore(), jo = try newStore()
        join(sam, to: alex)
        join(jo, to: alex, name: "Jo")
        jo.create(ChoreFields(name: "Gutters", repeats: .once, assignment: .upForGrabs))
        sync(jo, alex)             // Jo meets Alex
        sync(alex, sam)            // Alex meets Sam; Sam never meets Jo
        XCTAssertTrue(sam.board.activeChores.contains { $0.name == "Gutters" })
        XCTAssertEqual(sam.board, jo.board)
    }

    func testChangesWaitingCountsUnconfirmedOpsUntilTheNextSync() throws {
        let alex = try newStore(), sam = try newStore()
        join(sam, to: alex)
        XCTAssertEqual(alex.changesWaiting, 0)
        alex.create(ChoreFields(name: "Hoover"))
        alex.create(ChoreFields(name: "Mop"))
        XCTAssertEqual(alex.changesWaiting, 2)
        sync(alex, sam)
        XCTAssertEqual(alex.changesWaiting, 0)
    }

    func testAnUnknownKindIsRelayedByteForByte() throws {
        let alex = try newStore(), sam = try newStore()
        join(sam, to: alex)
        let future = #"{"at":"2026-10-04T08:00:00.000Z","device":"00000000-0000-0000-0000-0000000000d9","id":"00000000-0000-0000-0000-0000000000f1","kind":"send_kudos","seq":1,"v":1,"x":"y"}"#
        alex.ingest([future])
        sync(alex, sam)
        let relayed = try XCTUnwrap(sam.records.first { $0.opID.uuidString.lowercased() == "00000000-0000-0000-0000-0000000000f1" })
        XCTAssertEqual(String(decoding: relayed.payload, as: UTF8.self), future)
    }

    func testWrongKeyFailsAtAuthAndLeaksNothing() throws {
        let alex = try newStore(), mallory = try newStore()
        alex.ensureKey(); mallory.ensureKey()
        alex.create(ChoreFields(name: "Secret chore"))
        let dialer = HouseholdSyncMachine(dialing: .sync, identity: mallory.identity, secret: mallory.household.key,
                                          log: mallory.syncLog)
        var secrets = HouseholdSyncMachine.ListenerSecrets(householdKey: alex.household.key, log: alex.syncLog)
        secrets.invite = (HouseholdCrypto.randomBytes(32), HouseholdWelcome(householdID: alex.household.id,
                                                                            name: "x", key: alex.household.key))
        let listener = HouseholdSyncMachine(listening: alex.identity, secrets: secrets)

        // Watch every frame the listener sends: after its hello, nothing may open with Mallory's view of keys.
        var listenerFrames: [Data] = []
        var toListener = dialer.start(), toDialer: [Data] = []
        for _ in 0..<10 {
            let a = toListener; toListener = []
            for f in a { let out = listener.receive(f); listenerFrames += out; toDialer += out }
            let b = toDialer; toDialer = []
            for f in b { toListener += dialer.receive(f) }
        }
        XCTAssertEqual(dialer.outcome, .failed(.authFailed))
        XCTAssertEqual(listener.outcome, .failed(.authFailed))
        XCTAssertFalse(listener.sentWelcome)
        XCTAssertEqual(listenerFrames.count, 2, "hello + auth only: no welcome, state or ops")
        XCTAssertFalse(mallory.board.activeChores.contains { $0.name == "Secret chore" })
    }

    func testABurntOrExpiredInviteIsRefusedWithAReason() throws {
        let alex = try newStore(), sam = try newStore(), jo = try newStore()
        alex.ensureKey()
        // No invite open on Alex (burnt / expired): the listener says so in plaintext.
        let me = HouseholdSyncMachine.Identity(device: UUID(), member: UUID(), name: "Jo")
        let dialer = HouseholdSyncMachine(dialing: .join, identity: me, secret: HouseholdCrypto.randomBytes(32), log: nil,
                                          onWelcome: { jo.join($0, as: me, bringChores: false) })
        let listener = HouseholdSyncMachine(listening: alex.identity,
                                            secrets: .init(householdKey: alex.household.key, log: alex.syncLog))
        pump(dialer, listener)
        XCTAssertEqual(dialer.outcome, .failed(.rejected("invite_closed")))
        XCTAssertEqual(HouseholdPeerService.describe(.rejected("invite_closed")),
                       "That invite has expired or already been used. Ask for a new code.")
        XCTAssertNotEqual(jo.household.id, alex.household.id)

        // The wrong token against an open invite fails at auth.
        let (d2, _) = join(sam, to: alex, token: HouseholdCrypto.randomBytes(32))
        XCTAssertEqual(d2.outcome, .failed(.authFailed))
        XCTAssertNotEqual(sam.household.id, alex.household.id)
    }

    func testJoiningKeepsMyOldXPAndCanBringMyChores() throws {
        let alex = try newStore(), sam = try newStore()
        sam.create(ChoreFields(name: "Plants", effort: .s, repeats: .daily, assignment: .rotate([sam.me])))
        sam.create(ChoreFields(name: "Old one"))
        let plants = try XCTUnwrap(sam.board.activeChores.first { $0.name == "Plants" })
        sam.complete(plants)
        sam.archive(try XCTUnwrap(sam.board.activeChores.first { $0.name == "Old one" }))
        XCTAssertEqual(HouseholdXP.shared.earnings.count, 1)
        let soloID = sam.household.id

        join(sam, to: alex, bringChores: true)
        XCTAssertNotEqual(sam.household.id, soloID)
        XCTAssertEqual(sam.board.activeChores.map(\.name), ["Plants"], "active chores only, archived stays behind")
        XCTAssertTrue(sam.board.completions.isEmpty, "completions aren't copied")
        HouseholdXP.shared.load(context: containers[1].mainContext)   // Sam's phone, every household on it
        XCTAssertEqual(HouseholdXP.shared.earnings.count, 1, "the solo board's XP survives the join")
        XCTAssertEqual(alex.board.activeChores.map(\.name), ["Plants"], "and the carried chore reached Alex")
    }

    func testRestoreRerollsDeviceIDs() throws {
        let c = try ModelContainer(for: Schema(SnappetSchema.models),
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(c)
        let store = HouseholdStore(context: c.mainContext)
        let before = store.myDevice
        HouseholdStore.rerollDevices(context: c.mainContext)
        XCTAssertNotEqual(HouseholdStore(context: c.mainContext).myDevice, before)
    }

    func testRenameAndMyNameAreSharedOps() throws {
        let alex = try newStore(), sam = try newStore()
        join(sam, to: alex)
        alex.rename("Flat 4B")
        sam.setMyName("Samantha")
        sync(alex, sam)
        XCTAssertEqual(sam.displayName, "Flat 4B")
        XCTAssertTrue(alex.board.members.contains { $0.name == "Samantha" })
    }
}

private extension HouseholdInvite {
    /// The link carries whole seconds.
    func with(expiresTruncated: Bool) -> HouseholdInvite {
        var c = self
        c.expires = Date(timeIntervalSince1970: TimeInterval(Int(expires.timeIntervalSince1970)))
        return c
    }
}
