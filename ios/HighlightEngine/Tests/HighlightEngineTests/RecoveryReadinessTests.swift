import XCTest
@testable import HighlightEngine

final class RecoveryReadinessTests: XCTestCase {

    func testUnknownWithoutBounds() {
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 120, restBpm: nil, maxBpm: 190).state, .unknown)
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 120, restBpm: 60, maxBpm: nil).state, .unknown)
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: nil, restBpm: 60, maxBpm: 190).state, .unknown)
        // max ≤ rest is nonsense → unknown, never a divide-by-zero.
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 120, restBpm: 190, maxBpm: 190).state, .unknown)
    }

    func testReadyWhenRecovered() {
        // rest 60, max 190 → reserve 130. 100 bpm → %HRR = 40/130 ≈ 0.31 ≤ 0.40 → ready.
        let r = RecoveryReadiness.evaluate(currentBpm: 100, restBpm: 60, maxBpm: 190)
        XCTAssertEqual(r.state, .ready)
        XCTAssertEqual(r.fraction, 1 - 40.0 / 130.0, accuracy: 0.001)
    }

    func testRecoveringWhenElevated() {
        // 150 bpm → %HRR = 90/130 ≈ 0.69 > 0.40 → recovering.
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 150, restBpm: 60, maxBpm: 190).state, .recovering)
    }

    func testHRVReboundEasesThreshold() {
        // 113 bpm → %HRR = 53/130 ≈ 0.408 — just over the 0.40 default → recovering…
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 113, restBpm: 60, maxBpm: 190).state, .recovering)
        // …but a fully-rebounded HRV eases the threshold to 0.50 → ready.
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 113, restBpm: 60, maxBpm: 190,
                                                  rrReboundFraction: 1.0).state, .ready)
    }

    func testFractionClampsToUnitInterval() {
        // Below rest → fraction clamps at 1 (fully recovered), not >1.
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 50, restBpm: 60, maxBpm: 190).fraction, 1, accuracy: 0.001)
        // Above max → fraction clamps at 0.
        XCTAssertEqual(RecoveryReadiness.evaluate(currentBpm: 250, restBpm: 60, maxBpm: 190).fraction, 0, accuracy: 0.001)
    }
}
