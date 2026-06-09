import XCTest
@testable import Snappet

/// Unit tests for the pure multi-clip HR placement — the headline fix: each clip in a Studio project
/// gets HR from its OWN capture moment, not the whole session crammed across the composition. No device.
final class StudioHRPlacementTests: XCTestCase {

    private func clip(_ order: Int, trimStart: Double = 0, trimEnd: Double? = nil) -> TimelineClip {
        TimelineClip(sessionMediaID: UUID(), localIdentifier: "asset\(order)", isPhoto: false,
                     order: order, trimStart: trimStart, trimEnd: trimEnd)
    }

    /// Session HR rises 100→160 over [0, 3600]. Two clips filmed at very different times must each get
    /// their OWN window's HR — not the same whole-session line. This is the regression the bug was.
    func testTwoClipsFromDifferentSessionTimesAlignToOwnWindows() {
        let series = stride(from: 0.0, through: 3600.0, by: 60.0).map {
            HRPoint(t: $0, bpm: 100 + ($0 / 3600) * 60)   // 100 at t=0 … 160 at t=3600
        }
        let early = clip(0); let late = clip(1)
        let offsets = [early.id: 300.0, late.id: 3000.0]            // filmed at 5 min and 50 min
        let durations = [early.id: 30.0, late.id: 30.0]
        let out = StudioHRPlacement.sample(clips: [early, late], offsets: offsets,
                                           sourceDurations: durations, series: series)

        let earlyAvg = out[early.id]!.map(\.bpm).reduce(0, +) / Double(out[early.id]!.count)
        let lateAvg = out[late.id]!.map(\.bpm).reduce(0, +) / Double(out[late.id]!.count)
        // ~105 bpm at 5 min vs ~150 bpm at 50 min — the clips show DISTINCT, time-correct HR.
        XCTAssertEqual(earlyAvg, 105, accuracy: 3)
        XCTAssertEqual(lateAvg, 150, accuracy: 3)
        XCTAssertGreaterThan(lateAvg, earlyAvg + 30)
    }

    /// A clip whose window precedes the trimmed footage uses the trimmed sub-range (offset + trimStart),
    /// so trimming to a later part of a clip moves the HR window too.
    func testTrimShiftsTheCaptureWindow() {
        let series = stride(from: 0.0, through: 600.0, by: 10.0).map { HRPoint(t: $0, bpm: $0) } // bpm==t
        let c = clip(0, trimStart: 100, trimEnd: 130)              // visible footage = session 200…230
        let offsets = [c.id: 100.0]                                // asset starts at session t=100
        let out = StudioHRPlacement.sample(clips: [c], offsets: offsets,
                                           sourceDurations: [c.id: 300], series: series)
        let avg = out[c.id]!.map(\.bpm).reduce(0, +) / Double(out[c.id]!.count)
        XCTAssertEqual(avg, 215, accuracy: 6)                      // ~mid of [200,230]
    }

    /// A clip whose window is far past the session's HR (cool-down clip) is absent → no borrowed HR.
    func testClipFarOutsideCoverageIsAbsent() {
        let series = [HRPoint(t: 0, bpm: 120), HRPoint(t: 600, bpm: 140)]
        let c = clip(0)
        let out = StudioHRPlacement.sample(clips: [c], offsets: [c.id: 5000],   // 73 min after last
                                           sourceDurations: [c.id: 15], series: series)
        XCTAssertNil(out[c.id])
    }

    func testPhotosAndEmptySeriesProduceNothing() {
        let photo = TimelineClip(sessionMediaID: UUID(), localIdentifier: "p", isPhoto: true, order: 0)
        XCTAssertTrue(StudioHRPlacement.sample(clips: [photo], offsets: [photo.id: 10],
                                               sourceDurations: [:], series: [HRPoint(t: 10, bpm: 100)]).isEmpty)
        let v = clip(0)
        XCTAssertTrue(StudioHRPlacement.sample(clips: [v], offsets: [v.id: 0],
                                               sourceDurations: [v.id: 10], series: []).isEmpty)
    }
}
