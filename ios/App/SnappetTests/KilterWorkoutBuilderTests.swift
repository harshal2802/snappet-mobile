import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the **pure** `KilterSession → HighlightEngine.Workout` mapping and the
/// clip→climb auto-assignment — no SwiftData, no Photos, no device.
final class KilterWorkoutBuilderTests: XCTestCase {

    func testWorkoutMapping() {
        let hr = [HRPoint(t: 0, bpm: 100), HRPoint(t: 10, bpm: 150)]
        let clips = [
            KilterWorkoutBuilder.Clip(localIdentifier: "vid1", isVideo: true, offsetSec: 30, durationSec: 12),
            KilterWorkoutBuilder.Clip(localIdentifier: "pic1", isVideo: false, offsetSec: 50, durationSec: nil),
        ]
        let w = KilterWorkoutBuilder.workout(hr: hr, duration: 300, maxHR: 190, restHR: 60, clips: clips)

        XCTAssertEqual(w.activity, .climbing)
        XCTAssertEqual(w.duration, 300)
        XCTAssertEqual(w.restBpm, 60)
        XCTAssertEqual(w.maxBpm, 190)
        XCTAssertEqual(w.hr.count, 2)
        XCTAssertEqual(w.hr.first?.bpm, 100)
        XCTAssertEqual(w.hr.last?.t, 10)

        XCTAssertEqual(w.media.count, 2)
        XCTAssertEqual(w.media[0].id, "vid1")
        XCTAssertEqual(w.media[0].kind, .video)
        XCTAssertEqual(w.media[0].startOffset, 30)
        XCTAssertEqual(w.media[0].duration, 12)
        // A photo carries a zero duration (an instant at its offset).
        XCTAssertEqual(w.media[1].kind, .photo)
        XCTAssertEqual(w.media[1].duration, 0)
    }

    func testNegativeOffsetsClampToZero() {
        let clips = [KilterWorkoutBuilder.Clip(localIdentifier: "v", isVideo: true, offsetSec: -5, durationSec: 3)]
        let w = KilterWorkoutBuilder.workout(hr: [], duration: -10, maxHR: nil, restHR: nil, clips: clips)
        XCTAssertEqual(w.duration, 0)
        XCTAssertEqual(w.media[0].startOffset, 0)
    }

    // MARK: - Clip → climb assignment

    func testClipAssignmentByWindow() {
        let windows = [
            KilterMediaAssignment.ClimbWindow(climbUUID: "A", startOffset: 0, endOffset: 60),
            KilterMediaAssignment.ClimbWindow(climbUUID: "B", startOffset: 120, endOffset: 180),
        ]
        XCTAssertEqual(KilterMediaAssignment.climbUUID(forOffset: 30, windows: windows), "A")
        XCTAssertEqual(KilterMediaAssignment.climbUUID(forOffset: 150, windows: windows), "B")
        XCTAssertEqual(KilterMediaAssignment.climbUUID(forOffset: 60, windows: windows), "A")   // inclusive end
        XCTAssertNil(KilterMediaAssignment.climbUUID(forOffset: 90, windows: windows))          // in the gap
    }

    func testOverlappingWindowsPreferLatest() {
        let windows = [
            KilterMediaAssignment.ClimbWindow(climbUUID: "A", startOffset: 0, endOffset: 100),
            KilterMediaAssignment.ClimbWindow(climbUUID: "B", startOffset: 50, endOffset: 200),
        ]
        XCTAssertEqual(KilterMediaAssignment.climbUUID(forOffset: 75, windows: windows), "B")
    }

    // MARK: - Per-climb media grouping (the data behind the galleries)

    private struct GroupClip { let climb: String?; let offset: Double }

    func testMediaGroupingByClimbSortsByOffset() {
        let media = [GroupClip(climb: "A", offset: 30), GroupClip(climb: nil, offset: 90),
                     GroupClip(climb: "A", offset: 10), GroupClip(climb: "B", offset: 50)]
        let a = KilterMediaGrouping.clips(for: "A", in: media,
                                          climbUUIDOf: { $0.climb }, offsetOf: { $0.offset })
        XCTAssertEqual(a.map(\.offset), [10, 30])   // climb A clips, capture order
        let un = KilterMediaGrouping.unassigned(in: media,
                                                climbUUIDOf: { $0.climb }, offsetOf: { $0.offset })
        XCTAssertEqual(un.map(\.offset), [90])      // only the nil-assigned clip
    }
}
