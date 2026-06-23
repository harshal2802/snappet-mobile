import XCTest
@testable import Snappet

/// Tests for the pure denser-of-two chooser behind the watch-HR HealthKit densification (prompt 102):
/// keep the complete on-wrist series over the thinned live relay, but never clobber a good (BLE / denser)
/// series or churn on a tie.
final class HRSeriesDensifyTests: XCTestCase {

    private func pts(_ n: Int, bpm: Double = 130) -> [HRPoint] {
        (0..<n).map { HRPoint(t: Double($0), bpm: bpm) }
    }

    func testBothEmpty() {
        XCTAssertTrue(HRSeriesDensify.denser(live: [], healthKit: []).isEmpty)
    }

    func testEmptyHealthKitKeepsLive() {
        // BLE-only / HK not synced → keep the live buffer (which may carry RR).
        let live = pts(6)
        XCTAssertEqual(HRSeriesDensify.denser(live: live, healthKit: []).count, 6)
    }

    func testEmptyLiveTakesHealthKit() {
        XCTAssertEqual(HRSeriesDensify.denser(live: [], healthKit: pts(8)).count, 8)
    }

    func testDenserHealthKitWins() {
        // The reported watch case: ~2 relayed samples vs the full ~30 stored.
        let live = pts(2), hk = pts(30)
        XCTAssertEqual(HRSeriesDensify.denser(live: live, healthKit: hk).count, 30)
    }

    func testDenserLiveIsKept() {
        // A denser live buffer (e.g. a partial HK read) must not be downgraded.
        XCTAssertEqual(HRSeriesDensify.denser(live: pts(20), healthKit: pts(5)).count, 20)
    }

    func testTieKeepsLive() {
        // Equal density → no reason to churn the stored series; keep live (preserves any RR it carries).
        let live = pts(5, bpm: 111), hk = pts(5, bpm: 222)
        let out = HRSeriesDensify.denser(live: live, healthKit: hk)
        XCTAssertEqual(out.first?.bpm, 111)
    }
}
