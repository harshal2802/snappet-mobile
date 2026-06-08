import XCTest
import HighlightEngine
@testable import Snappet

/// Phase 3 (RR-intervals → on-device HRV) tests: the RR byte decode, the chest-strap trust gate, and
/// the per-rest HRV windowing in both apps' pure stats helpers. The live RR capture off a real strap
/// and the `0x180A` model read are device-pending; this is the math + gating that drives them.
final class RRDecodeTests: XCTestCase {

    func testParsesRRIntervals() {
        // flags 0x10 = RR present, UInt8 bpm. RR values 0x0400 (1024 → 1000 ms) and 0x0200 (512 → 500 ms).
        let m = BLEHeartRateMetricsSource.parseMeasurement(Data([0x10, 70, 0x00, 0x04, 0x00, 0x02]))
        let rr = try! XCTUnwrap(m?.rrIntervalsMs)
        XCTAssertEqual(rr.count, 2)
        XCTAssertEqual(rr[0], 1000, accuracy: 0.001)
        XCTAssertEqual(rr[1], 500, accuracy: 0.001)
        XCTAssertEqual(m?.bpm, 70)
    }

    func testSkipsEnergyFieldBeforeRR() {
        // flags 0x18 = energy (bit 3) + RR (bit 4). UInt8 bpm 80, 2-byte energy (skipped), then RR 1024.
        let m = BLEHeartRateMetricsSource.parseMeasurement(Data([0x18, 80, 0xFF, 0x00, 0x00, 0x04]))
        let rr = try! XCTUnwrap(m?.rrIntervalsMs)
        XCTAssertEqual(rr.count, 1)
        XCTAssertEqual(rr[0], 1000, accuracy: 0.001)
    }

    func testNoRRFlagMeansNil() {
        XCTAssertNil(BLEHeartRateMetricsSource.parseMeasurement(Data([0x00, 72]))?.rrIntervalsMs)
    }

    func testTruncatedRRTailTakesWholeIntervalsOnly() {
        // flags 0x10, bpm, then 3 RR bytes — only one whole UInt16 fits; the dangling byte is ignored.
        let m = BLEHeartRateMetricsSource.parseMeasurement(Data([0x10, 70, 0x00, 0x04, 0x55]))
        XCTAssertEqual(try! XCTUnwrap(m?.rrIntervalsMs).count, 1)
    }
}

final class RRTrustTests: XCTestCase {

    func testTrustsChestStraps() {
        XCTAssertTrue(BLEHeartRateMetricsSource.rrTrusted(modelNumber: nil, deviceName: "Polar H10"))
        XCTAssertTrue(BLEHeartRateMetricsSource.rrTrusted(modelNumber: "HRM-Pro", deviceName: nil))
        XCTAssertTrue(BLEHeartRateMetricsSource.rrTrusted(modelNumber: nil, deviceName: "Wahoo TICKR"))
    }

    func testRejectsOpticalAndUnknown() {
        XCTAssertFalse(BLEHeartRateMetricsSource.rrTrusted(modelNumber: nil, deviceName: "Polar Verity Sense"))
        XCTAssertFalse(BLEHeartRateMetricsSource.rrTrusted(modelNumber: nil, deviceName: "Scosche Rhythm24"))
        XCTAssertFalse(BLEHeartRateMetricsSource.rrTrusted(modelNumber: nil, deviceName: "Some Random Band"))
        XCTAssertFalse(BLEHeartRateMetricsSource.rrTrusted(modelNumber: nil, deviceName: nil))   // default-deny
    }

    func testTickrFitOpticalRejectedBeforeTickrMatch() {
        // The optical blacklist must win: "TICKR FIT" (optical armband) is NOT trusted, unlike "TICKR".
        XCTAssertFalse(BLEHeartRateMetricsSource.rrTrusted(modelNumber: nil, deviceName: "Wahoo TICKR FIT"))
    }

    @MainActor
    func testIngestDropsRRWhenUntrusted() {
        let src = BLEHeartRateMetricsSource()
        // Default-deny: RR is dropped until the source is told the band is trusted.
        src.ingest(bpm: 120, contact: true, rrIntervalsMs: [800, 810])
        XCTAssertNil(src.samples.last?.rrIntervalsMs)
        // Once trusted (a chest strap connected), RR is kept.
        src.setRRTrusted(true)
        src.ingest(bpm: 122, contact: true, rrIntervalsMs: [805, 815])
        XCTAssertEqual(src.samples.last?.rrIntervalsMs, [805, 815])
    }
}

/// Per-rest HRV windowing in both apps' pure stats helpers.
final class RestHRVStatsTests: XCTestCase {

    private let s0 = Date(timeIntervalSince1970: 1_000)
    private let rrBurst = [800.0, 810, 820, 805, 815]   // 5 plausible intervals → HRVMetrics is non-empty

    private func setLog(at completedAt: Date?) -> SetLog {
        SetLog(actualReps: nil, actualWeight: nil, weightUnit: nil, completedAt: completedAt,
               durationSec: nil, climbGradeLabel: nil, climbStatusRaw: nil, climbAttempts: nil)
    }

    func testWorkoutSetRestHRVOverGapBeforeSet() throws {
        let exID = UUID()
        let ex = SessionExercise(id: exID, exerciseId: "ex", targetSets: 2, targetReps: "",
                                 targetRestSeconds: 0, targetWeight: nil, targetWeightUnit: nil,
                                 sets: [setLog(at: s0.addingTimeInterval(30)), setLog(at: s0.addingTimeInterval(90))],
                                 skipped: false, displayName: nil, kindRaw: SetKind.repsWeight.rawValue)
        // RR captured during the rest gap [30, 90] before set 1.
        let hr = [HRSample(t: 50, bpm: 110, rrIntervalsMs: rrBurst)]
        let map = WorkoutHRStats.setRestHRV(for: [ex], sessionStart: s0, hr: hr)
        XCTAssertNil(map[.init(exerciseID: exID, setIndex: 0)])              // first set: no rest before it
        XCTAssertNotNil(try XCTUnwrap(map[.init(exerciseID: exID, setIndex: 1)]).rmssd)
    }

    func testWorkoutSetRestHRVEmptyWithoutRR() {
        let exID = UUID()
        let ex = SessionExercise(id: exID, exerciseId: "ex", targetSets: 2, targetReps: "",
                                 targetRestSeconds: 0, targetWeight: nil, targetWeightUnit: nil,
                                 sets: [setLog(at: s0.addingTimeInterval(30)), setLog(at: s0.addingTimeInterval(90))],
                                 skipped: false, displayName: nil, kindRaw: SetKind.repsWeight.rawValue)
        let hr = [HRSample(t: 50, bpm: 110)]   // no RR (untrusted band / watch)
        let map = WorkoutHRStats.setRestHRV(for: [ex], sessionStart: s0, hr: hr)
        XCTAssertNil(map[.init(exerciseID: exID, setIndex: 1)]?.rmssd ?? nil)
    }

    func testKilterClimbRestHRVOverGap() throws {
        // Two climbs: A ends at t=60, B starts at t=120 → rest gap [60,120]; RR captured there.
        let a = KilterClimbLog(climbUUID: "a", climbName: "A", gradeLabel: "V3", difficulty: 3,
                               status: .sent, attempts: 1,
                               startedAt: s0, endedAt: s0.addingTimeInterval(60), loggedAt: s0.addingTimeInterval(60))
        let b = KilterClimbLog(climbUUID: "b", climbName: "B", gradeLabel: "V4", difficulty: 4,
                               status: .sent, attempts: 1,
                               startedAt: s0.addingTimeInterval(120), endedAt: s0.addingTimeInterval(180),
                               loggedAt: s0.addingTimeInterval(180))
        let hr = [HRSample(t: 90, bpm: 105, rrIntervalsMs: rrBurst)]   // in the [60,120] rest before B
        let stats = KilterSessionStats.make(from: [a, b], start: s0, end: s0.addingTimeInterval(180), hrSeries: hr)
        XCTAssertEqual(stats.timeline[0].restHRV, .empty)               // first climb: no rest before it
        XCTAssertNotNil(stats.timeline[1].restHRV.rmssd)                // HRV over the rest before climb B
    }
}
