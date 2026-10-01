import XCTest
import SwiftData
@testable import Snappet

/// Progression P1 (prompt 148): XP per session, the daily cap, backfilled ledger, permanent levels,
/// stages and Form.
@MainActor
final class ProgressionTests: XCTestCase {
    private var container: ModelContainer!
    private var all: [WorkoutSession] = []
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let cal = Calendar.current

    override func setUp() async throws {
        container = try ModelContainer(for: Schema(SnappetSchema.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        RoutineHistorySeed.seed(into: container.mainContext, now: now)
        all = try container.mainContext.fetch(FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)]))
    }

    override func tearDown() async throws { container = nil }

    private func session(_ start: Date, minutes: Double, routineID: UUID? = nil, name: String = "Test",
                         sets: Int = 3) -> WorkoutSession {
        let logs: [SetLog] = (0..<sets).map { k in
            var s = SetLog(actualReps: 5, actualWeight: 40, weightUnit: .kg)
            s.completedAt = start.addingTimeInterval(Double(k + 1) * 60)
            return s
        }
        let ex = SessionExercise(exerciseId: "Barbell_Squat", targetSets: sets, targetReps: "5", targetRestSeconds: 90, sets: logs)
        return WorkoutSession(routineID: routineID, routineName: name, startedAt: start,
                              completedAt: start.addingTimeInterval(minutes * 60), exercises: [ex])
    }

    // MARK: - Levels

    func testLevelCurveAndStages() {
        XCTAssertEqual(Progression.levelInfo(totalXP: 0).level, 1)
        XCTAssertEqual(Progression.levelInfo(totalXP: 149).level, 1)
        XCTAssertEqual(Progression.levelInfo(totalXP: 150).level, 2)       // 100 + 50·1
        XCTAssertEqual(Progression.levelInfo(totalXP: 150).xpIntoLevel, 0)
        XCTAssertEqual(Progression.levelInfo(totalXP: 3_150).level, 10)    // Σ 100+50n, n = 1…9
        XCTAssertEqual(Progression.levelInfo(totalXP: 3_149).level, 9)
        XCTAssertEqual(Progression.levelInfo(totalXP: 3_150).stage, .adult)
        XCTAssertEqual([1, 2, 4, 5, 9, 10, 19, 20, 40].map { Progression.stage(forLevel: $0) },
                       [.egg, .hatchling, .hatchling, .sprout, .sprout, .adult, .adult, .legend, .legend])
        XCTAssertEqual(Progression.nextStageLevel(after: 12), 20)
        XCTAssertNil(Progression.nextStageLevel(after: 20))
    }

    // MARK: - XP per session

    func testStrengthSessionEarnsFinishMinutesAndRecords() {
        let push = all.filter { $0.routineName == "Push Day" }.last!
        let earlier = all.filter { $0.startedAt < push.startedAt }
        let items = Progression.items(for: push, earlier: earlier, schedule: nil)
        XCTAssertEqual(items.first, .init(label: "Session finished", xp: 50))
        XCTAssertTrue(items.contains { $0.label.hasSuffix("active minutes") && (46...56).contains($0.xp) })
        XCTAssertTrue(items.contains { $0.label.hasPrefix("🏆") && $0.label.contains("PR") }, "\(items)")
        XCTAssertLessThanOrEqual(items.filter { $0.label.hasPrefix("🏆") }.count, Progression.Rules.recordMax)
    }

    func testMinutesCapAndTooShortOrEmptyEarnsNothing() {
        let long = session(now, minutes: 150)
        XCTAssertEqual(Progression.items(for: long, earlier: [], schedule: nil)
            .first { $0.label.hasSuffix("active minutes") }?.xp, 60)
        XCTAssertTrue(Progression.items(for: session(now, minutes: 4), earlier: [], schedule: nil).isEmpty)
        XCTAssertTrue(Progression.items(for: session(now, minutes: 30, sets: 0), earlier: [], schedule: nil).isEmpty)
    }

    func testOnPlanBonusUsesTheRoutineSchedule() {
        let id = UUID()
        var everyDay = RoutineSchedule(startDay: DayKey(now.addingTimeInterval(-86_400 * 10), calendar: cal))
        everyDay.repeatRule = .weekly(weekdays: [1, 2, 3, 4, 5, 6, 7], everyWeeks: 1)
        let s = session(now, minutes: 30, routineID: id)
        XCTAssertTrue(Progression.items(for: s, earlier: [], schedule: everyDay).contains { $0.xp == 20 && $0.label.hasPrefix("On plan") })
        XCTAssertFalse(Progression.items(for: s, earlier: [], schedule: nil).contains { $0.label.hasPrefix("On plan") })
    }

    func testWeekStreakPaysOncePerWeek() {
        // Three consecutive weeks, two sessions in the latest week.
        let w0 = now.addingTimeInterval(-86_400 * 14), w1 = now.addingTimeInterval(-86_400 * 7)
        let a = session(w0, minutes: 30), b = session(w1, minutes: 30)
        let c = session(now, minutes: 30)
        let d = session(now.addingTimeInterval(3_600 * 3), minutes: 30)
        let streakC = Progression.items(for: c, earlier: [a, b], schedule: nil).first { $0.label.contains("week streak") }
        XCTAssertEqual(streakC?.xp, 30)
        XCTAssertNil(Progression.items(for: d, earlier: [a, b, c], schedule: nil).first { $0.label.contains("week streak") },
                     "only the week's first session pays the streak")
    }

    func testHealthImportEarnsAFlat25() {
        let s = session(now, minutes: 40, sets: 0)
        s.healthKitWorkoutUUID = UUID()
        XCTAssertEqual(Progression.items(for: s, earlier: [], schedule: nil), [.init(label: "Apple Health workout", xp: 25)])
    }

    // MARK: - Ledger

    func testLedgerBackfillsEveryPastSession() {
        let ledger = Progression.ledger(all, schedules: [:])
        XCTAssertEqual(ledger.sessionCount, all.count)
        XCTAssertEqual(ledger.totalXP, ledger.awards.values.reduce(0) { $0 + $1.total })
        XCTAssertGreaterThan(Progression.levelInfo(totalXP: ledger.totalXP).level, 5, "23 sessions of history count")
    }

    func testDailyCapTrimsManySessionsInOneDay() {
        let day = cal.startOfDay(for: now).addingTimeInterval(3_600 * 8)
        let many = (0..<5).map { session(day.addingTimeInterval(Double($0) * 7_200), minutes: 60) }
        let ledger = Progression.ledger(many, schedules: [:])
        XCTAssertEqual(ledger.totalXP, Progression.Rules.dailyCap)
        XCTAssertTrue(ledger.awards[many.last!.id]!.capped)
        XCTAssertEqual(ledger.awards[many.last!.id]!.total, 0)
    }

    func testCurrentSessionIsIncludedBeforeItIsSaved() {
        let active = session(now.addingTimeInterval(3_600), minutes: 30)
        active.completedAt = nil
        let without = Progression.ledger(all + [active], schedules: [:])
        XCTAssertNil(without.awards[active.id], "an active session is ignored")
        let with = Progression.ledger(all, including: active, schedules: [:])
        XCTAssertNotNil(with.awards[active.id])
        XCTAssertEqual(with.xp(before: active.id), without.totalXP)
    }

    func testLedgerOverYearsOfHistoryIsCachedSoFinishingStaysFast() {
        // ~3 sessions a week for 3 years. The first pass walks all of history; after that only what
        // changed is recomputed — a newly finished session, or everything after an edited one.
        let many = (0..<450).reversed().map { session(now.addingTimeInterval(-86_400 * Double($0) * 2.4), minutes: 45, sets: 12) }
        func timed(_ f: () -> Progression.Ledger) -> (Progression.Ledger, TimeInterval) {
            let t = Date(); let l = f(); return (l, Date().timeIntervalSince(t))
        }
        let (cold, coldT) = timed { Progression.ledger(many, schedules: [:]) }
        let (warm, warmT) = timed { Progression.ledger(many, schedules: [:]) }
        XCTAssertEqual(cold, warm)
        let next = session(now.addingTimeInterval(3_600), minutes: 45, sets: 12)
        next.completedAt = nil
        let (_, finishT) = timed { Progression.ledger(many, including: next, schedules: [:]) }
        print("ledger 450 sessions: cold \(coldT)s · warm \(warmT)s · finishing one \(finishT)s")
        XCTAssertLessThan(warmT, 0.3)
        XCTAssertLessThan(finishT, 0.4)

        // Editing an old session re-judges everything after it (records depend on history).
        many[440].exercises[0].sets[0].actualWeight = 200
        let edited = Progression.ledger(many, schedules: [:])
        XCTAssertNotEqual(edited.awards[many[440].id], cold.awards[many[440].id])
    }

    // MARK: - Form

    func testFormIsDoneOverPlannedWithSkipsNeutral() {
        let id = UUID()
        var sched = RoutineSchedule(startDay: DayKey(now.addingTimeInterval(-86_400 * 60), calendar: cal))
        sched.repeatRule = .weekly(weekdays: [1, 2, 3, 4, 5, 6, 7], everyWeeks: 1)
        // Done on 21 of the last 27 days (today not done yet → not counted).
        var sessions: [WorkoutSession] = []
        for d in 1...27 where d % 4 != 0 {
            sessions.append(session(now.addingTimeInterval(-86_400 * Double(d)), minutes: 20, routineID: id))
        }
        let form = Progression.form(sessions, schedules: [id: sched], now: now)
        XCTAssertEqual(form.basis, .plan(done: 21, planned: 27))
        XCTAssertEqual(form.value, 21.0 / 27, accuracy: 0.001)

        // Skipping one of the missed days with a reason takes it out of "planned".
        let missed = DayKey(now.addingTimeInterval(-86_400 * 4), calendar: cal)
        sched.skippedSlots = [SlotKey(day: missed, index: 0)]
        XCTAssertEqual(Progression.form(sessions, schedules: [id: sched], now: now).basis, .plan(done: 21, planned: 26))
    }

    func testFormWithoutAScheduleComparesWithYourUsualWeek() {
        // Usual: 3 a week for the 12 weeks before; lately 1.5 a week → Form 50 %.
        var sessions: [WorkoutSession] = []
        for w in 0..<12 { for k in 0..<3 {
            sessions.append(session(now.addingTimeInterval(-86_400 * Double(30 + w * 7 + k * 2)), minutes: 30))
        } }
        for k in 0..<6 { sessions.append(session(now.addingTimeInterval(-86_400 * Double(1 + k * 4)), minutes: 30)) }
        let form = Progression.form(sessions, schedules: [:], now: now)
        guard case .usual(let recent, let usual) = form.basis else { return XCTFail("\(form.basis)") }
        XCTAssertEqual(recent, 1.5, accuracy: 0.01)
        XCTAssertEqual(usual, 3, accuracy: 0.01)
        XCTAssertEqual(form.value, 0.5, accuracy: 0.01)
        XCTAssertEqual(Progression.form([], schedules: [:], now: now).basis, .new)
    }

    func testOverallWeekStreakNeedsARecentSession() {
        XCTAssertGreaterThanOrEqual(Progression.weekStreak(all, now: now), 4)
        XCTAssertEqual(Progression.weekStreak(all, now: now.addingTimeInterval(86_400 * 30)), 0, "lapsed")
    }
}
