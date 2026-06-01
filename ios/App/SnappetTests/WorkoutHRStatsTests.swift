import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the **pure** B2 HR-stats helper — no device, no simulator, no SwiftUI.
/// Exercises avg/max/min over a synthetic series, time-in-zone dwell bucketing, the empty +
/// single-sample edge cases, and the `HRSample → HRPoint` flush mapping. The chart's *visual*
/// + a real live-HR series are device-pending (the sim finishes with an empty `hrSeries`);
/// these prove the math's shape with synthetic data (decisions.md 2026-06-01, B2).
final class WorkoutHRStatsTests: XCTestCase {

    // MARK: - Empty / single-sample edge cases

    func testEmptySeriesYieldsNoStats() {
        XCTAssertNil(WorkoutHRStats.make(from: []))
    }

    func testSingleSampleHasNoDwellButReportsBpm() {
        let stats = WorkoutHRStats.make(from: [HRPoint(t: 0, bpm: 130)])
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.avgBpm, 130)
        XCTAssertEqual(stats?.maxBpm, 130)
        XCTAssertEqual(stats?.minBpm, 130)
        // One point has no following interval → zero dwell time attributed.
        XCTAssertEqual(stats?.totalSeconds, 0)
    }

    // MARK: - avg / max / min

    func testAvgMaxMinOverSyntheticSeries() throws {
        let series = [
            HRPoint(t: 0, bpm: 100),
            HRPoint(t: 10, bpm: 140),
            HRPoint(t: 20, bpm: 120),
            HRPoint(t: 30, bpm: 160),
        ]
        let stats = try XCTUnwrap(WorkoutHRStats.make(from: series))
        XCTAssertEqual(stats.avgBpm, 130, accuracy: 0.0001)  // (100+140+120+160)/4
        XCTAssertEqual(stats.maxBpm, 160)
        XCTAssertEqual(stats.minBpm, 100)
    }

    func testStatsIndependentOfInputOrder() {
        let ordered = [HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 150), HRPoint(t: 20, bpm: 120)]
        let shuffled = [HRPoint(t: 20, bpm: 120), HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 150)]
        XCTAssertEqual(WorkoutHRStats.make(from: ordered), WorkoutHRStats.make(from: shuffled))
    }

    // MARK: - Time-in-zone bucketing

    func testTimeInZoneBucketingByLeftEdge() {
        // maxHR 190 (default): 100→recovery (<114), 140→aerobic (133–151), 175→max (≥171).
        // Each sample owns the interval until the next; the last sample contributes nothing.
        let series = [
            HRPoint(t: 0, bpm: 100),    // recovery for 10 s
            HRPoint(t: 10, bpm: 140),   // aerobic for 20 s
            HRPoint(t: 30, bpm: 175),   // max — last, no interval
        ]
        let stats = WorkoutHRStats.make(from: series)
        XCTAssertEqual(stats?.secondsByZone[.recovery], 10)
        XCTAssertEqual(stats?.secondsByZone[.aerobic], 20)
        XCTAssertNil(stats?.secondsByZone[.max])             // last sample owns no interval
        XCTAssertEqual(stats?.totalSeconds, 30)              // sums to the span before the last point
    }

    func testTimeInZoneRespectsCustomMaxHR() {
        // With maxHR 160, 140 bpm is 87.5% → threshold (not aerobic as it'd be at 190).
        let series = [HRPoint(t: 0, bpm: 140), HRPoint(t: 10, bpm: 145)]
        let stats = WorkoutHRStats.make(from: series, maxHR: 160)
        XCTAssertEqual(stats?.secondsByZone[.threshold], 10)
        XCTAssertNil(stats?.secondsByZone[.aerobic])
    }

    func testOrderedZoneSecondsListsAllRealZonesLowToHigh() {
        let series = [HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 175)]
        let stats = WorkoutHRStats.make(from: series)
        let ordered = stats?.orderedZoneSeconds ?? []
        // All 5 real zones present (0 for unused), low→high, never .none.
        XCTAssertEqual(ordered.map(\.zone), [.recovery, .easy, .aerobic, .threshold, .max])
        XCTAssertEqual(ordered.first(where: { $0.zone == .recovery })?.seconds, 10)
        XCTAssertEqual(ordered.first(where: { $0.zone == .easy })?.seconds, 0)
    }

    // MARK: - HRSample → HRPoint flush mapping

    func testSampleToPointMappingIsFieldForField() {
        let samples = [HRSample(t: 0, bpm: 90), HRSample(t: 5.5, bpm: 132)]
        let points = WorkoutHRStats.points(from: samples)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].t, 0); XCTAssertEqual(points[0].bpm, 90)
        XCTAssertEqual(points[1].t, 5.5); XCTAssertEqual(points[1].bpm, 132)
    }

    func testEmptySampleBufferMapsToEmptySeries() {
        XCTAssertTrue(WorkoutHRStats.points(from: []).isEmpty)
    }

    func testRoundTripSamplesThroughPointsToStats() throws {
        let samples = [HRSample(t: 0, bpm: 100), HRSample(t: 10, bpm: 140), HRSample(t: 20, bpm: 120)]
        let stats = try XCTUnwrap(WorkoutHRStats.make(from: WorkoutHRStats.points(from: samples)))
        XCTAssertEqual(stats.avgBpm, 120, accuracy: 0.0001)
        XCTAssertEqual(stats.maxBpm, 140)
        XCTAssertEqual(stats.minBpm, 100)
    }
}
