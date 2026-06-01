import XCTest
import HealthKit
@testable import Snappet

/// Unit tests for the **pure** pieces of the live-workout path (A1) — no device, no
/// HealthKit data, no WCSession. `WorkoutActivityMapping` is a plain enum mapping and
/// the HR-buffer offset math is a static function, so both run in the app test target.
/// (The live relay itself is device-pending — see decisions.md 2026-06-01.)
final class WorkoutActivityMappingTests: XCTestCase {

    // MARK: - Sport tag wins

    func testClimbingSportMapsToClimbing() {
        XCTAssertEqual(
            WorkoutActivityMapping.activityType(sport: .climbing, category: .strength),
            .climbing)
    }

    func testCalisthenicsMapsToFunctionalStrength() {
        XCTAssertEqual(
            WorkoutActivityMapping.activityType(sport: .calisthenics, category: nil),
            .functionalStrengthTraining)
    }

    func testGeneralSportFallsThroughToCategory() {
        XCTAssertEqual(
            WorkoutActivityMapping.activityType(sport: .general, category: .cardio),
            .mixedCardio)
        XCTAssertEqual(
            WorkoutActivityMapping.activityType(sport: .general, category: .strength),
            .traditionalStrengthTraining)
    }

    // MARK: - Category mapping + fallback

    func testCategoryMapping() {
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .strength), .traditionalStrengthTraining)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .powerlifting), .traditionalStrengthTraining)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .cardio), .mixedCardio)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .plyometrics), .jumpRope)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .stretching), .flexibility)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .olympicWeightlifting), .functionalStrengthTraining)
        XCTAssertEqual(WorkoutActivityMapping.activityType(for: .strongman), .functionalStrengthTraining)
    }

    func testNoSportNoCategoryFallsBackToStrengthTraining() {
        XCTAssertEqual(
            WorkoutActivityMapping.activityType(sport: nil, category: nil),
            .traditionalStrengthTraining)
    }

    // MARK: - Dominant category

    func testDominantCategoryPicksMostCommon() {
        let cats: [ExerciseCategory] = [.strength, .strength, .cardio]
        XCTAssertEqual(WorkoutActivityMapping.dominantCategory(of: cats), .strength)
    }

    func testDominantCategoryEmptyIsNil() {
        XCTAssertNil(WorkoutActivityMapping.dominantCategory(of: []))
    }

    func testDominantCategoryTieIsDeterministic() {
        // 1 each → tie broken deterministically by rawValue (independent of input order).
        let a = WorkoutActivityMapping.dominantCategory(of: [.cardio, .strength])
        let b = WorkoutActivityMapping.dominantCategory(of: [.strength, .cardio])
        XCTAssertEqual(a, b)
        // Lock the concrete winner so a future comparator flip is caught (smallest
        // rawValue wins: "cardio" < "strength").
        XCTAssertEqual(a, .cardio)
    }
}

@MainActor
final class LiveWorkoutOffsetTests: XCTestCase {

    func testOffsetUsesWatchClockWhenClose() {
        let start = Date(timeIntervalSince1970: 1_000)
        // Watch says 30s; wall-clock arrival is 31s after start → trust watch's 30.
        let received = start.addingTimeInterval(31)
        let t = AppleWatchMetricsSource.sessionOffset(watchOffset: 30, sessionStart: start, receivedAt: received)
        XCTAssertEqual(t, 30, accuracy: 0.001)
    }

    func testOffsetFallsBackToWallClockWhenWatchClockWildlyAhead() {
        let start = Date(timeIntervalSince1970: 1_000)
        let received = start.addingTimeInterval(10)
        // Watch claims 9999s but only 10s of wall-clock elapsed → use 10.
        let t = AppleWatchMetricsSource.sessionOffset(watchOffset: 9_999, sessionStart: start, receivedAt: received)
        XCTAssertEqual(t, 10, accuracy: 0.001)
    }

    func testOffsetClampsNonNegative() {
        let start = Date(timeIntervalSince1970: 1_000)
        let received = start.addingTimeInterval(-5)   // skew: arrived "before" start
        let t = AppleWatchMetricsSource.sessionOffset(watchOffset: -3, sessionStart: start, receivedAt: received)
        XCTAssertGreaterThanOrEqual(t, 0)
    }

    func testOffsetWithoutSessionStartUsesRawWatchOffset() {
        let t = AppleWatchMetricsSource.sessionOffset(watchOffset: 12, sessionStart: nil, receivedAt: .now)
        XCTAssertEqual(t, 12, accuracy: 0.001)
    }

    func testIngestBuffersSamplesAgainstSessionStart() {
        let service = AppleWatchMetricsSource()
        let start = Date(timeIntervalSince1970: 5_000)
        service.start(activityType: .running, sessionStart: start)
        service.ingest(hrBpm: 120, energyKcal: 8, watchOffset: 5,
                       receivedAt: start.addingTimeInterval(5))
        service.ingest(hrBpm: 145, energyKcal: 20, watchOffset: 10,
                       receivedAt: start.addingTimeInterval(10))
        XCTAssertEqual(service.latestHR, 145)
        XCTAssertEqual(service.energy, 20)
        XCTAssertEqual(service.samples.count, 2)
        XCTAssertEqual(service.samples[0].t, 5, accuracy: 0.001)
        XCTAssertEqual(service.samples[0].bpm, 120)
        XCTAssertEqual(service.samples[1].t, 10, accuracy: 0.001)
    }

    func testStartResetsBuffer() {
        let service = AppleWatchMetricsSource()
        let start = Date()
        service.start(activityType: .running, sessionStart: start)
        service.ingest(hrBpm: 100, energyKcal: 1, watchOffset: 1)
        XCTAssertEqual(service.samples.count, 1)
        service.start(activityType: .climbing, sessionStart: Date())
        XCTAssertTrue(service.samples.isEmpty)
        XCTAssertNil(service.latestHR)
    }

    func testMessageRoundTrips() {
        let m = LiveWorkoutMessage.metrics(hrBpm: 130, energyKcal: 12.5, t: 42)
        XCTAssertEqual(LiveWorkoutMessage(payload: m.payload), m)
        let s = LiveWorkoutMessage.start(activityType: HKWorkoutActivityType.climbing.rawValue)
        XCTAssertEqual(LiveWorkoutMessage(payload: s.payload), s)
        XCTAssertEqual(LiveWorkoutMessage(payload: LiveWorkoutMessage.stop.payload), .stop)
        XCTAssertNil(LiveWorkoutMessage(payload: ["nonsense": 1]))
        // Malformed metrics (missing energyKcal + t) must decode to nil, not phantom 0s.
        XCTAssertNil(LiveWorkoutMessage(payload: ["kind": "metrics", "hrBpm": 100.0]))
    }

    func testPauseResumeMessagesRoundTrip() {
        // The bidirectional pause/resume control must survive the WCSession dictionary round-trip.
        XCTAssertEqual(LiveWorkoutMessage(payload: LiveWorkoutMessage.pause.payload), .pause)
        XCTAssertEqual(LiveWorkoutMessage(payload: LiveWorkoutMessage.resume.payload), .resume)
    }

    func testPauseResumeTogglesSourceState() {
        // Phone-initiated pause/resume flips the source's paused flag (the relay send is a no-op
        // with no activated WCSession, but the local state must still track).
        let service = AppleWatchMetricsSource()
        service.start(activityType: .running, sessionStart: Date())
        XCTAssertFalse(service.isPaused)
        service.pause()
        XCTAssertTrue(service.isPaused)
        service.resume()
        XCTAssertFalse(service.isPaused)
        // Start resets the paused flag.
        service.pause()
        service.start(activityType: .running, sessionStart: Date())
        XCTAssertFalse(service.isPaused)
    }

    func testCoordinatorForwardsPauseToActiveSource() {
        // With no watch/BLE available the coordinator defaults to the Apple-Watch source; pausing
        // the coordinator must flip the watch source (and thus the coordinator's own `isPaused`).
        let coordinator = LiveMetricsCoordinator()
        XCTAssertFalse(coordinator.isPaused)
        coordinator.pause()
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertTrue(coordinator.watch.isPaused)
        coordinator.resume()
        XCTAssertFalse(coordinator.isPaused)
        // Stopping clears any paused state.
        coordinator.pause()
        coordinator.stop()
        XCTAssertFalse(coordinator.isPaused)
    }
}
