import XCTest
@testable import Snappet

/// Unit tests for the **pure** `FreeformClimbStats` bridge that turns a freeform session's climb
/// exercises into `KilterSessionStats` (sends, hardest, pyramid, sends/hr) — no SwiftData, no device.
final class FreeformClimbStatsTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A climb exercise: name + type + grade at the climb level, with attempt `SetLog`s underneath.
    private func climb(_ name: String, type: ClimbType = .boulder, scale: GradeScale = .vScale,
                       grade: String, attempts: [(KilterAscentStatus, Double?, Int)],
                       startAt: TimeInterval = 0) -> SessionExercise {
        var sets: [SetLog] = []
        for (i, a) in attempts.enumerated() {
            sets.append(SetLog(
                completedAt: t0.addingTimeInterval(startAt + Double(i) * 60),
                durationSec: a.1,
                climbGradeLabel: grade, climbStatusRaw: a.0.rawValue, climbAttempts: a.2))
        }
        return SessionExercise(
            exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "", targetRestSeconds: 0,
            sets: sets, displayName: name, kindRaw: SetKind.climbAttempt.rawValue,
            climbTypeRaw: type.rawValue, climbGradeLabel: grade, climbGradeScaleRaw: scale.rawValue)
    }

    private func session(_ exercises: [SessionExercise], durationSec: TimeInterval) -> WorkoutSession {
        WorkoutSession(routineID: nil, routineName: "Quick session", startedAt: t0,
                       completedAt: t0.addingTimeInterval(durationSec), exercises: exercises)
    }

    func testFreshClimbWithNoAttemptsYieldsNoLog() {
        let ex = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "",
                                 targetRestSeconds: 0, sets: [], displayName: "Slab",
                                 kindRaw: SetKind.climbAttempt.rawValue,
                                 climbTypeRaw: "boulder", climbGradeLabel: "V4", climbGradeScaleRaw: "vScale")
        XCTAssertNil(FreeformClimbStats.log(for: ex))
    }

    func testLogResolvesBestStatusAndSumsAttempts() {
        // Two attempt-logs on one V5: a 2-bid project then a flash (best status wins).
        let ex = climb("Cave Roof", grade: "V5",
                       attempts: [(.project, 52, 2), (.flash, 38, 1)])
        let log = FreeformClimbStats.log(for: ex)
        XCTAssertEqual(log?.climbName, "Cave Roof")
        XCTAssertEqual(log?.gradeLabel, "V5")
        XCTAssertEqual(log?.difficulty, GradeScale.vScale.difficulty(for: "V5"))
        XCTAssertEqual(log?.status, .flash)         // best of {project, flash}
        XCTAssertEqual(log?.attempts, 3)            // 2 + 1
        XCTAssertTrue(log?.isSend ?? false)
    }

    func testSessionStatsSendsHardestAndPyramid() {
        let s = session([
            climb("Blue #3", grade: "V3", attempts: [(.flash, nil, 1)]),
            climb("Cave Roof", grade: "V5", attempts: [(.sent, nil, 3)]),
            climb("Slab Project", grade: "V4", attempts: [(.project, nil, 5)]),  // not a send
        ], durationSec: 3600)
        let stats = FreeformClimbStats.stats(for: s, now: t0.addingTimeInterval(3600))
        XCTAssertEqual(stats.totalClimbs, 3)
        XCTAssertEqual(stats.sends, 2)              // flash + sent
        XCTAssertEqual(stats.projects, 1)
        XCTAssertEqual(stats.hardestSendGrade, "V5")
        // Pyramid: sends grouped by grade, easiest→hardest (V3 then V5; the V4 project is not a send).
        XCTAssertEqual(stats.pyramid.map(\.gradeLabel), ["V3", "V5"])
        XCTAssertEqual(stats.sendsPerHour, 2, accuracy: 0.001)   // 2 sends / 1 hour
    }

    func testRouteClimbStatsUseYdsOrdering() {
        let s = session([
            climb("Yellow Arete", type: .topRope, scale: .yds, grade: "5.10a", attempts: [(.sent, nil, 2)]),
            climb("Overhang", type: .lead, scale: .yds, grade: "5.11c", attempts: [(.sent, nil, 4)]),
        ], durationSec: 7200)
        let stats = FreeformClimbStats.stats(for: s, now: t0.addingTimeInterval(7200))
        XCTAssertEqual(stats.sends, 2)
        XCTAssertEqual(stats.hardestSendGrade, "5.11c")
        XCTAssertEqual(stats.pyramid.map(\.gradeLabel), ["5.10a", "5.11c"])
    }

    func testHasClimbingGate() {
        let empty = session([], durationSec: 60)
        XCTAssertFalse(FreeformClimbStats.hasClimbing(empty))
        let withClimb = session([climb("X", grade: "V2", attempts: [(.sent, nil, 1)])], durationSec: 60)
        XCTAssertTrue(FreeformClimbStats.hasClimbing(withClimb))
    }
}
