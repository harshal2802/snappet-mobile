import XCTest
@testable import Snappet

/// Unit tests for the **pure** P3 trend helpers (`KilterStatsTrend`) — range bucketing, the
/// vs-previous-period delta, the ghost alignment, the climbing-level delta, and the "Month in Send"
/// recap composition. No SwiftData, no device. The dashboard view itself reads only P0-tested
/// `KilterAllTimeStats` aggregates plus these helpers, so all the new math lives — and is tested — here.
final class KilterStatsTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .iso8601)        // Monday-first, stable ISO weeks
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// A weekly volume bucket starting `weeksAgo` weeks before `now`'s week (normalized to week-start).
    private func bucket(weeksAgo: Int, sends: Int, now: Date) -> KilterAllTimeStats.VolumeBucket {
        let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let start = cal.date(byAdding: .weekOfYear, value: -weeksAgo, to: thisWeekStart)!
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
        let label = String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        return KilterAllTimeStats.VolumeBucket(periodLabel: label, start: start, sends: sends)
    }

    /// A descending-weeks series oldest→newest (index 0 = oldest), `sends[i]` per week.
    private func series(_ sends: [Int], now: Date) -> [KilterAllTimeStats.VolumeBucket] {
        let n = sends.count
        return (0..<n).map { i in bucket(weeksAgo: n - 1 - i, sends: sends[i], now: now) }
    }

    // MARK: - Range bucketing

    func testRangeAllReturnsEverythingSortedOldestToNewest() {
        let now = date(2026, 6, 19)
        let s = series([1, 2, 3, 4], now: now)            // 4 weeks
        let out = KilterStatsTrend.bucketsInRange(s.shuffled(), range: .all, now: now, calendar: cal)
        XCTAssertEqual(out.map(\.sends), [1, 2, 3, 4])    // re-sorted oldest→newest
    }

    func test30dRangeKeepsOnlyLastFourishWeeks() {
        let now = date(2026, 6, 19)
        // 10 weeks; 30d keeps the most recent buckets at/after the (week-snapped) cutoff.
        let s = series(Array(repeating: 1, count: 10), now: now)
        let out = KilterStatsTrend.bucketsInRange(s, range: .days30, now: now, calendar: cal)
        // F4a: every kept bucket starts on/after the *week-snapped* calendar cutoff; older ones drop.
        let cutoff = KilterStatsTrend.Range.days30.cutoff(endingAt: now, calendar: cal)!
        XCTAssertTrue(out.allSatisfy { $0.start >= cutoff })
        XCTAssertTrue(out.count < s.count, "30d should drop the oldest weeks")
        XCTAssertFalse(out.isEmpty)
    }

    /// F4a: the cutoff is snapped to a week boundary, so a few days' drift in `now` within the same week
    /// yields the SAME in-range bucket count (no ±1 jitter).
    func testRangeCutoffSnapsToWeekForStableBucketCount() {
        // Three "now"s inside the same ISO week (Mon-anchored) should keep an identical count of weekly
        // buckets in range for every calendar-based range.
        let nows = [date(2026, 6, 15), date(2026, 6, 17), date(2026, 6, 19)]  // Mon, Wed, Fri
        let s = series(Array(repeating: 1, count: 20), now: date(2026, 6, 19))
        for range in [KilterStatsTrend.Range.days30, .months3, .year] {
            let counts = nows.map { KilterStatsTrend.bucketsInRange(s, range: range, now: $0,
                                                                    calendar: cal).count }
            XCTAssertEqual(Set(counts).count, 1,
                           "\(range.label) bucket count should be stable across a week (got \(counts))")
        }
    }

    func testRangeBoundaryIsInclusive() {
        let now = date(2026, 6, 19)
        // A bucket exactly 30 days back lands on the cutoff and must be kept (inclusive lower bound).
        let s = series([1, 1, 1, 1, 1], now: now)
        let out90 = KilterStatsTrend.bucketsInRange(s, range: .months3, now: now, calendar: cal)
        XCTAssertEqual(out90.count, 5, "5 recent weeks are well inside 3 months")
    }

    // MARK: - vs-previous delta

    func testDeltaUpPercentVsPreviousWindow() {
        let now = date(2026, 6, 19)
        // Derive the exact in-range window count, then build EXACTLY `w` recent fours preceded by EXACTLY
        // `w` twos — a fully-covered equal-span comparison that is +100% independent of the window size.
        let probe = series(Array(repeating: 1, count: 30), now: now)
        let w = KilterStatsTrend.bucketsInRange(probe, range: .days30, now: now, calendar: cal).count
        XCTAssertGreaterThan(w, 0)
        let s = series(Array(repeating: 2, count: w) + Array(repeating: 4, count: w), now: now)
        let unwrapped = try! XCTUnwrap(KilterStatsTrend.delta(s, range: .days30, now: now, calendar: cal))
        XCTAssertGreaterThan(unwrapped.current, unwrapped.previous)
        XCTAssertTrue(unwrapped.isUp)
        let pct = try! XCTUnwrap(unwrapped.percent)
        XCTAssertEqual(pct, 1.0, accuracy: 0.0001, "equal w-week spans: 4w vs 2w → +100%")
    }

    func testDeltaPercentNilWhenNoPreviousBaseline() {
        let now = date(2026, 6, 19)
        // "All" splits in half: a single bucket → previous half is empty → percent nil, absolute shown.
        let s = series([5], now: now)
        let d = KilterStatsTrend.delta(s, range: .all, now: now, calendar: cal)
        let unwrapped = try! XCTUnwrap(d)
        XCTAssertEqual(unwrapped.previous, 0)
        XCTAssertNil(unwrapped.percent)
        XCTAssertEqual(unwrapped.change, 5)
        XCTAssertTrue(unwrapped.caption(for: .all).contains("+5"))
    }

    func testDeltaEvenCaption() {
        let now = date(2026, 6, 19)
        let s = series([3, 3, 3, 3], now: now)
        let d = KilterStatsTrend.delta(s, range: .all, now: now, calendar: cal)
        let unwrapped = try! XCTUnwrap(d)
        XCTAssertEqual(unwrapped.change, 0)
        XCTAssertTrue(unwrapped.caption(for: .all).hasPrefix("even"))
    }

    func testDeltaNilOnEmptySeries() {
        let now = date(2026, 6, 19)
        XCTAssertNil(KilterStatsTrend.delta([], range: .months3, now: now, calendar: cal))
    }

    // MARK: - F4: equal-span comparison + honest captions

    /// F4b: when the prior history is shorter than the current window, the previous window is NOT fully
    /// covered, so the percent is suppressed (no inflated ratio off an under-counted baseline) and the
    /// caption shows the honest absolute delta instead.
    func testDeltaSuppressesPercentWhenPreviousWindowUndercovered() {
        let now = date(2026, 6, 19)
        // Build EXACTLY `w` recent threes preceded by only ONE prior week — the previous window can never
        // be fully covered, regardless of the exact window size.
        let probe = series(Array(repeating: 1, count: 30), now: now)
        let w = KilterStatsTrend.bucketsInRange(probe, range: .days30, now: now, calendar: cal).count
        XCTAssertGreaterThan(w, 1, "30d should span several weeks")
        let s = series([5] + Array(repeating: 3, count: w), now: now)
        let d = try! XCTUnwrap(KilterStatsTrend.delta(s, range: .days30, now: now, calendar: cal))
        XCTAssertNil(d.percent, "an under-covered previous window must not yield a (deflated/inflated) %")
        XCTAssertGreaterThan(d.change, 0)
        XCTAssertFalse(d.caption(for: .days30).contains("%"), "falls back to the absolute delta")
        XCTAssertTrue(d.caption(for: .days30).contains("+\(d.change)"))
    }

    /// F4c: a non-zero change whose percentage rounds to 0% must show the absolute delta, never "▲ +0%".
    func testDeltaCaptionFallsBackToAbsoluteWhenPercentRoundsToZero() {
        // +1 over a 300 baseline → 0.33% → rounds to 0%. The caption must read "+1", not "+0%".
        let d = KilterStatsTrend.Delta(current: 301, previous: 300, change: 1, percent: 1.0 / 300.0)
        let caption = d.caption(for: .months3)
        XCTAssertFalse(caption.contains("0%"), "must not print a misleading +0%")
        XCTAssertTrue(caption.contains("+1"), "shows the honest absolute delta instead")
        XCTAssertTrue(caption.hasPrefix("▲"))
    }

    /// F4c: a percentage that rounds to a non-zero value still prints as a percent.
    func testDeltaCaptionKeepsPercentWhenItRoundsNonZero() {
        let d = KilterStatsTrend.Delta(current: 24, previous: 12, change: 12, percent: 1.0)
        XCTAssertTrue(d.caption(for: .days30).contains("+100%"))
    }

    /// F4d: the flat (change == 0) case reads "even" and `isUp` is consistent (not a regression colour),
    /// regardless of whether the counts are zero or positive.
    func testDeltaIsUpConsistentWithEvenCaptionForFlatChange() {
        let flatZero = KilterStatsTrend.Delta(current: 0, previous: 0, change: 0, percent: nil)
        XCTAssertTrue(flatZero.isUp, "even (no change) must not colour as down")
        XCTAssertTrue(flatZero.caption(for: .days30).hasPrefix("even"))

        let flatPositive = KilterStatsTrend.Delta(current: 5, previous: 5, change: 0, percent: 0)
        XCTAssertTrue(flatPositive.isUp)
        XCTAssertTrue(flatPositive.caption(for: .days30).hasPrefix("even"))
    }

    /// F4d: a genuine decline is "down".
    func testDeltaIsDownForNegativeChange() {
        let d = KilterStatsTrend.Delta(current: 2, previous: 8, change: -6, percent: -0.75)
        XCTAssertFalse(d.isUp)
        XCTAssertTrue(d.caption(for: .days30).hasPrefix("▼"))
    }

    // MARK: - Ghost alignment

    func testGhostedBarsAlignToOneWindowEarlier() {
        let now = date(2026, 6, 19)
        // 8 weeks; 30d keeps the recent ~5. Each in-range bar's ghost is `window` weeks earlier.
        let s = series([1, 2, 3, 4, 5, 6, 7, 8], now: now)
        let bars = KilterStatsTrend.ghostedBars(s, range: .days30, now: now, calendar: cal)
        XCTAssertFalse(bars.isEmpty)
        // The current values match the in-range buckets, newest last.
        let inRange = KilterStatsTrend.bucketsInRange(s, range: .days30, now: now, calendar: cal)
        XCTAssertEqual(bars.map(\.current), inRange.map(\.sends))
        // The oldest in-range bar's ghost looks `window` weeks before its start — which may be out of
        // the full series (→ nil) or a real older bucket; either way it's not the bar's own value.
        for bar in bars {
            if let ghost = bar.previous { XCTAssertNotEqual(ghost, bar.current, "ghost ≠ current bucket") }
        }
    }

    func testGhostedBarsEmptyForEmptyRange() {
        let now = date(2026, 6, 19)
        // All buckets are older than 30 days → nothing in range.
        let s = series([1, 1], now: date(2026, 1, 1))   // far in the past relative to `now`
        let bars = KilterStatsTrend.ghostedBars(s, range: .days30, now: now, calendar: cal)
        XCTAssertTrue(bars.isEmpty)
    }

    // MARK: - Climbing-level delta

    func testLevelDeltaStepsUp() {
        let now = date(2026, 6, 19)
        let p = [
            KilterAllTimeStats.GradePoint(periodLabel: "2026-03", difficulty: 18, gradeLabel: "V5"),
            KilterAllTimeStats.GradePoint(periodLabel: "2026-04", difficulty: 19, gradeLabel: "V6"),
            KilterAllTimeStats.GradePoint(periodLabel: "2026-05", difficulty: 20, gradeLabel: "V6"),
            KilterAllTimeStats.GradePoint(periodLabel: "2026-06", difficulty: 21, gradeLabel: "V7"),
        ]
        // now − 3 months = March → reference is the March point (V5), latest = June (V7).
        let d = try! XCTUnwrap(KilterStatsTrend.levelDelta(p, monthsBack: 3, now: now, calendar: cal))
        XCTAssertEqual(d.steps, 21 - 18)          // 3 rounded steps
        XCTAssertEqual(d.fromLabel, "V5")
        XCTAssertEqual(d.toLabel, "V7")
    }

    func testLevelDeltaNilWithSinglePoint() {
        let now = date(2026, 6, 19)
        let p = [KilterAllTimeStats.GradePoint(periodLabel: "2026-06", difficulty: 21, gradeLabel: "V7")]
        XCTAssertNil(KilterStatsTrend.levelDelta(p, monthsBack: 3, now: now, calendar: cal))
    }

    /// F3: when the entire history is more recent than the `now − N months` cutoff, there is no honest
    /// baseline to chip against — return nil (no bogus clamp to the oldest point).
    func testLevelDeltaNilWhenAllHistoryNewerThanCutoff() {
        let now = date(2026, 6, 19)
        let p = [
            KilterAllTimeStats.GradePoint(periodLabel: "2026-05", difficulty: 18, gradeLabel: "V5"),
            KilterAllTimeStats.GradePoint(periodLabel: "2026-06", difficulty: 21, gradeLabel: "V7"),
        ]
        // monthsBack far exceeds the series (cutoff = 2024-06): no point on/before it → no delta.
        XCTAssertNil(KilterStatsTrend.levelDelta(p, monthsBack: 24, now: now, calendar: cal))
    }

    /// F3: the reference must be resolved by DATE, not by stepping back N array entries — a gap in the
    /// progression (months with no sends are simply absent) must not be miscounted.
    func testLevelDeltaResolvesReferenceByDateAcrossGap() {
        let now = date(2026, 6, 19)
        // Sends in Jan and June only (Feb–May are gaps with no points). monthsBack: 3 → cutoff = March.
        // The latest point on/before March is JANUARY (V4) — NOT "3 array entries back" (there's only one
        // earlier entry). An index-based step would over/under-shoot the gap; by-date is correct.
        let p = [
            KilterAllTimeStats.GradePoint(periodLabel: "2026-01", difficulty: 16, gradeLabel: "V4"),
            KilterAllTimeStats.GradePoint(periodLabel: "2026-06", difficulty: 21, gradeLabel: "V7"),
        ]
        let d = try! XCTUnwrap(KilterStatsTrend.levelDelta(p, monthsBack: 3, now: now, calendar: cal))
        XCTAssertEqual(d.fromLabel, "V4", "reference = the Jan point (latest on/before the March cutoff)")
        XCTAssertEqual(d.toLabel, "V7")
        XCTAssertEqual(d.steps, 21 - 16)
    }

    /// F3: a gap between two qualifying points must pick the LATEST point still on/before the cutoff,
    /// never an older one reached by counting array slots.
    func testLevelDeltaPicksLatestPointOnOrBeforeCutoff() {
        let now = date(2026, 9, 15)
        let p = [
            KilterAllTimeStats.GradePoint(periodLabel: "2026-02", difficulty: 16, gradeLabel: "V4"),
            KilterAllTimeStats.GradePoint(periodLabel: "2026-06", difficulty: 19, gradeLabel: "V6"),
            // gap: no July/Aug points
            KilterAllTimeStats.GradePoint(periodLabel: "2026-09", difficulty: 21, gradeLabel: "V7"),
        ]
        // now − 3 months = June → reference is the June point (V6), the latest on/before the cutoff.
        let d = try! XCTUnwrap(KilterStatsTrend.levelDelta(p, monthsBack: 3, now: now, calendar: cal))
        XCTAssertEqual(d.fromLabel, "V6")
        XCTAssertEqual(d.toLabel, "V7")
        XCTAssertEqual(d.steps, 21 - 19)
    }

    // MARK: - Month-in-Send recap

    func testMonthRecapComposesFromRollup() {
        var s = KilterAllTimeStats.empty
        s.monthRollups = [
            KilterAllTimeStats.PeriodRollup(periodLabel: "2026-06", sessions: 3, sends: 14,
                                            hardestGradeLabel: "V7"),
        ]
        let recap = try! XCTUnwrap(KilterStatsTrend.monthRecap(s, now: date(2026, 6, 19), calendar: cal))
        XCTAssertTrue(recap.title.contains("in Send"))
        XCTAssertTrue(recap.line.contains("14 sends"))
        XCTAssertTrue(recap.line.contains("3 sessions"))
        XCTAssertTrue(recap.line.contains("V7"))
    }

    func testMonthRecapNilWhenNoSendsThatMonth() {
        var s = KilterAllTimeStats.empty
        s.monthRollups = [
            KilterAllTimeStats.PeriodRollup(periodLabel: "2026-05", sessions: 1, sends: 4,
                                            hardestGradeLabel: "V4"),
        ]
        // Asking for June (no June roll-up) → nil.
        XCTAssertNil(KilterStatsTrend.monthRecap(s, now: date(2026, 6, 19), calendar: cal))
    }

    func testMonthRecapSingularGrammar() {
        var s = KilterAllTimeStats.empty
        s.monthRollups = [
            KilterAllTimeStats.PeriodRollup(periodLabel: "2026-06", sessions: 1, sends: 1,
                                            hardestGradeLabel: nil),
        ]
        let recap = try! XCTUnwrap(KilterStatsTrend.monthRecap(s, now: date(2026, 6, 19), calendar: cal))
        XCTAssertTrue(recap.line.contains("1 send "), "singular send, singular session")
        XCTAssertTrue(recap.line.contains("1 session"))
        XCTAssertFalse(recap.line.contains("sends"))
    }

    // MARK: - Range metadata

    func testRangePhrasesAndLabels() {
        XCTAssertEqual(KilterStatsTrend.Range.days30.label, "30d")
        XCTAssertEqual(KilterStatsTrend.Range.months3.previousPhrase, "prev 3m")
        XCTAssertEqual(KilterStatsTrend.Range.year.days, 365)
        XCTAssertNil(KilterStatsTrend.Range.all.days)
        XCTAssertEqual(KilterStatsTrend.Range.allCases.count, 4)
    }
}
