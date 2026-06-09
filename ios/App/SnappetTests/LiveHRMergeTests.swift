import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the pure live-HR transport merge — the in-editor fallback that keeps a clip's HR
/// from going blank when a workout switched HR source mid-session (only the active source's buffer is
/// otherwise visible). No device.
final class LiveHRMergeTests: XCTestCase {

    func testMergeUnionsAndSortsByT() {
        let watch = [HRSample(t: 0, bpm: 100), HRSample(t: 20, bpm: 120)]
        let ble = [HRSample(t: 10, bpm: 110), HRSample(t: 30, bpm: 130)]
        let out = LiveHRMerge.merge(watch, ble)
        XCTAssertEqual(out.map(\.t), [0, 10, 20, 30])
        XCTAssertEqual(out.map(\.bpm), [100, 110, 120, 130])
    }

    func testMergeEitherSideEmpty() {
        let ble = [HRSample(t: 0, bpm: 90), HRSample(t: 5, bpm: 95)]
        XCTAssertEqual(LiveHRMerge.merge([], ble).map(\.t), [0, 5])
        XCTAssertEqual(LiveHRMerge.merge(ble, []).map(\.t), [0, 5])
        XCTAssertTrue(LiveHRMerge.merge([], []).isEmpty)
    }

    /// Same instant from both transports collapses to one, preferring the sample carrying RR (so HRV
    /// from the chest strap survives a watch overlap at the same timestamp).
    func testMergeDeDupesNearTimestampsKeepingRR() {
        let watch = [HRSample(t: 10.0, bpm: 120)]                       // no RR
        let ble = [HRSample(t: 10.1, bpm: 121, rrIntervalsMs: [800])]   // within epsilon, has RR
        let out = LiveHRMerge.merge(watch, ble)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.rrIntervalsMs, [800])
    }
}
