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

    // MARK: - Redline (Z4+Z5) + Edwards TRIMP

    /// @190: 160 = threshold (Z4), 175 = max (Z5), 100 = recovery (Z1).
    func testRedlineSumsThresholdAndMaxOnly() throws {
        let series = [HRPoint(t: 0, bpm: 160), HRPoint(t: 10, bpm: 175),
                      HRPoint(t: 40, bpm: 100), HRPoint(t: 50, bpm: 120)]
        let stats = try XCTUnwrap(WorkoutHRStats.make(from: series))
        XCTAssertEqual(stats.totalSeconds, 50)
        XCTAssertEqual(stats.redlineSeconds, 40)               // 10 threshold + 30 max
        XCTAssertEqual(stats.redlineFraction, 0.8, accuracy: 0.0001)
        // (10/60)·4 + (30/60)·5 + (10/60)·1 = 0.6667 + 2.5 + 0.1667 = 3.3333
        XCTAssertEqual(stats.edwardsTRIMP, 3.3333, accuracy: 0.001)
    }

    func testRedlineZeroWhenNeverHard() throws {
        let series = [HRPoint(t: 0, bpm: 120), HRPoint(t: 10, bpm: 140), HRPoint(t: 20, bpm: 120)]
        let stats = try XCTUnwrap(WorkoutHRStats.make(from: series))   // easy/aerobic only
        XCTAssertEqual(stats.redlineSeconds, 0)
        XCTAssertEqual(stats.redlineFraction, 0)
    }

    func testRedlineFractionZeroNotNaNOnSingleSample() throws {
        let stats = try XCTUnwrap(WorkoutHRStats.make(from: [HRPoint(t: 0, bpm: 175)]))
        XCTAssertEqual(stats.totalSeconds, 0)
        XCTAssertEqual(stats.redlineSeconds, 0)
        XCTAssertEqual(stats.redlineFraction, 0)               // guarded → no divide-by-zero
        XCTAssertFalse(stats.redlineFraction.isNaN)
        XCTAssertEqual(stats.edwardsTRIMP, 0)
    }

    func testEdwardsTRIMPWeightsByZoneNumber() throws {
        // 10 s in Z1 (recovery, weight 1) vs 10 s in Z4 (threshold, weight 4) → ratio 1:4.
        let z1 = try XCTUnwrap(WorkoutHRStats.make(from: [HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 100)]))
        let z4 = try XCTUnwrap(WorkoutHRStats.make(from: [HRPoint(t: 0, bpm: 160), HRPoint(t: 10, bpm: 160)]))
        XCTAssertEqual(z1.edwardsTRIMP, (10.0 / 60) * 1, accuracy: 0.0001)
        XCTAssertEqual(z4.edwardsTRIMP, (10.0 / 60) * 4, accuracy: 0.0001)
    }

    func testRedlineRespectsCustomMaxHR() throws {
        // 140 bpm: @190 it's aerobic (not redline); @160 it's 87.5% → threshold (redline).
        let series = [HRPoint(t: 0, bpm: 140), HRPoint(t: 10, bpm: 140)]
        XCTAssertEqual(try XCTUnwrap(WorkoutHRStats.make(from: series)).redlineSeconds, 0)
        XCTAssertEqual(try XCTUnwrap(WorkoutHRStats.make(from: series, maxHR: 160)).redlineSeconds, 10)
    }

    func testEdwardsTRIMPOrderIndependent() throws {
        let ordered = [HRPoint(t: 0, bpm: 160), HRPoint(t: 10, bpm: 175),
                       HRPoint(t: 40, bpm: 100), HRPoint(t: 50, bpm: 120)]
        let shuffled = [HRPoint(t: 50, bpm: 120), HRPoint(t: 10, bpm: 175),
                        HRPoint(t: 0, bpm: 160), HRPoint(t: 40, bpm: 100)]
        XCTAssertEqual(try XCTUnwrap(WorkoutHRStats.make(from: ordered)).edwardsTRIMP,
                       try XCTUnwrap(WorkoutHRStats.make(from: shuffled)).edwardsTRIMP, accuracy: 0.0001)
    }

    // MARK: - Per-set effort (all SetKinds; smoothing disabled for exact assertions)

    private let s0 = Date(timeIntervalSince1970: 1_000)
    private let fastCfg = HighlightConfig(smoothingWindowSec: 1, hrLagSec: 6)

    private func setLog(at completedAt: Date?, durationSec: Double? = nil) -> SetLog {
        SetLog(actualReps: nil, actualWeight: nil, weightUnit: nil, completedAt: completedAt,
               durationSec: durationSec, climbGradeLabel: nil, climbStatusRaw: nil, climbAttempts: nil)
    }

    private func exercise(_ kind: SetKind, _ sets: [SetLog], id: UUID = UUID()) -> SessionExercise {
        SessionExercise(id: id, exerciseId: "ex", targetSets: sets.count, targetReps: "",
                        targetRestSeconds: 0, targetWeight: nil, targetWeightUnit: nil,
                        sets: sets, skipped: false, displayName: nil, kindRaw: kind.rawValue)
    }

    private func hr(_ pairs: [(Double, Double)]) -> [HRSample] { pairs.map { HRSample(t: $0.0, bpm: $0.1) } }

    /// A timed-hold set's window is `[completedAt − durationSec, completedAt + lag]` — a spike before
    /// the window start is excluded.
    func testDurationSetUsesDurationWindow() throws {
        let exID = UUID()
        let ex = exercise(.duration, [setLog(at: s0.addingTimeInterval(60), durationSec: 40)], id: exID)
        // 200 spike at t=10 (before window start 20) must be excluded; the in-window peak is 180@t30.
        let samples = hr([(0, 120), (10, 200), (15, 120), (30, 180), (60, 120), (120, 120)])
        let efforts = WorkoutHRStats.setEfforts(for: [ex], sessionStart: s0, hr: samples, config: fastCfg)
        let e = try XCTUnwrap(efforts[.init(exerciseID: exID, setIndex: 0)])
        XCTAssertEqual(e.peakBpm, 180)        // not 200 — the pre-window spike is outside [20,66]
    }

    /// A reps&weight set with no prior set falls back to the capped lookback (here it reaches t=20).
    func testRepsWeightFirstSetUsesMaxLookback() throws {
        let exID = UUID()
        let ex = exercise(.repsWeight, [setLog(at: s0.addingTimeInterval(40))], id: exID)
        let samples = hr([(0, 120), (20, 180), (40, 120), (120, 120)])
        let efforts = WorkoutHRStats.setEfforts(for: [ex], sessionStart: s0, hr: samples, config: fastCfg)
        XCTAssertEqual(try XCTUnwrap(efforts[.init(exerciseID: exID, setIndex: 0)]).peakBpm, 180)
    }

    /// A later set's window starts at the PREVIOUS chronological set's completion, so a spike before
    /// that earlier set is excluded from the later set (but captured by the earlier one).
    func testLaterSetLookbackBoundedByPreviousSet() throws {
        let exID = UUID()
        let ex = exercise(.repsWeight,
                          [setLog(at: s0.addingTimeInterval(30)), setLog(at: s0.addingTimeInterval(90))], id: exID)
        let samples = hr([(0, 120), (10, 200), (15, 120), (60, 180), (65, 120), (90, 120), (150, 120)])
        let efforts = WorkoutHRStats.setEfforts(for: [ex], sessionStart: s0, hr: samples, config: fastCfg)
        // Set 0 (window [0,36]) sees the t=10 spike…
        XCTAssertEqual(try XCTUnwrap(efforts[.init(exerciseID: exID, setIndex: 0)]).peakBpm, 200)
        // …set 1 (window [30,96], starting at set 0's completion) does NOT — its peak is the t=60 spike.
        XCTAssertEqual(try XCTUnwrap(efforts[.init(exerciseID: exID, setIndex: 1)]).peakBpm, 180)
    }

    func testNoHRYieldsEmptyMap() {
        let ex = exercise(.repsWeight, [setLog(at: s0.addingTimeInterval(30))])
        XCTAssertTrue(WorkoutHRStats.setEfforts(for: [ex], sessionStart: s0, hr: []).isEmpty)
    }

    func testIncompleteSetIsNotScored() {
        let exID = UUID()
        let ex = exercise(.repsWeight, [setLog(at: nil)], id: exID)   // never completed
        let samples = hr([(0, 120), (20, 180), (40, 120)])
        let efforts = WorkoutHRStats.setEfforts(for: [ex], sessionStart: s0, hr: samples, config: fastCfg)
        XCTAssertNil(efforts[.init(exerciseID: exID, setIndex: 0)])
        XCTAssertTrue(efforts.isEmpty)
    }

    func testPeakHRRNilWithoutBoundsPresentWithThem() throws {
        let exID = UUID()
        let ex = exercise(.repsWeight, [setLog(at: s0.addingTimeInterval(40))], id: exID)
        let samples = hr([(0, 120), (20, 180), (40, 120), (120, 120)])
        let bpmOnly = WorkoutHRStats.setEfforts(for: [ex], sessionStart: s0, hr: samples, config: fastCfg)
        XCTAssertEqual(try XCTUnwrap(bpmOnly[.init(exerciseID: exID, setIndex: 0)]).peakBpm, 180)
        XCTAssertNil(try XCTUnwrap(bpmOnly[.init(exerciseID: exID, setIndex: 0)]).peakHRR)
        let withBounds = WorkoutHRStats.setEfforts(for: [ex], sessionStart: s0, hr: samples,
                                                   maxHR: 200, restHR: 60, config: fastCfg)
        // %HRR = (180 − 60) / (200 − 60) = 0.857
        let bounded = try XCTUnwrap(withBounds[.init(exerciseID: exID, setIndex: 0)])
        XCTAssertEqual(try XCTUnwrap(bounded.peakHRR), 120.0 / 140.0, accuracy: 0.001)
    }
}
