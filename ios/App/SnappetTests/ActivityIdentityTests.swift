import XCTest
@testable import Snappet

/// `ActivityIdentity` (Library redesign L1, prompt 183): a climb = its base identity + its set window, because gyms
/// reset their climbs every few weeks.
final class ActivityIdentityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func climb(_ name: String?, gym: String? = "Gravity", wall: String? = nil, grade: String = "V5",
                       color: ClimbColor? = nil) -> SessionExercise {
        var e = SessionExercise(exerciseId: "adhoc-climbAttempt", targetSets: 0, targetReps: "", targetRestSeconds: 0,
                                sets: [SetLog(completedAt: now, climbGradeLabel: grade, climbStatusRaw: "attempt")],
                                displayName: name, kindRaw: SetKind.climbAttempt.rawValue)
        e.gym = gym; e.wall = wall; e.climbGradeLabel = grade; e.climbColorRaw = color?.rawValue
        return e
    }

    private func session(daysAgo: Double, _ ex: [SessionExercise]) -> WorkoutSession {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return WorkoutSession(routineName: "B", startedAt: start, completedAt: start.addingTimeInterval(3600), exercises: ex)
    }

    // MARK: - Set window

    func testAProjectAcrossSessionsInsideTheWindowIsOneClimb() {
        let a = climb("Blue crimp"), b = climb("blue crimp "), c = climb("Blue Crimp")
        // 50 → 30 → 10 days ago: every gap is 20 days (< 28), though the whole span is 40.
        let ids = ActivityIdentity(sessions: [session(daysAgo: 50, [a]), session(daysAgo: 30, [b]), session(daysAgo: 10, [c])])
        XCTAssertNotNil(ids.key(for: a))
        XCTAssertEqual(ids.key(for: a), ids.key(for: b))
        XCTAssertEqual(ids.key(for: b), ids.key(for: c))
    }

    func testAGapLongerThanTheResetWindowIsANewClimb() {
        let old = climb("Blue crimp"), new = climb("Blue crimp")
        let s1 = session(daysAgo: 60, [old]), s2 = session(daysAgo: 5, [new])
        let ids = ActivityIdentity(sessions: [s2, s1])                 // order doesn't matter
        XCTAssertNotEqual(ids.key(for: old), ids.key(for: new), "the gym reset it")
        XCTAssertEqual(ids.setStart[ids.key(for: old)!], s1.startedAt)
        XCTAssertEqual(ids.setStart[ids.key(for: new)!], s2.startedAt)
    }

    func testTheResetWindowIsAdjustable() {
        let a = climb("Blue crimp"), b = climb("Blue crimp")
        let sessions = [session(daysAgo: 20, [a]), session(daysAgo: 5, [b])]
        XCTAssertEqual(ActivityIdentity(sessions: sessions).key(for: a), ActivityIdentity(sessions: sessions).key(for: b))
        let tight = ActivityIdentity(sessions: sessions, resetDays: 7)
        XCTAssertNotEqual(tight.key(for: a), tight.key(for: b))
    }

    // MARK: - Base identity

    func testTheSameNameAtAnotherGymIsAnotherClimb() {
        let a = climb("Blue crimp", gym: "Gravity"), b = climb("Blue crimp", gym: "Crux")
        let ids = ActivityIdentity(sessions: [session(daysAgo: 3, [a, b])])
        XCTAssertNotEqual(ids.key(for: a), ids.key(for: b))
    }

    func testAnUnnamedClimbIsIdentifiedByGradeWallAndColour() {
        let a = climb(nil, wall: "Cave", grade: "V4", color: .yellow)
        let b = climb(nil, wall: "cave ", grade: "V4", color: .yellow)
        let c = climb(nil, wall: "Cave", grade: "V4", color: .green)
        let ids = ActivityIdentity(sessions: [session(daysAgo: 9, [a]), session(daysAgo: 2, [b, c])])
        XCTAssertNotNil(ids.key(for: a))
        XCTAssertEqual(ids.key(for: a), ids.key(for: b))
        XCTAssertNotEqual(ids.key(for: a), ids.key(for: c))
    }

    func testABareGradeHasNoIdentity() {
        let bare = climb(nil, gym: nil, grade: "V4")
        XCTAssertNil(ActivityIdentity(sessions: [session(daysAgo: 1, [bare])]).key(for: bare), "not every V4 is one climb")
    }

    // MARK: - Live placement

    func testAClimbAddedLiveJoinsTheCurrentSetOrStartsANewOne() {
        let past = climb("Blue crimp")
        let ids = ActivityIdentity(sessions: [session(daysAgo: 10, [past])])
        let live = climb("Blue crimp")                                  // not in the sessions above
        XCTAssertEqual(ids.key(for: live, loggedAt: now), ids.key(for: past), "10 days later is the same set")
        XCTAssertNotEqual(ids.key(for: live, loggedAt: now.addingTimeInterval(40 * 86_400)), ids.key(for: past))
    }
}
