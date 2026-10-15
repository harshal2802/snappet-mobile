import XCTest
@testable import Snappet

/// `LibraryCatalog` — the Library's "Yours" tab (Library redesign L1, prompt 183).
final class LibraryCatalogTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(daysAgo: Double, _ ex: [SessionExercise]) -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        let done = ex.map { e -> SessionExercise in
            var e = e
            for i in e.sets.indices { e.sets[i].completedAt = start }
            return e
        }
        return WorkoutSession(routineName: "S", startedAt: start, completedAt: start.addingTimeInterval(3600), exercises: done)
    }

    private func lift(_ id: String, _ kg: Double, _ reps: Int) -> SessionExercise {
        SessionExercise(exerciseId: id, targetSets: 1, targetReps: "", targetRestSeconds: 0,
                        sets: [SetLog(actualReps: reps, actualWeight: kg, weightUnit: .kg)])
    }

    private func climb(_ name: String, grade: String, _ statuses: [KilterAscentStatus], gym: String = "Gravity") -> SessionExercise {
        var e = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                sets: statuses.map { SetLog(climbGradeLabel: grade, climbStatusRaw: $0.rawValue) },
                                displayName: name, kindRaw: SetKind.climbAttempt.rawValue)
        e.gym = gym; e.climbGradeLabel = grade
        return e
    }

    private func run(_ secs: Double) -> SessionExercise {
        var e = SessionExercise(exerciseId: "adhoc-run", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                sets: [SetLog(durationSec: secs, distanceMeters: 5_000)], displayName: "Riverside 5k",
                                kindRaw: SetKind.duration.rawValue)
        e.disciplineRaw = WorkoutDiscipline.run.rawValue
        return e
    }

    private func rows(_ history: [WorkoutSession]) -> [LibraryCatalog.Row] {
        LibraryCatalog.yours(history: history, identity: ActivityIdentity(sessions: history), unit: .kg, now: now,
                             title: LibraryCatalog.fallbackTitle)
    }

    // MARK: - Yours

    func testYoursHasEveryLoggedActivityWithUsage() throws {
        let history = [
            session(daysAgo: 200, [lift("bench", 60, 8)]),          // outside the 90-day window
            session(daysAgo: 20, [lift("bench", 70, 8), climb("Blue crimp", grade: "V5", [.attempt, .attempt])]),
            session(daysAgo: 2, [lift("bench", 75, 8), climb("Blue crimp", grade: "V5", [.sent]), run(1_700)]),
        ]
        let r = rows(history)
        XCTAssertEqual(r.count, 3)
        let bench = try XCTUnwrap(r.first { $0.key == ActivityKey(exerciseId: "bench", nameKey: "") })
        XCTAssertEqual(bench.sessions, 3)
        XCTAssertEqual(bench.recentSessions, 2)
        XCTAssertEqual(bench.headline, "75 kg × 8")
        let crimp = try XCTUnwrap(r.first { $0.discipline == .climb })
        XCTAssertEqual(crimp.sessions, 2)
        XCTAssertEqual(crimp.climb?.attempts, 3)
        XCTAssertEqual(crimp.climb?.sent, true)
        XCTAssertEqual(crimp.climb?.gym, "Gravity")
        XCTAssertEqual(r.first { $0.discipline == .run }?.headline, "5:40/km")
    }

    func testAResetClimbIsTwoRowsAndTheOlderIsMarked() {
        let r = rows([session(daysAgo: 70, [climb("Blue crimp", grade: "V5", [.attempt])]),
                      session(daysAgo: 3, [climb("Blue crimp", grade: "V5", [.sent])])])
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.filter { $0.climb?.isReset == true }.count, 1)
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .recent).last?.climb?.isReset, true, "the older set is the reset one")
    }

    func testActiveSessionsAndEmptyEntitiesAreLeftOut() {
        let live = session(daysAgo: 0, [lift("squat", 100, 5)]); live.completedAt = nil
        let planned = WorkoutSession(routineName: "P", startedAt: now, completedAt: now,
                                     exercises: [SessionExercise(exerciseId: "row", targetSets: 3, targetReps: "8",
                                                                 targetRestSeconds: 0, sets: [])])
        XCTAssertEqual(rows([live, planned]).count, 0)
    }

    // MARK: - Sort

    func testSorts() {
        let history = [
            session(daysAgo: 300, [lift("deadlift", 180, 3)]),
            session(daysAgo: 250, [lift("deadlift", 170, 3)]),
            session(daysAgo: 240, [lift("deadlift", 170, 3)]),       // most sessions all-time, none recent
            session(daysAgo: 30, [lift("bench", 80, 5)]),
            session(daysAgo: 10, [lift("bench", 80, 5), lift("curl", 20, 10)]),
        ]
        let r = rows(history).filter { $0.discipline == .strength }
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .mostUsed).map(\.key.exerciseId), ["bench", "curl", "deadlift"],
                       "recent use outranks old totals")
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .recent).first?.key.exerciseId, "bench")
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .best).first?.key.exerciseId, "deadlift", "highest e1RM")
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .name).map(\.title), ["bench", "curl", "deadlift"])
    }

    func testHardestGradeAndAttemptsForClimbs() {
        let r = rows([session(daysAgo: 4, [climb("Easy", grade: "V2", [.attempt, .attempt, .attempt, .sent]),
                                           climb("Hard", grade: "V6", [.attempt])])])
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .best).first?.title, "Hard")
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .attempts).first?.title, "Easy")
    }

    func testSortOptionsFollowTheDiscipline() {
        XCTAssertFalse(LibraryCatalog.sorts(for: nil).contains(.best), "All mixes units")
        XCTAssertTrue(LibraryCatalog.sorts(for: .climb).contains(.attempts))
        XCTAssertEqual(LibraryCatalog.Sort.best.label(for: .run), "Fastest pace")
    }

    // MARK: - Filter

    func testClimbFiltersAndSearch() {
        let r = rows([session(daysAgo: 4, [climb("Blue crimp", grade: "V5", [.sent]),
                                           climb("Yellow slab", grade: "V4", [.attempt]),
                                           climb("Arete", grade: "V3", [.flash], gym: "Crux")])])
        XCTAssertEqual(LibraryCatalog.filter(r, query: "", discipline: .climb, climbFilter: .projects).map(\.title), ["Yellow slab"])
        XCTAssertEqual(Set(LibraryCatalog.filter(r, query: "", discipline: .climb, climbFilter: .sent).map(\.title)),
                       ["Blue crimp", "Arete"])
        XCTAssertEqual(LibraryCatalog.filter(r, query: "crux", discipline: nil).map(\.title), ["Arete"], "search covers the gym")
    }

    func testUnnamedClimbTitle() {
        var e = climb("", grade: "V4", [.attempt])
        e.displayName = nil; e.climbColorRaw = ClimbColor.yellow.rawValue; e.wall = "Cave"
        XCTAssertEqual(LibraryCatalog.fallbackTitle(e), "V4 Yellow · Cave")
    }

    // MARK: - Festivals

    private func festivalNight(_ festival: String, daysAgo: Double, _ artists: [String]) -> WorkoutSession {
        let sets = artists.map { a -> SessionExercise in
            var e = SessionExercise(exerciseId: "festival-set", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                    sets: [SetLog(durationSec: 1_800)], displayName: "\(a) · Main",
                                    kindRaw: SetKind.duration.rawValue)
            e.disciplineRaw = WorkoutDiscipline.dance.rawValue
            return e
        }
        let s = session(daysAgo: daysAgo, sets)
        s.routineName = festival
        return s
    }

    func testFestivalSetsAreOneRowPerFestivalNamedAfterIt() throws {
        let r = rows([festivalNight("Lost Lands", daysAgo: 40, ["Excision", "Subtronics"]),
                      festivalNight("Lost Lands", daysAgo: 39, ["ALLDAT: Crankdat B2B Riot Ten"]),
                      festivalNight("Shambhala", daysAgo: 5, ["Fred again.."])])
        XCTAssertEqual(r.count, 2, "one row per festival, not per artist and not all festivals together")
        let lostLands = try XCTUnwrap(r.first { $0.title == "Lost Lands" })
        XCTAssertEqual(lostLands.sessions, 2, "nights attended")
        XCTAssertEqual(lostLands.discipline, .dance)
        XCTAssertEqual(lostLands.headline, SetMeasure.formatDuration(3 * 1_800), "total time danced")
        XCTAssertTrue(r.contains { $0.title == "Shambhala" })
        XCTAssertNil(ActivityKey.plain(festivalNight("X", daysAgo: 1, ["A"]).exercises[0]))
    }

    // MARK: - Counting (days by default)

    /// A festival night where the user ended the session after every set → one session per set.
    private func nightOneSessionPerSet(_ festival: String, daysAgo: Double, sets: Int) -> [WorkoutSession] {
        // Anchored at 7 pm local so the hourly sets (7 pm → midnight) stay inside one 5 am-to-5 am night.
        let evening = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0,
                                            of: now.addingTimeInterval(-daysAgo * 86_400))!
        return (0..<sets).map { i in
            let s = festivalNight(festival, daysAgo: daysAgo, ["Artist \(i)"])
            s.startedAt = evening.addingTimeInterval(Double(i) * 3600)
            return s
        }
    }

    func testAFestivalNightEndedAfterEverySetIsOneDayAndManySets() throws {
        let r = rows(nightOneSessionPerSet("Lost Lands", daysAgo: 3, sets: 3))
        let row = try XCTUnwrap(r.first)
        XCTAssertEqual(row.sessions, 3, "the raw sessions are still known")
        XCTAssertEqual(row.days, 1, "but it was one night")
        XCTAssertEqual(row.efforts, 3)
        XCTAssertEqual(LibraryCatalog.countLabel(row, .days), "1 day")
        XCTAssertEqual(LibraryCatalog.countLabel(row, .efforts), "3 sets")
        XCTAssertEqual(LibraryCatalog.countLabel(row, .sessions), "3 sessions")
    }

    func testALateSetCountsTowardTheNightItStarted() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let evening = cal.date(bySettingHour: 22, minute: 0, second: 0, of: now)!
        let oneAM = evening.addingTimeInterval(3 * 3600)
        XCTAssertEqual(LibraryCatalog.activeDay(evening, calendar: cal), LibraryCatalog.activeDay(oneAM, calendar: cal))
        XCTAssertNotEqual(LibraryCatalog.activeDay(evening, calendar: cal),
                          LibraryCatalog.activeDay(evening.addingTimeInterval(86_400), calendar: cal))
    }

    func testMostUsedRanksByDaysNotSessions() {
        let festival = nightOneSessionPerSet("Lost Lands", daysAgo: 3, sets: 6)    // 6 sessions, 1 day
        let gym = [session(daysAgo: 10, [lift("bench", 80, 5)]), session(daysAgo: 6, [lift("bench", 80, 5)])]
        let r = rows(festival + gym)
        XCTAssertEqual(LibraryCatalog.sorted(r, by: .mostUsed).first?.key.exerciseId, "bench", "2 days beat 1 night")
    }

    func testEffortNounsFollowTheDiscipline() {
        XCTAssertEqual(LibraryCatalog.CountUnit.efforts.label(for: .climb), "Attempts")
        XCTAssertEqual(LibraryCatalog.CountUnit.efforts.label(for: .run), "Legs")
        XCTAssertEqual(LibraryCatalog.CountUnit.efforts.label(for: .dance), "Sets")
    }
}
