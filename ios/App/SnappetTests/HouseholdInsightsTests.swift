import XCTest
import SwiftData
@testable import Snappet

/// Household P3 (prompt 158): the house pet, streak, pause, fair share, lean, help requests, thanks and
/// the weekly recap, all derived from the op log.
final class HouseholdInsightsTests: XCTestCase {
    private let cal = HouseholdChoreBoardTests.cal
    private func day(_ n: Int, hour: Int = 9) -> Date { HouseholdChoreBoardTests.day(n, hour: hour) }
    private let xp: (ChoreEffort) -> Int = { [.s: 10, .m: 20, .l: 35][$0]! }

    let alex = UUID(), sam = UUID(), jo = UUID()
    let phone = UUID()
    private var seq = 0

    private func op(_ kind: ChoreOp.Kind, at: Date) -> ChoreOp {
        seq += 1
        return ChoreOp(id: UUID(), device: phone, seq: seq, at: at, kind: kind)
    }

    private func members(_ ids: [(UUID, String)]) -> [ChoreOp] {
        ids.map { op(.addMember(member: $0.0, name: $0.1), at: day(-60)) }
    }

    private func chore(_ id: UUID, _ name: String, _ effort: ChoreEffort = .s, _ repeats: ChoreRepeat = .daily,
                       _ assignment: ChoreAssignment = .upForGrabs, room: String = "", lean: Bool? = nil, at: Date? = nil) -> ChoreOp {
        op(.createChore(chore: id, fields: ChoreFields(name: name, room: room, effort: effort, repeats: repeats,
                                                       assignment: assignment, lean: lean)), at: at ?? day(-30))
    }

    // MARK: Pet

    func testHouseXPCountsEveryCreditedMemberUncapped() {
        let fridge = UUID(), dishes = UUID()
        var log = members([(alex, "Alex"), (sam, "Sam")])
        log += [chore(fridge, "Fridge", .l, .afterDone(days: 14)), chore(dishes, "Dishes", .s, .daily)]
        log.append(op(.complete(chore: fridge, member: alex), at: day(0)))
        log.append(op(.complete(chore: fridge, member: sam), at: day(1)))          // same round, both credited
        for d in 0..<40 { log.append(op(.complete(chore: dishes, member: alex), at: day(d - 39))) }   // no daily cap here
        let board = ChoreBoard.fold(log)
        XCTAssertEqual(HouseholdInsights.houseXP(board, calendar: cal, xp: xp), 35 * 2 + 10 * 40)
        XCTAssertEqual(HouseholdInsights.houseXP(board, before: day(1), calendar: cal, xp: xp), 35 + 10 * 40, "Sam's day-1 tick excluded")
    }

    func testMoodFallsWithOverdueChoresAndRecoversWhenDone() {
        let fridge = UUID(), oven = UUID()
        var log = members([(alex, "Alex")])
        log += [chore(fridge, "Fridge", .l, .afterDone(days: 7), room: "Kitchen", at: day(-20)),
                chore(oven, "Oven", .m, .afterDone(days: 7), room: "Kitchen", at: day(-20))]
        log.append(op(.complete(chore: fridge, member: alex), at: day(-10)))
        log.append(op(.complete(chore: oven, member: alex), at: day(-10)))
        let slipping = ChoreBoard.fold(log)
        let low = HouseholdInsights.mood(slipping, now: day(0), calendar: cal)
        XCTAssertLessThan(low, 0.5)
        XCTAssertEqual(HouseholdInsights.moodDetail(slipping, now: day(0), calendar: cal), "2 chores overdue · the kitchen's slipping")

        log.append(op(.complete(chore: fridge, member: alex), at: day(0, hour: 8)))
        log.append(op(.complete(chore: oven, member: alex), at: day(0, hour: 8)))
        let tidy = ChoreBoard.fold(log)
        XCTAssertGreaterThan(HouseholdInsights.mood(tidy, now: day(0), calendar: cal), 0.9)
        XCTAssertNil(HouseholdInsights.moodDetail(tidy, now: day(0), calendar: cal))
        XCTAssertEqual(HouseholdInsights.moodTitle(0.8, paused: false), "Cosy, the house is on top of things")
    }

    func testPauseMeansNothingIsOverdueAndThePetDozes() {
        let fridge = UUID()
        var log = members([(alex, "Alex")])
        log.append(chore(fridge, "Fridge", .l, .afterDone(days: 7), at: day(-20)))
        log.append(op(.complete(chore: fridge, member: alex), at: day(-10)))
        log.append(op(.pauseHouse(until: nil), at: day(-5)))
        var board = ChoreBoard.fold(log)
        XCTAssertTrue(board.isPaused(at: day(0), calendar: cal))
        XCTAssertEqual(board.status(of: board.chores[fridge]!, now: day(0), calendar: cal), .due(overdueDays: 0))
        XCTAssertEqual(HouseholdInsights.mood(board, now: day(0), calendar: cal), 0.6)

        log.append(op(.resumeHouse, at: day(0, hour: 10)))
        board = ChoreBoard.fold(log)
        // Due day −3; days −3…−1 were paused, day 0 resumed at 10:00 (midday counts as unpaused) → 1 day.
        XCTAssertEqual(board.status(of: board.chores[fridge]!, now: day(1), calendar: cal), .due(overdueDays: 1))
    }

    func testAPauseUntilADateEndsOnItsOwn() {
        var log = members([(alex, "Alex")])
        log.append(op(.pauseHouse(until: "2026-10-07"), at: day(0)))   // Mon → Wed inclusive
        let board = ChoreBoard.fold(log)
        XCTAssertTrue(board.isPaused(at: day(2, hour: 20), calendar: cal))
        XCTAssertFalse(board.isPaused(at: day(3), calendar: cal))
    }

    // MARK: Streak

    func testStreakCountsMetWeeksAndSkipsPausedOnes() {
        let dishes = UUID()
        var log = members([(alex, "Alex")])
        log.append(chore(dishes, "Dishes", .s, .daily, at: day(-40)))
        func week(_ w: Int) -> Date { day(7 * w) }
        func weekKey(_ w: Int) -> String { ChoreSchedule.weekKey(week(w), calendar: cal) }
        // Weeks −4, −3 met; −2 paused (no goal met); −1 met; this week met so far.
        for w in [-4, -3, -1, 0] {
            log.append(op(.setGoal(week: weekKey(w), target: 2, reward: ""), at: week(w)))
            log.append(op(.complete(chore: dishes, member: alex), at: week(w).addingTimeInterval(3600)))
            log.append(op(.complete(chore: dishes, member: alex), at: week(w).addingTimeInterval(90_000)))
        }
        log.append(op(.pauseHouse(until: nil), at: week(-2).addingTimeInterval(-3600)))
        log.append(op(.resumeHouse, at: week(-1).addingTimeInterval(-3600)))
        let board = ChoreBoard.fold(log)
        XCTAssertEqual(HouseholdInsights.streak(board, now: day(2), calendar: cal), 4)

        // An unmet, unpaused week breaks it.
        log.append(op(.setGoal(week: weekKey(-5), target: 9, reward: ""), at: week(-5)))
        log.append(op(.setGoal(week: weekKey(-3), target: 9, reward: ""), at: week(-3).addingTimeInterval(1)))
        XCTAssertEqual(HouseholdInsights.streak(ChoreBoard.fold(log), now: day(2), calendar: cal), 2, "this week + last week")
    }

    // MARK: Fair share and lean

    func testFairShareAndBalanceThresholds() {
        let a = UUID(), b = UUID()
        var log = members([(alex, "Alex"), (sam, "Sam")])
        log += [chore(a, "A", .l, .daily), chore(b, "B", .m, .daily)]
        log.append(op(.complete(chore: a, member: alex), at: day(0)))   // Alex 3
        log.append(op(.complete(chore: b, member: sam), at: day(0)))    // Sam 2
        log.append(op(.complete(chore: b, member: alex), at: day(0, hour: 10)))   // shared round: Alex +2
        let board = ChoreBoard.fold(log)
        let shares = HouseholdInsights.fairShare(board, weekStart: ChoreSchedule.weekStart(day(0), calendar: cal), calendar: cal)
        XCTAssertEqual(shares.map(\.points), [5, 2])

        func split(_ p: [Int]) -> [HouseholdInsights.Share] {
            let total = Double(p.reduce(0, +))
            return p.enumerated().map { .init(member: .init(id: UUID(), name: "\($0.offset)"), points: $0.element, fraction: Double($0.element) / total) }
        }
        XCTAssertEqual(HouseholdInsights.balance(split([55, 45])), .balanced, "10 pp is balanced")
        XCTAssertEqual(HouseholdInsights.balance(split([56, 44])), .aBitUneven)
        XCTAssertEqual(HouseholdInsights.balance(split([625, 375])), .aBitUneven, "25 pp is a bit uneven")
        XCTAssertEqual(HouseholdInsights.balance(split([63, 37])), .uneven)
        XCTAssertNil(HouseholdInsights.balance(split([1])), "one member: nothing to compare")
    }

    func testLeanGivesARotatingChoreToTheLightestMember() {
        let bins = UUID(), other = UUID()
        var log = members([(alex, "Alex"), (sam, "Sam"), (jo, "Jo")])
        log.append(chore(bins, "Bins", .s, .weekly, .rotate([alex, sam, jo]), lean: true))
        log.append(chore(other, "Other", .l, .daily))
        let board0 = ChoreBoard.fold(log)
        XCTAssertEqual(board0.assignee(of: board0.chores[bins]!, now: day(1), calendar: cal), alex, "ties: rotation order")

        log.append(op(.complete(chore: other, member: alex), at: day(0)))
        log.append(op(.complete(chore: other, member: sam), at: day(0, hour: 10)))
        let board = ChoreBoard.fold(log)
        XCTAssertEqual(board.assignee(of: board.chores[bins]!, now: day(1), calendar: cal), jo, "Jo has done least")
    }

    // MARK: Help and thanks

    func testHelpRequestLifecycle() {
        let bath = UUID()
        var log = members([(alex, "Alex"), (jo, "Jo")])
        log.append(chore(bath, "Bathroom", .l, .weekly, .fixed(jo)))
        let ask = op(.askHelp(chore: bath, member: jo, note: "Away till Tue"), at: day(0))
        log.append(ask)
        XCTAssertEqual(ChoreBoard.fold(log).openHelpRequests(now: day(1)).map(\.note), ["Away till Tue"])

        var claimed = log
        claimed.append(op(.claim(chore: bath, member: alex), at: day(1)))
        XCTAssertTrue(ChoreBoard.fold(claimed).openHelpRequests(now: day(2)).isEmpty, "someone took it")

        var done = log
        done.append(op(.complete(chore: bath, member: jo), at: day(1)))
        XCTAssertTrue(ChoreBoard.fold(done).openHelpRequests(now: day(2)).isEmpty, "done")

        var retracted = log
        retracted.append(op(.undo(op: ask.id), at: day(1)))
        XCTAssertTrue(ChoreBoard.fold(retracted).openHelpRequests(now: day(2)).isEmpty, "taken back")
    }

    func testThanksFoldAndUndo() {
        var log = members([(alex, "Alex"), (sam, "Sam")])
        let t = op(.thank(member: sam, by: alex, chore: nil), at: day(0))
        log.append(t)
        XCTAssertEqual(ChoreBoard.fold(log).thanks.map(\.member), [sam])
        log.append(op(.undo(op: t.id), at: day(0, hour: 10)))
        XCTAssertTrue(ChoreBoard.fold(log).thanks.isEmpty)
    }

    // MARK: Recap

    func testRecapGivesEachMemberTheirBestLine() {
        let bath = UUID(), fridge = UUID(), dishes = UUID(), bins = UUID()
        var log = members([(alex, "Alex"), (sam, "Sam"), (jo, "Jo"), (UUID(), "Idle")])
        log += [chore(bath, "Bathroom", .l, .weekly, .fixed(jo)),
                chore(fridge, "Fridge", .l, .afterDone(days: 14), at: day(-30)),
                chore(dishes, "Dishes", .s, .daily),
                chore(bins, "Bins", .s, .weekly)]
        log.append(op(.setGoal(week: ChoreSchedule.weekKey(day(0), calendar: cal), target: 6, reward: "Pizza"), at: day(0)))
        log.append(op(.askHelp(chore: bath, member: jo, note: ""), at: day(0)))
        log.append(op(.complete(chore: bath, member: sam), at: day(1)))                 // Sam took Jo's
        log.append(op(.complete(chore: fridge, member: alex), at: day(2)))              // 16 days in: 2 overdue…
        log.append(op(.complete(chore: fridge, member: alex), at: day(-20)))            // …prior tick at −20 → due −6 → 8 late
        for d in 0..<5 { log.append(op(.complete(chore: dishes, member: jo), at: day(d, hour: 20))) }   // 5 in a row
        log.append(op(.thank(member: sam, by: jo, chore: bath), at: day(2)))
        let board = ChoreBoard.fold(log)
        let recap = HouseholdInsights.recap(board, weekStart: ChoreSchedule.weekStart(day(0), calendar: cal), calendar: cal,
                                            xp: xp, level: { Progression.levelInfo(totalXP: $0).level })
        let lines = Dictionary(uniqueKeysWithValues: recap.lines.map { ($0.member.name, $0.text) })
        XCTAssertEqual(lines["Sam"], "took Jo's bathroom when they asked for a hand")
        XCTAssertEqual(lines["Alex"], "finally did the fridge (8 days overdue)")
        XCTAssertEqual(lines["Jo"], "did the dishes 5 days in a row")
        XCTAssertNil(lines["Idle"], "no line, never a call-out")
        XCTAssertEqual(recap.rounds, 7)
        XCTAssertTrue(recap.goalMet)
        XCTAssertEqual(recap.thanks.count, 1)
        XCTAssertGreaterThanOrEqual(recap.levelAfter, recap.levelBefore)
    }

    // MARK: Sync

    @MainActor
    func testCooperativeOpsConvergeAcrossTwoPhones() throws {
        func store() throws -> (HouseholdStore, ModelContainer) {
            let c = try ModelContainer(for: Schema(SnappetSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            return (HouseholdStore(context: c.mainContext), c)
        }
        let (a, ca) = try store(), (b, cb) = try store()
        defer { _ = (ca, cb); HouseholdXP.shared.publish([]) }
        a.ensureKey()
        let inv = HouseholdInvite.make(householdID: a.household.id, name: "Home")
        let me = HouseholdSyncMachine.Identity(device: UUID(), member: UUID(), name: "Sam")
        func pump(_ d: HouseholdSyncMachine, _ l: HouseholdSyncMachine) {
            var toL = d.start(), toD: [Data] = []
            for _ in 0..<50 where !(toL.isEmpty && toD.isEmpty) {
                let x = toL; toL = []; for f in x { toD += l.receive(f) }
                let y = toD; toD = []; for f in y { toL += d.receive(f) }
            }
        }
        var secrets = HouseholdSyncMachine.ListenerSecrets(householdKey: a.household.key, log: a.syncLog)
        secrets.invite = (inv.token, HouseholdWelcome(householdID: a.household.id, name: "Home", key: a.household.key))
        pump(HouseholdSyncMachine(dialing: .join, identity: me, secret: inv.token, log: nil,
                                  onWelcome: { b.join($0, as: me, bringChores: false) }),
             HouseholdSyncMachine(listening: a.identity, secrets: secrets))

        a.create(ChoreFields(name: "Bins", effort: .s, repeats: .weekly, assignment: .rotate([a.me, b.me]), lean: true))
        a.namePet("Mochi")
        a.pauseHouse()
        b.thank(a.me, for: nil)
        let sync = { pump(HouseholdSyncMachine(dialing: .sync, identity: a.identity, secret: a.household.key, log: a.syncLog),
                          HouseholdSyncMachine(listening: b.identity, secrets: .init(householdKey: b.household.key, log: b.syncLog))) }
        sync()
        b.askHelp(try XCTUnwrap(b.board.activeChores.first), note: "Busy")
        sync()
        XCTAssertEqual(a.board, b.board)
        XCTAssertEqual(b.petName, "Mochi")
        XCTAssertTrue(b.board.isPaused(at: .now))
        XCTAssertEqual(a.board.thanks.count, 1)
        XCTAssertEqual(a.board.openHelpRequests().count, 1)
        XCTAssertEqual(b.board.activeChores.first?.lean, true)
    }
}
