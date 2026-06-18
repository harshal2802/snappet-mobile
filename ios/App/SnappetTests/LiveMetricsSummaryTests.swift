import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the **pure** `LiveMetricsSummary` aggregation (issue #158, workstream E) — current
/// bpm + zone, running avg/max/redline over the live buffer, and recovery toward rest. No device, no
/// `MetricsSource`; the transport that fills the buffer is the device-only edge, not this math.
final class LiveMetricsSummaryTests: XCTestCase {

    func testEmptyBufferAndNoReadingHidesEverything() {
        let m = LiveMetricsSummary.make(from: [], currentBpm: nil, maxHR: nil, restHR: nil)
        XCTAssertNil(m.stats)
        XCTAssertNil(m.currentBpm)
        XCTAssertNil(m.avgBpm)
        XCTAssertNil(m.maxBpm)
        XCTAssertEqual(m.zone, .none)
        XCTAssertEqual(m.recovery, .unknown)
        XCTAssertEqual(m.redlineFraction, 0)
        XCTAssertFalse(m.hasData)
    }

    func testCurrentBpmDrivesZoneAndRecovery() {
        // 150 bpm, max 200, rest 50 → %HRR = 100/150 = 0.667 (> 0.40 ⇒ recovering); fraction = 0.333.
        let m = LiveMetricsSummary.make(from: [], currentBpm: 150, maxHR: 200, restHR: 50)
        XCTAssertEqual(m.currentBpm, 150)
        XCTAssertEqual(m.zone, HeartRateZone.forBpm(150, maxHR: 200))   // 0.75 → aerobic
        XCTAssertEqual(m.zone, .aerobic)
        XCTAssertEqual(m.recovery.state, .recovering)
        XCTAssertEqual(m.recovery.fraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(m.recoveryFraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertTrue(m.hasData)
    }

    func testRecoveryUnknownWithoutProfileBounds() {
        // No max/rest bounds → readiness can't be evaluated, so the nudge hides (like every call site).
        let m = LiveMetricsSummary.make(from: [], currentBpm: 150, maxHR: nil, restHR: nil)
        XCTAssertEqual(m.recovery, .unknown)
        XCTAssertEqual(m.zone, HeartRateZone.forBpm(150))   // default max 190 → still colored
    }

    func testStatsComputedOverBuffer() {
        let samples = [HRSample(t: 0, bpm: 100), HRSample(t: 10, bpm: 120), HRSample(t: 20, bpm: 100)]
        let m = LiveMetricsSummary.make(from: samples, currentBpm: 120, maxHR: nil, restHR: nil)
        XCTAssertNotNil(m.stats)
        XCTAssertEqual(m.avgBpm, 107)   // (100 + 120 + 100)/3 = 106.67 → 107
        XCTAssertEqual(m.maxBpm, 120)
        XCTAssertTrue(m.hasData)
        // Those bpms are all sub-threshold at the default max → no redline yet.
        XCTAssertEqual(m.redlineFraction, 0)
    }

    func testNonPositiveReadingIsTreatedAsNoReading() {
        // A transient 0 / negative bpm must degrade consistently — not show "0 bpm" with a "—" zone.
        for bad in [0.0, -5] {
            let m = LiveMetricsSummary.make(from: [], currentBpm: bad, maxHR: 200, restHR: 50)
            XCTAssertNil(m.currentBpm, "≤0 bpm should read as no reading")
            XCTAssertFalse(m.hasData, "an empty buffer + ≤0 reading is no data")
            XCTAssertEqual(m.zone, .none)
            XCTAssertEqual(m.recovery, .unknown)
        }
    }

    func testRedlineFractionReflectsHardZones() {
        // 180 bpm at default max 190 = 0.947 → Z5 (max); a full 10s dwell there ⇒ redline = 1.
        let samples = [HRSample(t: 0, bpm: 180), HRSample(t: 10, bpm: 180)]
        let m = LiveMetricsSummary.make(from: samples, currentBpm: 180, maxHR: nil, restHR: nil)
        XCTAssertEqual(m.redlineFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(m.zone, .max)
    }
}
