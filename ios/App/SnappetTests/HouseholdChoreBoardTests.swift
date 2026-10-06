import XCTest
@testable import Snappet

/// Household P1 (prompt 156): the board is a pure fold of the op log — order-independent, idempotent,
/// with the merge rules P2's sync relies on.
final class HouseholdChoreBoardTests: XCTestCase {
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()
    private var cal: Calendar { Self.cal }

    /// Monday 5 Oct 2026, 09:00 UTC.
    static let monday = Date(timeIntervalSince1970: 1_791_190_800)
    static func day(_ n: Int, hour: Int = 9) -> Date {
        monday.addingTimeInterval(TimeInterval(n * 86_400 + (hour - 9) * 3_600))
    }

    let phoneA = UUID(), phoneB = UUID()
    let alex = UUID(), sam = UUID(), jo = UUID()
    let fridge = UUID(), dishes = UUID()

    struct Writer {
        let device: UUID
        var seq = 0
        mutating func op(_ kind: ChoreOp.Kind, at: Date) -> ChoreOp {
            seq += 1
            return ChoreOp(id: UUID(), device: device, seq: seq, at: at, kind: kind)
        }
    }

    /// A deterministic shuffle source.
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    func testCalendarAnchor() {
        XCTAssertEqual(cal.component(.weekday, from: Self.monday), 2, "fixture day is a Monday")
    }

    /// Two phones' worth of creates, edits, completes, an undo, a claim, a goal and an archive.
    private func busyLog() -> [ChoreOp] {
        var a = Writer(device: phoneA), b = Writer(device: phoneB)
        let doneByA = a.op(.complete(chore: dishes, member: alex), at: Self.day(0, hour: 20))
        let claimByB = b.op(.claim(chore: fridge, member: sam), at: Self.day(1))
        return [
            a.op(.addMember(member: alex, name: "Alex"), at: Self.day(0, hour: 8)),
            b.op(.addMember(member: sam, name: "Sam"), at: Self.day(0, hour: 8)),
            a.op(.createChore(chore: fridge, fields: ChoreFields(name: "Fridge", effort: .l,
                                                                 repeats: .afterDone(days: 14), assignment: .upForGrabs)),
                 at: Self.day(0, hour: 9)),
            a.op(.createChore(chore: dishes, fields: ChoreFields(name: "Dishes", repeats: .daily,
                                                                 assignment: .rotate([alex, sam]))),
                 at: Self.day(0, hour: 9)),
            b.op(.editChore(chore: fridge, fields: ChoreFields(name: "Clean the fridge")), at: Self.day(0, hour: 10)),
            a.op(.editChore(chore: fridge, fields: ChoreFields(room: "Kitchen")), at: Self.day(0, hour: 10)),
            doneByA,
            b.op(.complete(chore: dishes, member: sam), at: Self.day(1, hour: 20)),
            b.op(.undo(op: doneByA.id), at: Self.day(1, hour: 21)),
            claimByB,
            a.op(.setGoal(week: "2026-10-05", target: 10, reward: "Pizza"), at: Self.day(0, hour: 11)),
            b.op(.setGoal(week: "2026-10-05", target: 12, reward: "Pizza night"), at: Self.day(0, hour: 12)),
            a.op(.complete(chore: fridge, member: alex), at: Self.day(2)),
            b.op(.unknown("send_kudos"), at: Self.day(2)),
        ]
    }

    func testFoldIsOrderIndependentAndIdempotent() {
        let log = busyLog()
        let reference = ChoreBoard.fold(log)
        var rng = LCG(state: 42)
        for _ in 0..<50 {
            var scrambled = log + log.shuffled(using: &rng).prefix(5)   // duplicates too
            scrambled.shuffle(using: &rng)
            XCTAssertEqual(ChoreBoard.fold(scrambled), reference)
        }
        XCTAssertEqual(ChoreBoard.fold(log + log), reference, "re-receiving the whole log changes nothing")
    }

    func testBusyLogFoldsToTheExpectedBoard() {
        let board = ChoreBoard.fold(busyLog())
        XCTAssertEqual(board.members.map(\.name).sorted(), ["Alex", "Sam"])
        let f = board.chores[fridge]!
        XCTAssertEqual(f.name, "Clean the fridge", "edits to different fields both land")
        XCTAssertEqual(f.room, "Kitchen")
        XCTAssertEqual(f.effort, .l)
        XCTAssertEqual(board.completions.filter { $0.chore == dishes }.map(\.member), [sam], "the undone tick is gone")
        XCTAssertEqual(board.goals["2026-10-05"], HouseholdGoal(week: "2026-10-05", target: 12, reward: "Pizza night"))
    }

    func testSameFieldIsLastWriterWins() {
        var a = Writer(device: phoneA), b = Writer(device: phoneB)
        let log = [
            a.op(.createChore(chore: fridge, fields: ChoreFields(name: "Fridge")), at: Self.day(0)),
            a.op(.editChore(chore: fridge, fields: ChoreFields(name: "From A")), at: Self.day(0, hour: 12)),
            b.op(.editChore(chore: fridge, fields: ChoreFields(name: "From B")), at: Self.day(0, hour: 11)),
        ]
        XCTAssertEqual(ChoreBoard.fold(log).chores[fridge]?.name, "From A")
        XCTAssertEqual(ChoreBoard.fold(log.reversed()).chores[fridge]?.name, "From A")
    }

    func testAnEditFromASkewedClockStillLandsOnItsCreate() {
        var a = Writer(device: phoneA), b = Writer(device: phoneB)
        let log = [
            a.op(.createChore(chore: fridge, fields: ChoreFields(name: "Fridge", effort: .s)), at: Self.day(0, hour: 12)),
            b.op(.editChore(chore: fridge, fields: ChoreFields(effort: .l)), at: Self.day(0, hour: 10)),
        ]
        XCTAssertEqual(ChoreBoard.fold(log).chores[fridge]?.effort, .l)
    }

    func testArchiveBeatsAConcurrentEdit() {
        var a = Writer(device: phoneA), b = Writer(device: phoneB)
        let log = [
            a.op(.createChore(chore: fridge, fields: ChoreFields(name: "Fridge")), at: Self.day(0)),
            a.op(.archiveChore(chore: fridge), at: Self.day(1)),
            b.op(.editChore(chore: fridge, fields: ChoreFields(name: "Fridge!")), at: Self.day(2)),
        ]
        let board = ChoreBoard.fold(log)
        XCTAssertEqual(board.chores[fridge]?.archived, true)
        XCTAssertTrue(board.activeChores.isEmpty)
    }

    func testTwoPeopleDoingTheSameRoundWhileApartAreBothCreditedAndCountOnce() {
        var a = Writer(device: phoneA), b = Writer(device: phoneB)
        let log = [
            a.op(.createChore(chore: fridge, fields: ChoreFields(name: "Fridge", effort: .l, repeats: .afterDone(days: 14),
                                                                 assignment: .upForGrabs)), at: Self.day(0)),
            a.op(.complete(chore: fridge, member: alex), at: Self.day(1)),
            b.op(.complete(chore: fridge, member: sam), at: Self.day(2)),
        ]
        let board = ChoreBoard.fold(log)
        let chore = board.chores[fridge]!
        let rounds = board.rounds(of: chore, calendar: cal)
        XCTAssertEqual(rounds.count, 1)
        XCTAssertEqual(rounds[0].members, [alex, sam])
        XCTAssertEqual(board.credits(for: alex, calendar: cal).count, 1)
        XCTAssertEqual(board.credits(for: sam, calendar: cal).count, 1)
        XCTAssertEqual(board.roundsByDay(weekStart: ChoreSchedule.weekStart(Self.monday, calendar: cal), calendar: cal),
                       [0, 1, 0, 0, 0, 0, 0], "the round counts once, on the day it was first done")
    }

    func testTickingTwiceInOneRoundCreditsOnce() {
        var a = Writer(device: phoneA)
        let log = [
            a.op(.createChore(chore: dishes, fields: ChoreFields(name: "Dishes", repeats: .daily)), at: Self.day(0)),
            a.op(.complete(chore: dishes, member: alex), at: Self.day(0, hour: 10)),
            a.op(.complete(chore: dishes, member: alex), at: Self.day(0, hour: 11)),
            a.op(.complete(chore: dishes, member: alex), at: Self.day(1, hour: 11)),
        ]
        XCTAssertEqual(ChoreBoard.fold(log).credits(for: alex, calendar: cal).count, 2, "one per day")
    }

    func testUndoRetractsATickAndAClaim() {
        var a = Writer(device: phoneA)
        let create = a.op(.createChore(chore: fridge, fields: ChoreFields(name: "Fridge", assignment: .upForGrabs)),
                          at: Self.day(0))
        let claim = a.op(.claim(chore: fridge, member: alex), at: Self.day(0, hour: 10))
        let tick = a.op(.complete(chore: dishes, member: alex), at: Self.day(0, hour: 11))
        var board = ChoreBoard.fold([create, claim])
        XCTAssertEqual(board.assignee(of: board.chores[fridge]!, now: Self.day(0, hour: 12), calendar: cal), alex)
        board = ChoreBoard.fold([create, claim, a.op(.undo(op: claim.id), at: Self.day(0, hour: 13))])
        XCTAssertNil(board.assignee(of: board.chores[fridge]!, now: Self.day(0, hour: 14), calendar: cal))
        XCTAssertTrue(ChoreBoard.fold([create, tick]).completions.isEmpty, "a tick on an unknown chore is dropped")
    }

    func testAClaimLastsUntilTheChoreIsNextDone() {
        var a = Writer(device: phoneA)
        let log = [
            a.op(.createChore(chore: fridge, fields: ChoreFields(name: "Fridge", repeats: .afterDone(days: 14),
                                                                 assignment: .upForGrabs)), at: Self.day(0)),
            a.op(.claim(chore: fridge, member: sam), at: Self.day(0, hour: 10)),
            a.op(.complete(chore: fridge, member: sam), at: Self.day(1)),
        ]
        let board = ChoreBoard.fold(log)
        XCTAssertNil(board.assignee(of: board.chores[fridge]!, now: Self.day(20), calendar: cal))
    }

    func testRotationAdvancesPerCompletedRoundThroughThreeMembers() {
        var a = Writer(device: phoneA)
        var log = [a.op(.createChore(chore: dishes, fields: ChoreFields(name: "Dishes", repeats: .daily,
                                                                         assignment: .rotate([alex, sam, jo]))),
                        at: Self.day(0, hour: 8))]
        func who(_ now: Date) -> UUID? {
            let board = ChoreBoard.fold(log)
            return board.assignee(of: board.chores[dishes]!, now: now, calendar: cal)
        }
        XCTAssertEqual(who(Self.day(0)), alex)
        log.append(a.op(.complete(chore: dishes, member: alex), at: Self.day(0, hour: 20)))
        XCTAssertEqual(who(Self.day(0, hour: 21)), alex, "today's round is done, and it was Alex's")
        XCTAssertEqual(who(Self.day(1)), sam)
        XCTAssertEqual(who(Self.day(2)), sam, "a missed day doesn't skip Sam")
        log.append(a.op(.complete(chore: dishes, member: jo), at: Self.day(2, hour: 20)))   // Jo helps out
        XCTAssertEqual(who(Self.day(3)), jo)
        log.append(a.op(.complete(chore: dishes, member: jo), at: Self.day(3, hour: 20)))
        XCTAssertEqual(who(Self.day(4)), alex, "wraps round")
    }

    func testVersionVectorFindsWhatAPeerIsMissing() {
        var a = Writer(device: phoneA), b = Writer(device: phoneB)
        let opsA = (0..<3).map { a.op(.unknown("x\($0)"), at: Self.day($0)) }
        let opsB = (0..<2).map { b.op(.unknown("y\($0)"), at: Self.day($0)) }
        let peer = VersionVector([opsA[0]] + opsB)
        XCTAssertEqual(peer[phoneA], 1)
        XCTAssertEqual(peer[phoneB], 2)
        XCTAssertEqual(peer.missing(from: opsA + opsB).map(\.id), [opsA[1].id, opsA[2].id])
    }
}
