import XCTest
import HighlightEngine
@testable import Snappet

/// Regression guard for the shared `SessionRecap` scaffold (workout-redesign E0): the extracted
/// `heroCells` must pick the SAME three cells per dominant discipline that `FreeformDoneSummaryView` used
/// inline before the extraction (the "no behavior change" requirement). Pure — no view, no device.
final class SessionRecapTests: XCTestCase {

    private func lift(_ reps: Int, _ kg: Double) -> SetLog {
        SetLog(actualReps: reps, actualWeight: kg, weightUnit: .kg, completedAt: Date(timeIntervalSince1970: 0))
    }
    private func climb(_ grade: String, _ status: KilterAscentStatus) -> SetLog {
        SetLog(completedAt: Date(timeIntervalSince1970: 0), climbGradeLabel: grade,
               climbStatusRaw: status.rawValue, climbAttempts: 1)
    }
    private func timed(_ sec: Double) -> SetLog {
        SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: sec)
    }
    private func run(_ meters: Double, _ sec: Double) -> SetLog {
        var s = SetLog(completedAt: Date(timeIntervalSince1970: 0), durationSec: sec); s.distanceMeters = meters; return s
    }
    private func entity(_ id: String, _ d: WorkoutDiscipline, _ sets: [SetLog]) -> SessionExercise {
        var ex = SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                 sets: sets, kindRaw: d.defaultSetKind.rawValue)
        ex.disciplineRaw = d.rawValue
        return ex
    }
    private func session(_ ex: [SessionExercise]) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 0)
        return WorkoutSession(routineID: nil, routineName: "S", startedAt: start,
                              completedAt: start.addingTimeInterval(1800), exercises: ex)
    }
    private func cells(_ s: WorkoutSession, unit: WeightUnit = .kg,
                       milestones: [FreeformSummary.Milestone] = []) -> [FreeformSummary.Stat] {
        let stats = FreeformSummary.stats(for: s, unit: unit)
        let climbStats = FreeformClimbStats.stats(for: s, now: Date(timeIntervalSince1970: 1800), hrSeries: [])
        return SessionRecap.heroCells(stats: stats, climbStats: climbStats, session: s, unit: unit, milestones: milestones)
    }

    func testLiftingHero() {
        let s = session([entity("squat", .strength, [lift(5, 100)])])
        let c = cells(s, milestones: [.personalRecord(exerciseId: "squat", bestKg: 100, reps: 5)])
        XCTAssertEqual(c.map(\.label), ["Volume", "Sets", "PRs"])
        XCTAssertEqual(c[2].value, "1")     // one PR this session
    }

    func testClimbingHeroNoTimingShowsClimbsCount() {
        let s = session([entity("c", .climb, [climb("V4", .sent), climb("V2", .flash)])])
        let c = cells(s)
        XCTAssertEqual(c.map(\.label), ["Sends", "Hardest", "Climbs"])
        XCTAssertEqual(c[1].value, "V4")    // hardest send grade
    }

    func testTimedHero() {
        let s = session([entity("plank", .timed, [timed(30), timed(45)])])
        let c = cells(s)
        XCTAssertEqual(c.map(\.label), ["Hold time", "Best", "Sets"])
        XCTAssertEqual(c[1].value, SetMeasure.formatDuration(45))   // best hold
    }

    func testRunningHero() {
        let s = session([entity("run", .run, [run(5000, 1500)])])
        let c = cells(s)
        XCTAssertEqual(c.map(\.label), ["Distance", "Pace", "Duration"])
        XCTAssertEqual(c[0].value, SetMeasure.formatDistance(5000, unit: .km))
    }

    func testRunningHeroMilesWhenLbUnit() {
        let s = session([entity("run", .run, [run(5000, 1500)])])
        let c = cells(s, unit: .lb)
        XCTAssertEqual(c[0].value, SetMeasure.formatDistance(5000, unit: .mi))
    }
}
