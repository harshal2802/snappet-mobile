import XCTest
@testable import Snappet

/// Unit tests for the **pure** Apple Watch → Clips reconciliation (watch-workouts-clips, PR1). No device,
/// no HealthKit, no Photos, no SwiftData — synthetic workouts + candidates → asserts which anchors mint,
/// which get late media attached, and which are suppressed (media-only, idempotency, gym overlap).
final class WatchWorkoutReconcilerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func workout(_ uuid: UUID = UUID(), name: String = "Run",
                         startOffset: Double, minutes: Double) -> WatchWorkoutReconciler.WorkoutInfo {
        WatchWorkoutReconciler.WorkoutInfo(
            workoutUUID: uuid, displayName: name,
            start: t0.addingTimeInterval(startOffset),
            end: t0.addingTimeInterval(startOffset + minutes * 60),
            energyKcal: 300, distanceMeters: 5000)
    }

    private func candidate(_ id: String, offset: Double = 10) -> SessionMediaService.Candidate {
        SessionMediaService.Candidate(localIdentifier: id, kind: .video, offsetSec: offset, durationSec: 6)
    }

    // MARK: FR2 — media-only

    func testWorkoutWithNoMediaMintsNothing() {
        let wk = workout(startOffset: 0, minutes: 30)
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [:], gymSessionIntervals: [])
        XCTAssertTrue(actions.isEmpty)
    }

    func testWorkoutWithMediaMintsAnchor() {
        let wk = workout(startOffset: 0, minutes: 30)
        let cands = [candidate("a"), candidate("b")]
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: cands], gymSessionIntervals: [])
        XCTAssertEqual(actions, [.mint(wk, candidates: cands)])
    }

    // MARK: FR3 — idempotency

    func testAlreadyAnchoredWithNoNewMediaDoesNothing() {
        let wk = workout(startOffset: 0, minutes: 30)
        let sessionID = UUID()
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk],
            anchoredSessionByUUID: [wk.workoutUUID: sessionID],
            existingMediaBySession: [sessionID: ["a"]],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],   // already stored
            gymSessionIntervals: [])
        XCTAssertTrue(actions.isEmpty, "no re-mint, no re-attach of stored media")
    }

    // MARK: FR4 — late-syncing media attaches to the existing anchor

    func testLateMediaAttachesOnlyFreshAssets() {
        let wk = workout(startOffset: 0, minutes: 30)
        let sessionID = UUID()
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk],
            anchoredSessionByUUID: [wk.workoutUUID: sessionID],
            existingMediaBySession: [sessionID: ["a"]],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a"), candidate("b")]],
            gymSessionIntervals: [])
        XCTAssertEqual(actions, [.attach(sessionID: sessionID, newCandidates: [candidate("b")])])
    }

    // MARK: FR10 — gym overlap suppression (and climbing coexistence)

    func testWorkoutOverlappingGymSessionIsSuppressed() {
        let wk = workout(startOffset: 0, minutes: 30)   // midpoint = t0 + 15 min
        let gym = DateInterval(start: t0, end: t0.addingTimeInterval(60 * 60))  // covers the midpoint
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],
            gymSessionIntervals: [gym])
        XCTAssertTrue(actions.isEmpty, "an in-app gym session owns that time window")
    }

    func testNonOverlappingWorkoutStillMintsAlongsideGym() {
        let wk = workout(startOffset: 3 * 60 * 60, minutes: 30)   // 3h later, no overlap
        let gym = DateInterval(start: t0, end: t0.addingTimeInterval(60 * 60))
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],
            gymSessionIntervals: [gym])
        XCTAssertEqual(actions.count, 1)
    }

    /// Decision Q2: Kilter is NOT a gym-overlap source, so a watch **Climbing** workout coinciding with a
    /// board session still mints — the caller only ever passes gym intervals here.
    func testClimbingCoexistsWhenNoGymIntervalsPassed() {
        let wk = workout(name: "Climbing", startOffset: 0, minutes: 45)
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],
            gymSessionIntervals: [])   // Kilter intervals are deliberately not supplied
        XCTAssertEqual(actions.count, 1)
    }

    func testGymOverlapUsesPadTolerance() {
        // Workout midpoint sits 60s AFTER a gym session's end — inside the ±90s pad ⇒ suppressed.
        let gymEnd = t0.addingTimeInterval(20 * 60)
        let wk = workout(startOffset: 20 * 60 + 60 - 15, minutes: 0.5)  // midpoint ≈ gymEnd + 60s
        let gym = DateInterval(start: t0, end: gymEnd)
        XCTAssertTrue(WatchWorkoutReconciler.overlapsGymSession(wk, [gym]))
    }

    // MARK: ordering — oldest first (chronological back-fill)

    func testMintsAreOldestFirst() {
        let older = workout(name: "A", startOffset: 0, minutes: 20)
        let newer = workout(name: "B", startOffset: 5 * 60 * 60, minutes: 20)
        let actions = WatchWorkoutReconciler.plan(
            workouts: [newer, older],   // supplied newest-first
            anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [older.workoutUUID: [candidate("a")],
                                  newer.workoutUUID: [candidate("b")]],
            gymSessionIntervals: [])
        guard case let .mint(first, _) = actions.first else { return XCTFail("expected mints") }
        XCTAssertEqual(first.displayName, "A", "older workout mints first")
    }
}
