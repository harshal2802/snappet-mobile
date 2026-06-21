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

    // MARK: - F3b (R6) — clip-HR window slicing (the editor `HROverlayValues` input)

    private func ramp(from: Int, to: Int) -> [HRPoint] {
        (from...to).map { HRPoint(t: Double($0), bpm: 100 + Double($0)) }
    }

    func testClipWindowEntirelyBeforeHRSeriesIsEmpty() {
        // Clip at [0, 10]; the series only starts at t=200 → no overlap, no fabricated samples.
        let window = FeedMedia.clipHRWindow(offsetSec: 0, durationSec: 10, hrSeries: ramp(from: 200, to: 260))
        XCTAssertTrue(window.isEmpty)
        // …and the legacy peak/avg accessor degrades to nil too (name-tag-only path).
        let hr = FeedMedia.clipHR(offsetSec: 0, durationSec: 10, hrSeries: ramp(from: 200, to: 260), maxHR: 190)
        XCTAssertNil(hr.peakBpm)
    }

    func testClipWindowEntirelyAfterHRSeriesIsEmpty() {
        // Clip at [500, 510]; the series ends at t=260 → no overlap.
        let window = FeedMedia.clipHRWindow(offsetSec: 500, durationSec: 10, hrSeries: ramp(from: 0, to: 260))
        XCTAssertTrue(window.isEmpty)
    }

    func testClipWindowPartialOverlapRebasesToClipLocalTime() {
        // Clip at [50, 70]; the series spans [0, 260]. Window = samples 50…70, rebased so t starts at 0.
        let window = FeedMedia.clipHRWindow(offsetSec: 50, durationSec: 20, hrSeries: ramp(from: 0, to: 260))
        XCTAssertEqual(window.count, 21)             // inclusive [50, 70]
        XCTAssertEqual(window.first?.t, 0)           // rebased to clip-local 0
        XCTAssertEqual(window.last?.t, 20)
        XCTAssertEqual(window.first?.bpm, 100 + 50)  // bpm value carried through unchanged
    }

    func testZeroDurationPhotoCollapsesToTheSampleAtOffset() {
        // A zero-duration clip resolves to the sample(s) AT its offset (the still poster's moment).
        let window = FeedMedia.clipHRWindow(offsetSec: 30, durationSec: 0, hrSeries: ramp(from: 0, to: 260))
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.first?.t, 0)
        XCTAssertEqual(window.first?.bpm, 100 + 30)
    }

    func testNilDurationPhotoUsesDefaultWindow() {
        // A photo (nil duration) gets the default `photoWindowSec` window so a still still resolves HR.
        let window = FeedMedia.clipHRWindow(offsetSec: 30, durationSec: nil, hrSeries: ramp(from: 0, to: 260))
        XCTAssertEqual(window.count, Int(FeedMedia.photoWindowSec) + 1)  // inclusive [30, 30+6]
        XCTAssertEqual(window.first?.t, 0)
    }

    func testSparseHRSeriesKeepsOnlyTrulyInWindowSamples() {
        // Sparse series (every 20s). Clip [25, 65] only contains t=40, t=60 → 2 samples, rebased.
        let sparse = [0, 20, 40, 60, 80, 100].map { HRPoint(t: Double($0), bpm: Double(120 + $0)) }
        let window = FeedMedia.clipHRWindow(offsetSec: 25, durationSec: 40, hrSeries: sparse)
        XCTAssertEqual(window.map(\.t), [15, 35])    // (40-25), (60-25)
    }

    func testSparseWindowWithNoExactSamplesFallsBackToNearestWithin8s() {
        // The exact [offset, offset+dur] window holds NO samples, but a sample sits within ±8s of the
        // offset. The window must fall back to it (matching the poster chip's `clipHR`), so the poster
        // and the fullscreen overlay agree (both show HR, not chip-yes / overlay-blank).
        let sparse = [0.0, 30.0, 90.0].map { HRPoint(t: $0, bpm: 100 + $0) }
        // Clip at [33, 35]: nothing in-window, but t=30 is within 8s of offset 33.
        let window = FeedMedia.clipHRWindow(offsetSec: 33, durationSec: 2, hrSeries: sparse)
        XCTAssertFalse(window.isEmpty)               // now non-empty via the ±8s fallback
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.first?.bpm, 130)       // the t=30 sample
        XCTAssertEqual(window.first?.t, 0)           // rebased to clip-local (max(0, 30-33))
        // The poster chip resolves a peak from the SAME fallback → both agree.
        XCTAssertEqual(FeedMedia.clipHR(offsetSec: 33, durationSec: 2, hrSeries: sparse, maxHR: 190).peakBpm, 130)
    }

    func testWindowStillEmptyWhenNoSampleWithin8s() {
        // No sample inside the window AND none within ±8s of the offset → truly empty (name-tag-only).
        let sparse = [0.0, 30.0, 90.0].map { HRPoint(t: $0, bpm: 100 + $0) }
        // Clip at [50, 55]: in-window empty, and nearest samples (t=30, t=90) are both >8s from offset 50.
        XCTAssertTrue(FeedMedia.clipHRWindow(offsetSec: 50, durationSec: 5, hrSeries: sparse).isEmpty)
    }

    func testWindowCarriesRRIntervalsThrough() {
        // The windowed slice must preserve each sample's rrIntervalsMs (HRV input), rebased in t only.
        let series = [
            HRPoint(t: 50, bpm: 150, rrIntervalsMs: [820, 805]),
            HRPoint(t: 51, bpm: 152, rrIntervalsMs: [798]),
            HRPoint(t: 52, bpm: 151, rrIntervalsMs: nil),
        ]
        let window = FeedMedia.clipHRWindow(offsetSec: 50, durationSec: 2, hrSeries: series)
        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.map(\.rrIntervalsMs), [[820, 805], [798], nil])  // carried through
        XCTAssertEqual(window.map(\.t), [0, 1, 2])                              // rebased to clip-local
    }

    func testEmptyHRSeriesYieldsEmptyWindow() {
        XCTAssertTrue(FeedMedia.clipHRWindow(offsetSec: 10, durationSec: 5, hrSeries: []).isEmpty)
    }

    // MARK: - F3b (R6) — General bucket + cross-session grouping

    func testByExerciseCollectsUnassignedClipsIntoGeneralBucket() {
        let exA = UUID()
        // One assigned clip + two unassigned (no exerciseId, no climbUUID) → a "general" bucket.
        let m = [media(10, dur: 5, ex: exA), media(20, dur: 5), media(30, dur: 5)]
        let groups = FeedMedia.groups(m, by: .byExercise) { key in
            key == "general" ? "General" : (key == exA.uuidString ? "Bench" : "?")
        }
        XCTAssertEqual(groups.count, 2)
        let general = groups.first { $0.id == "general" }
        XCTAssertNotNil(general)
        XCTAssertEqual(general?.title, "General")
        XCTAssertEqual(general?.items.count, 2)      // both unassigned clips, never dropped
    }

    func testByExerciseMixesClimbAndExerciseAndGeneralKeys() {
        let exA = UUID()
        let m = [media(5, dur: 5, climb: "C1"), media(15, dur: 5, ex: exA), media(25, dur: 5)]
        let groups = FeedMedia.groups(m, by: .byExercise) { key in
            switch key {
            case "C1": return "V4 crimp"
            case exA.uuidString: return "Bench"
            default: return "General"
            }
        }
        XCTAssertEqual(groups.map(\.title), ["V4 crimp", "Bench", "General"])   // first-offset order
    }

    func testBySessionFlatBucketHoldsTheWholeCorpusOrdered() {
        // The "By session" mode flattens everything into one offset-ordered bucket (the cross-session
        // browser surfaces media from >1 session into the same flat list here).
        let m = [media(90, dur: 5), media(10, dur: 5), media(50, dur: 5)]
        let groups = FeedMedia.groups(m, by: .bySession) { _ in "" }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.map(\.offsetSec), [10, 50, 90])
    }
}
