import XCTest
@testable import Snappet
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Unit tests for the **pure** pieces of the A2 Live Activity / overall-timer path — no device,
/// no ActivityKit runtime. `WorkoutLiveSnapshot` is platform-free, so the elapsed-time
/// formatting and the snapshot → `ContentState` field mapping run in the app test target.
/// (The Live Activity *rendering* itself is device-pending — see decisions.md 2026-06-01.)
final class WorkoutLiveSnapshotTests: XCTestCase {

    // MARK: - Elapsed-time formatting (the overall timer string)

    func testElapsedUnderAMinute() {
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(0), "0:00")
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(5), "0:05")
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(59), "0:59")
    }

    func testElapsedMinutesSeconds() {
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(60), "1:00")
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(125), "2:05")
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(599), "9:59")
    }

    func testElapsedRollsOverToHours() {
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(3600), "1:00:00")
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(3661), "1:01:01")
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(7325), "2:02:05")
    }

    func testElapsedClampsNegativeToZero() {
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(-10), "0:00")
    }

    func testElapsedTruncatesFractionalSeconds() {
        // 90.9s is still in the 90th second → 1:30, not 1:31.
        XCTAssertEqual(WorkoutLiveSnapshot.elapsedString(90.9), "1:30")
    }

    // MARK: - Snapshot shape

    func testSnapshotCarriesFieldsThrough() {
        let start = Date(timeIntervalSince1970: 10_000)
        let snap = WorkoutLiveSnapshot(startedAt: start, hrBpm: 142,
                                       exerciseName: "Back Squat", setProgress: "Set 2 of 4")
        XCTAssertEqual(snap.startedAt, start)
        XCTAssertEqual(snap.hrBpm, 142)
        XCTAssertEqual(snap.exerciseName, "Back Squat")
        XCTAssertEqual(snap.setProgress, "Set 2 of 4")
    }

    func testSnapshotAllowsNilHR() {
        let snap = WorkoutLiveSnapshot(startedAt: .now, hrBpm: nil,
                                       exerciseName: "Warming up", setProgress: "")
        XCTAssertNil(snap.hrBpm)
    }

    // MARK: - Update throttle (shouldPush) — keeps ActivityKit within its update budget

    private func snap(_ name: String, _ progress: String, hr: Int?) -> WorkoutLiveSnapshot {
        WorkoutLiveSnapshot(startedAt: Date(timeIntervalSince1970: 0), hrBpm: hr,
                            exerciseName: name, setProgress: progress)
    }

    func testFirstPushAlwaysGoes() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(WorkoutLiveSnapshot.shouldPush(
            snap("Squat", "Set 1 of 3", hr: nil), after: nil, lastPushedAt: nil, now: now))
    }

    func testIdenticalSnapshotDoesNotPush() {
        let now = Date(timeIntervalSince1970: 100)
        let s = snap("Squat", "Set 1 of 3", hr: 120)
        XCTAssertFalse(WorkoutLiveSnapshot.shouldPush(
            s, after: s, lastPushedAt: now.addingTimeInterval(-0.1), now: now))
    }

    func testStructuralChangePushesImmediatelyEvenWithinHRWindow() {
        let now = Date(timeIntervalSince1970: 100)
        let last = snap("Squat", "Set 1 of 3", hr: 120)
        let next = snap("Squat", "Set 2 of 3", hr: 120)   // set advanced
        XCTAssertTrue(WorkoutLiveSnapshot.shouldPush(
            next, after: last, lastPushedAt: now.addingTimeInterval(-0.1), now: now))
    }

    func testHROnlyChangeRateLimited() {
        let now = Date(timeIntervalSince1970: 100)
        let last = snap("Squat", "Set 1 of 3", hr: 120)
        let next = snap("Squat", "Set 1 of 3", hr: 121)   // HR only
        // Too soon → suppressed.
        XCTAssertFalse(WorkoutLiveSnapshot.shouldPush(
            next, after: last, lastPushedAt: now.addingTimeInterval(-1), now: now))
        // Past the interval → allowed.
        XCTAssertTrue(WorkoutLiveSnapshot.shouldPush(
            next, after: last, lastPushedAt: now.addingTimeInterval(-3), now: now))
    }

    func testPauseStateChangePushesImmediately() {
        // A pause/resume must reach the Live Activity at once (it's structural), even inside the
        // HR rate-limit window, so the Lock Screen "Paused" badge isn't delayed.
        let now = Date(timeIntervalSince1970: 100)
        var last = snap("Squat", "Set 1 of 3", hr: 120)
        var next = last
        next.paused = true
        XCTAssertTrue(WorkoutLiveSnapshot.shouldPush(
            next, after: last, lastPushedAt: now.addingTimeInterval(-0.1), now: now))
        // And resuming likewise.
        last.paused = true
        next.paused = false
        XCTAssertTrue(WorkoutLiveSnapshot.shouldPush(
            next, after: last, lastPushedAt: now.addingTimeInterval(-0.1), now: now))
    }

    #if canImport(ActivityKit)
    // MARK: - ContentState mapping (the producer/renderer contract)

    /// The Live Activity `ContentState` mirrors the snapshot's fields one-to-one, so a missing
    /// HR renders as "—" and the overall timer anchors on `startedAt`. This guards the shape the
    /// widget extension renders against drifting from what the app pushes.
    func testContentStateMirrorsSnapshotFields() {
        let start = Date(timeIntervalSince1970: 20_000)
        let snap = WorkoutLiveSnapshot(startedAt: start, hrBpm: 130,
                                       exerciseName: "Deadlift", setProgress: "Set 1 of 5")
        let state = WorkoutActivityAttributes.ContentState(
            startedAt: snap.startedAt, hrBpm: snap.hrBpm,
            exerciseName: snap.exerciseName, setProgress: snap.setProgress)
        XCTAssertEqual(state.startedAt, start)
        XCTAssertEqual(state.hrBpm, 130)
        XCTAssertEqual(state.exerciseName, "Deadlift")
        XCTAssertEqual(state.setProgress, "Set 1 of 5")
    }

    func testContentStateCodableRoundTrips() throws {
        let state = WorkoutActivityAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: 1_234),
            hrBpm: nil, exerciseName: "Resting", setProgress: "Next: Bench", paused: true)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.paused)
    }

    func testContentStatePausedCarriesThrough() {
        let snap = WorkoutLiveSnapshot(startedAt: .now, hrBpm: 120,
                                       exerciseName: "Bench", setProgress: "Set 1 of 3", paused: true)
        let state = WorkoutActivityAttributes.ContentState(
            startedAt: snap.startedAt, hrBpm: snap.hrBpm,
            exerciseName: snap.exerciseName, setProgress: snap.setProgress, paused: snap.paused)
        XCTAssertTrue(state.paused)
    }
    #endif
}
