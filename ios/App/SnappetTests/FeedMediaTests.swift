import XCTest
@testable import Snappet

/// F3b: pure media grouping + per-clip HR window (no device, no Photos).
final class FeedMediaTests: XCTestCase {

    private func media(_ offset: Double, dur: Double, ex: UUID? = nil, climb: String? = nil) -> MediaInput {
        MediaInput(id: UUID(), kind: "video", offsetSec: offset, durationSec: dur,
                   exerciseId: ex, setIndex: nil, climbUUID: climb, localIdentifier: "L")
    }

    /// The footage's samples as the one resolver slices them (prompt 309: `FeedMedia` no longer
    /// has a slice of its own).
    private func window(offsetSec: Double, durationSec: Double, hrSeries: [HRPoint]) -> [HRPoint] {
        ClipHeartRate.resolve(series: hrSeries, clock: ClipCaptureClock(offsetSec: offsetSec),
                              renditionStart: 0, renditionEnd: durationSec, options: .footageOnly).data?.samples ?? []
    }

    /// The poster chip of a clip. `footageOnly` = a clip whose Studio edit has no lead-in and no tail.
    private func chip(offsetSec: Double, durationSec: Double?, hrSeries: [HRPoint],
                      footageOnly: Bool = false) -> MediaClipHR {
        var clip = MediaInput(id: UUID(), kind: "video", offsetSec: offsetSec, durationSec: durationSec,
                              exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "L")
        if footageOnly { clip.edit = ClipStudioEdit(hrLeadSec: 0, hrTailSec: 0) }
        return FeedMedia.clipHR(for: clip, hrSeries: hrSeries, maxHR: 190)
    }

    func testClipHRWindowPicksThePeakInWindow() {
        let hr = (0..<300).map { HRPoint(t: Double($0), bpm: 100 + 70 * exp(-pow(Double($0) - 120, 2) / (2 * 20 * 20))) }
        let inPeak = chip(offsetSec: 100, durationSec: 40, hrSeries: hr)
        XCTAssertNotNil(inPeak.peakBpm)
        XCTAssertGreaterThan(inPeak.peakBpm ?? 0, 150)
        XCTAssertNotNil(inPeak.zoneRaw)
        let away = chip(offsetSec: 250, durationSec: 10, hrSeries: hr)
        XCTAssertLessThan(away.peakBpm ?? 999, inPeak.peakBpm ?? 0)
    }

    func testClipHRNilWhenNoHR() {
        XCTAssertNil(chip(offsetSec: 0, durationSec: 5, hrSeries: []).peakBpm)
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
        let window = window(offsetSec: 0, durationSec: 10, hrSeries: ramp(from: 200, to: 260))
        XCTAssertTrue(window.isEmpty)
        // …and the legacy peak/avg accessor degrades to nil too (name-tag-only path).
        let hr = chip(offsetSec: 0, durationSec: 10, hrSeries: ramp(from: 200, to: 260))
        XCTAssertNil(hr.peakBpm)
    }

    func testClipWindowEntirelyAfterHRSeriesIsEmpty() {
        // Clip at [500, 510]; the series ends at t=260 → no overlap.
        let window = window(offsetSec: 500, durationSec: 10, hrSeries: ramp(from: 0, to: 260))
        XCTAssertTrue(window.isEmpty)
    }

    func testClipWindowPartialOverlapRebasesToClipLocalTime() {
        // Clip at [50, 70]; the series spans [0, 260]. Window = samples 50…70, rebased so t starts at 0.
        let window = window(offsetSec: 50, durationSec: 20, hrSeries: ramp(from: 0, to: 260))
        XCTAssertEqual(window.count, 21)             // inclusive [50, 70]
        XCTAssertEqual(window.first?.t, 0)           // rebased to clip-local 0
        XCTAssertEqual(window.last?.t, 20)
        XCTAssertEqual(window.first?.bpm, 100 + 50)  // bpm value carried through unchanged
    }

    func testZeroDurationPhotoResolvesAFlatLineAtItsInstant() {
        // A zero-duration clip resolves to a degenerate ≥2-point flat line at its instant — the slicer's
        // ≥2-point guarantee, so the still poster's chart/aggregates still draw (was a single sample).
        let window = window(offsetSec: 30, durationSec: 0, hrSeries: ramp(from: 0, to: 260))
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window.first?.t, 0)
        XCTAssertEqual(window.first?.bpm ?? 0, 130, accuracy: 0.01)   // 100 + 30, the instant's bpm
    }

    func testAVideoOfUnknownLengthIsReadOverTheDefaultSeconds() {
        // A video whose length is not known is read over `photoWindowSec` (6 s) of footage.
        let hr = chip(offsetSec: 30, durationSec: nil, hrSeries: ramp(from: 0, to: 260), footageOnly: true)
        XCTAssertEqual(hr.peakBpm, 136)          // 100 + 36: the last of [30, 36]
        XCTAssertEqual(hr.avgBpm, 133)
    }

    func testAPhotoIsReadTenSecondsEitherSideOfItsMoment() {
        // Prompt 309: one photo rule (it was 6 s forward here and ±10 s on the activity pages).
        let photo = MediaInput(id: UUID(), kind: "photo", offsetSec: 30, durationSec: nil,
                               exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "P")
        let hr = FeedMedia.clipHR(for: photo, hrSeries: ramp(from: 0, to: 260), maxHR: 190)
        XCTAssertEqual(hr.peakBpm, 140)          // [20, 40] of bpm = 100 + t
        XCTAssertEqual(hr.avgBpm, 130)
        // In the first seconds of a session the window starts at the session's start.
        let early = MediaInput(id: UUID(), kind: "photo", offsetSec: 4, durationSec: nil,
                               exerciseId: nil, setIndex: nil, climbUUID: nil, localIdentifier: "P")
        XCTAssertEqual(FeedMedia.clipHR(for: early, hrSeries: ramp(from: 0, to: 260), maxHR: 190).peakBpm, 114)
    }

    func testTheChipShowsTheOverlaysPeakAndAverage() {
        // Prompt 309: the chip is over the clip's own HR window (5 s before, 30 s after), as the
        // overlay's PEAK and AVG are. bpm = 100 + t, clip 50…60: the window is 45…90.
        let hr = chip(offsetSec: 50, durationSec: 10, hrSeries: ramp(from: 0, to: 260))
        XCTAssertEqual(hr.peakBpm, 190)          // was 160 (the footage alone)
        XCTAssertEqual(hr.avgBpm, 168)           // 167.5; was 155
        let footage = chip(offsetSec: 50, durationSec: 10, hrSeries: ramp(from: 0, to: 260), footageOnly: true)
        XCTAssertEqual(footage.peakBpm, 160)
        XCTAssertEqual(footage.avgBpm, 155)
    }

    func testSparseHRSeriesInterpolatesWindowEndpoints() {
        // Sparse series (every 20s). Clip [25, 65] contains t=40, t=60 (→ clip-local 15, 35) PLUS the
        // slicer's interpolated endpoints at the window edges (clip-local 0 and 40), so the chart has a
        // correctly-anchored line instead of starting/ending mid-gap.
        let sparse = [0, 20, 40, 60, 80, 100].map { HRPoint(t: Double($0), bpm: Double(120 + $0)) }
        let window = window(offsetSec: 25, durationSec: 40, hrSeries: sparse)
        XCTAssertEqual(window.map(\.t), [0, 15, 35, 40])         // interp@25, t40→15, t60→35, interp@65
        XCTAssertEqual(window.first?.bpm ?? 0, 145, accuracy: 0.01)   // interp 140→160 at (25-20)/20
        XCTAssertEqual(window.last?.bpm ?? 0, 185, accuracy: 0.01)    // interp 180→200 at (65-60)/20
    }

    func testWithinCoverageWindowInterpolatesInsteadOfBlanking() {
        // The exact [offset, offset+dur] window holds NO raw samples, but it lies INSIDE the series'
        // coverage, so the hardened slicer interpolates the window edges (it never blanks within
        // coverage). The poster chip resolves its peak from the SAME interpolated window → both agree.
        let sparse = [0.0, 30.0, 90.0].map { HRPoint(t: $0, bpm: 100 + $0) }   // bpm 100, 130, 190
        let window = window(offsetSec: 33, durationSec: 2, hrSeries: sparse)
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window.map(\.t), [0, 2])
        XCTAssertEqual(window.first?.bpm ?? 0, 133, accuracy: 0.01)   // interp 130→190 at (33-30)/60
        XCTAssertEqual(window.last?.bpm ?? 0, 135, accuracy: 0.01)    // interp at (35-30)/60
        // The chip is a bare number with no dashed line: it prints one only when a recorded
        // sample lies in the clip's HR window (prompt 309, `ClipHRSummary.printable`). Over the
        // footage alone (33…35 s) there is none, so no chip (it printed 135, a reading drawn
        // between the samples at 30 s and 90 s); the tile still shows the window above, dashed.
        // Over the default window (28…65 s) the sample at 30 s is inside: peak 165 at 65 s.
        XCTAssertNil(chip(offsetSec: 33, durationSec: 2, hrSeries: sparse, footageOnly: true).peakBpm)
        XCTAssertEqual(chip(offsetSec: 33, durationSec: 2, hrSeries: sparse, footageOnly: false).peakBpm, 165)
    }

    func testWindowEmptyOnlyWhenFartherThanTheEdgeClampPad() {
        // Out of coverage by MORE than the ±90s edge-clamp pad → honestly empty (name-tag-only): a clip
        // filmed minutes after HR stopped, or a cross-day manual pick.
        let sparse = [0.0, 30.0, 90.0].map { HRPoint(t: $0, bpm: 100 + $0) }
        XCTAssertTrue(window(offsetSec: 200, durationSec: 5, hrSeries: sparse).isEmpty)
    }

    func testEdgeClipWithinPadHoldsAFlatLastKnownLine() {
        // Just past the last sample but within the ±90s discovery pad → a flat "last known" 2-point line
        // (the edge sample held across the clip), so a legit edge clip shows HR instead of going blank.
        let sparse = [0.0, 30.0, 90.0].map { HRPoint(t: $0, bpm: 100 + $0) }   // last bpm 190 @ t=90
        let window = window(offsetSec: 120, durationSec: 4, hrSeries: sparse)
        XCTAssertEqual(window.count, 2)
        XCTAssertEqual(window.map(\.bpm), [190, 190])           // held last-known across the clip
        XCTAssertEqual(window.map(\.t), [0, 4])
    }

    func testWindowCarriesRRIntervalsThrough() {
        // The windowed slice must preserve each sample's rrIntervalsMs (HRV input), rebased in t only.
        let series = [
            HRPoint(t: 50, bpm: 150, rrIntervalsMs: [820, 805]),
            HRPoint(t: 51, bpm: 152, rrIntervalsMs: [798]),
            HRPoint(t: 52, bpm: 151, rrIntervalsMs: nil),
        ]
        let window = window(offsetSec: 50, durationSec: 2, hrSeries: series)
        XCTAssertEqual(window.count, 3)
        XCTAssertEqual(window.map(\.rrIntervalsMs), [[820, 805], [798], nil])  // carried through
        XCTAssertEqual(window.map(\.t), [0, 1, 2])                              // rebased to clip-local
    }

    func testEmptyHRSeriesYieldsEmptyWindow() {
        XCTAssertTrue(window(offsetSec: 10, durationSec: 5, hrSeries: []).isEmpty)
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

    // MARK: feed scorebug — HRR drops without a rest HR

    func testFeedClipScorebugDropsHRRWithoutRestHR() {
        // With a rest HR, HRR is meaningful → kept.
        XCTAssertTrue(HRTile.feedClipScorebug(restHR: 55).enabledMetrics.contains(.hrr),
                      "HRR should be shown when a rest HR is present")
        // No / zero rest HR → HRR is undefined (would render a dead 0%) → dropped.
        XCTAssertFalse(HRTile.feedClipScorebug(restHR: nil).enabledMetrics.contains(.hrr),
                       "HRR should be dropped when there's no rest HR")
        XCTAssertFalse(HRTile.feedClipScorebug(restHR: 0).enabledMetrics.contains(.hrr),
                       "HRR should be dropped when rest HR is 0")
        // The other scorebug metrics are unaffected either way.
        XCTAssertTrue(HRTile.feedClipScorebug(restHR: nil).enabledMetrics.contains(.bpm),
                      "BPM stays even without a rest HR")
    }
}
