import XCTest
@testable import Snappet

/// F3b: pure media grouping + per-clip HR window (no device, no Photos).
final class FeedMediaTests: XCTestCase {

    private func media(_ offset: Double, dur: Double, ex: UUID? = nil, climb: String? = nil) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: dur,
                   exerciseId: ex, setIndex: nil, climbUUID: climb, localIdentifier: "L")
    }

    func testClipHRWindowPicksThePeakInWindow() {
        let hr = (0..<300).map { HRPoint(t: Double($0), bpm: 100 + 70 * exp(-pow(Double($0) - 120, 2) / (2 * 20 * 20))) }
        let inPeak = FeedMedia.clipHR(offsetSec: 100, durationSec: 40, hrSeries: hr, maxHR: 190)
        XCTAssertNotNil(inPeak.peakBpm)
        XCTAssertGreaterThan(inPeak.peakBpm ?? 0, 150)
        XCTAssertNotNil(inPeak.zoneRaw)
        let away = FeedMedia.clipHR(offsetSec: 250, durationSec: 10, hrSeries: hr, maxHR: 190)
        XCTAssertLessThan(away.peakBpm ?? 999, inPeak.peakBpm ?? 0)
    }

    func testClipHRNilWhenNoHR() {
        XCTAssertNil(FeedMedia.clipHR(offsetSec: 0, durationSec: 5, hrSeries: [], maxHR: 190).peakBpm)
    }

    func testGroupByExercisePreservesOrderAndBuckets() {
        let exA = UUID(), exB = UUID()
        let m = [media(10, dur: 5, ex: exA), media(50, dur: 5, ex: exB), media(20, dur: 5, ex: exA)]
        let groups = FeedMedia.groups(m, by: .byExercise) { key in
            key == exA.uuidString ? "Bench" : (key == exB.uuidString ? "Squat" : "?")
        }
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.title, "Bench")        // exA appears first (offset 10)
        XCTAssertEqual(groups.first?.items.count, 2)
    }

    func testGroupAllSortsByOffset() {
        let g = FeedMedia.groups([media(50, dur: 5), media(10, dur: 5)], by: .all) { _ in "" }
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.first?.items.first?.offsetSec, 10)
    }
}
