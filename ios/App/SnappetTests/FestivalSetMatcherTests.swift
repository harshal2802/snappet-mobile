import XCTest
@testable import Snappet

/// The confidence table for `FestivalSetMatcher` (festival prompt 01) — read it like wireframe frame
/// 9's captions: mid-set → 97%, between stages → 62%, two sets live → capped below the auto threshold,
/// campsite footage → outside schedule. Every `Assignment.Reason` case is covered, plus the
/// midnight/day-boundary and timezone rows and the hint-boosts-never-overrides contract.
final class FestivalSetMatcherTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()

    private func match(_ local: String, duration: TimeInterval? = nil,
                       hints: [FestivalSessionHint] = []) -> FestivalSetMatcher.Assignment {
        FestivalSetMatcher.assignments(
            for: [ClipStamp(id: "clip", captureDate: FestivalFixtures.date(local),
                            duration: duration)],
            in: pack, hints: hints)[0]
    }

    private func hint(_ artist: String, _ from: String, _ to: String) -> FestivalSessionHint {
        FestivalSessionHint(setID: FestivalFixtures.set(named: artist, in: pack).id,
                            interval: DateInterval(start: FestivalFixtures.date(from),
                                                   end: FestivalFixtures.date(to)))
    }

    // MARK: - The threshold is one source of truth

    func testConfidenceConstantsBracketTheAutoThreshold() {
        // Auto: a lone containing set. Ask: everything ambiguous — structurally, not by luck.
        XCTAssertGreaterThanOrEqual(FestivalSetMatcher.withinSetConfidence,
                                    FestivalSetMatcher.autoTagThreshold)
        XCTAssertLessThan(FestivalSetMatcher.multipleLiveCap, FestivalSetMatcher.autoTagThreshold)
        XCTAssertLessThan(FestivalSetMatcher.gapEdgeConfidence, FestivalSetMatcher.autoTagThreshold)
        XCTAssertLessThan(FestivalSetMatcher.gapFloorConfidence,
                          FestivalSetMatcher.gapEdgeConfidence)
    }

    // MARK: - Within a set (auto)

    func testMidSetClipAutoTagsHigh() {
        // 20:41, only Little Simz is on → "mid-set · ✦ 97%".
        let a = match("2026-06-27T20:41")
        XCTAssertEqual(a.set?.artist, "Little Simz")
        XCTAssertEqual(a.reason, .withinSet)
        XCTAssertEqual(a.confidence, FestivalSetMatcher.withinSetConfidence)
        XCTAssertTrue(a.isAutoTag)
    }

    func testHandoverInstantBelongsToTheStartingSet() {
        // A photo at exactly 01:00 — Overmono's end IS Jayda G's start. Half-open windows: it counts
        // toward the set starting, unambiguously.
        let a = match("2026-06-28T01:00")
        XCTAssertEqual(a.set?.artist, "Jayda G")
        XCTAssertEqual(a.reason, .withinSet)
        XCTAssertTrue(a.isAutoTag)
    }

    func testMidnightCrossingClipStillMatchesItsSet() {
        // 01:30 on the calendar-Sunday night: Jayda G is on, poster day is still Saturday.
        let a = match("2026-06-28T01:30")
        XCTAssertEqual(a.set?.artist, "Jayda G")
        XCTAssertEqual(a.reason, .withinSet)
        XCTAssertEqual(pack.day(containing: FestivalFixtures.date("2026-06-28T01:30"))?.date,
                       "2026-06-27")
    }

    func testMatchingIsTimezoneAgnostic() {
        // The same absolute instant expressed from a New York phone (−04:00) — 15:41 EDT is 20:41 BST.
        let nyClock = ClipStamp(id: "ny",
                                captureDate: FestivalFixtures.date("2026-06-27T15:41",
                                                                   offsetSeconds: -4 * 3600))
        let a = FestivalSetMatcher.assignments(for: [nyClock], in: pack)[0]
        XCTAssertEqual(a.set?.artist, "Little Simz")
        XCTAssertEqual(a.reason, .withinSet)
    }

    // MARK: - Between sets (always asks)

    func testGapClipReadsLikeTheWireframeCaption() {
        // 21:21 — 6 min after Little Simz ended, nothing on anywhere → "between stages · 62%".
        let a = match("2026-06-27T21:21")
        XCTAssertEqual(a.set?.artist, "Little Simz")
        XCTAssertEqual(a.reason, .betweenSets(
            before: FestivalFixtures.set(named: "Little Simz", in: pack),
            after: FestivalFixtures.set(named: "Fred again..", in: pack)))
        XCTAssertEqual(a.confidence, 0.62, accuracy: 0.0001)
        XCTAssertFalse(a.isAutoTag)
    }

    func testGapConfidenceDecaysToTheFloorMidGap() {
        // 21:45 — dead center of the hour gap, 30 min from either edge → the floor.
        let a = match("2026-06-27T21:45")
        XCTAssertEqual(a.confidence, FestivalSetMatcher.gapFloorConfidence, accuracy: 0.0001)
        XCTAssertFalse(a.isAutoTag)
    }

    func testGapClipLeansTowardTheNearerEdge() {
        // 22:05 — 10 min before Fred again.., 50 after Simz → lean forward.
        let a = match("2026-06-27T22:05")
        XCTAssertEqual(a.set?.artist, "Fred again..")
        XCTAssertEqual(a.confidence, 0.70 - 0.40 * (600.0 / 1800.0), accuracy: 0.0001)
    }

    // MARK: - Multiple sets live (capped below auto — the acceptance criterion)

    func testTwoStagesLivePicksTheNearerMidpointCappedBelowAuto() {
        // 23:58 — Overmono (West Holts) and Eric Prydz (Arcadia) both on. Prydz's midpoint (23:45) is
        // nearer than Overmono's (00:15) → chosen, at a split share of the cap. "two sets live · 58%"-
        // territory, never auto.
        let a = match("2026-06-27T23:58")
        XCTAssertEqual(a.set?.artist, "Eric Prydz")
        XCTAssertEqual(a.reason, .multipleStagesLive([
            FestivalFixtures.set(named: "Eric Prydz", in: pack),
            FestivalFixtures.set(named: "Overmono", in: pack),
        ]), "candidates sorted by start for stable review rows")
        // share = (1/780) / (1/780 + 1/1020) = 1020/1800
        XCTAssertEqual(a.confidence, 0.65 * (1020.0 / 1800.0), accuracy: 0.0001)
        XCTAssertFalse(a.isAutoTag)
    }

    func testThreeStagesLiveStillCapped() {
        // 23:35 — Fred again.., Overmono, AND Eric Prydz are all on.
        let a = match("2026-06-27T23:35")
        guard case .multipleStagesLive(let live) = a.reason else {
            return XCTFail("expected multipleStagesLive, got \(a.reason)")
        }
        XCTAssertEqual(Set(live.map(\.artist)), ["Fred again..", "Overmono", "Eric Prydz"])
        XCTAssertLessThan(a.confidence, FestivalSetMatcher.autoTagThreshold)
        XCTAssertFalse(a.isAutoTag)
    }

    func testStraddlingAdjacentSetsIsAmbiguous() {
        // A 20-min video from 00:50 — half in Overmono, half in Jayda G, same stage. Equal evidence →
        // an even split of the cap; floats to review, the earlier set leading.
        let a = match("2026-06-28T00:50", duration: 20 * 60)
        XCTAssertEqual(a.set?.artist, "Overmono")
        XCTAssertEqual(a.confidence, FestivalSetMatcher.multipleLiveCap * 0.5, accuracy: 0.0001)
        XCTAssertFalse(a.isAutoTag)
    }

    func testStraddlingClipLeansTowardTheDominantOverlap() {
        // 30 min from 00:55 — 5 min of Overmono, 25 of Jayda G → Jayda leads at 25/30 of the cap.
        let a = match("2026-06-28T00:55", duration: 30 * 60)
        XCTAssertEqual(a.set?.artist, "Jayda G")
        XCTAssertEqual(a.confidence, 0.65 * (1500.0 / 1800.0), accuracy: 0.0001)
        XCTAssertFalse(a.isAutoTag)
    }

    func testHintCanNeverLiftMultipleLiveAboveTheCap() {
        // Dead-center of Prydz's set with an "I'm here — Prydz" hint: as strong as multi-live evidence
        // gets, and still clamped to the cap — the acceptance criterion, hint or no hint.
        let a = match("2026-06-27T23:45",
                      hints: [hint("Eric Prydz", "2026-06-27T23:00", "2026-06-28T00:30")])
        XCTAssertEqual(a.set?.artist, "Eric Prydz")
        XCTAssertEqual(a.confidence, FestivalSetMatcher.multipleLiveCap, accuracy: 0.0001)
        XCTAssertFalse(a.isAutoTag)
    }

    // MARK: - Outside the schedule

    func testCampsiteMorningIsOutsideSchedule() {
        // 10:00 Saturday — inside the festival day, before any set: nobody's footage.
        let a = match("2026-06-27T10:00")
        XCTAssertNil(a.set)
        XCTAssertEqual(a.reason, .outsideSchedule)
        XCTAssertEqual(a.confidence, 0)
    }

    func testAfterTheLastSetIsOutsideSchedule() {
        // 03:00 — Jayda G wrapped at 02:30 and nothing follows on the Saturday.
        let a = match("2026-06-28T03:00")
        XCTAssertEqual(a.reason, .outsideSchedule)
    }

    func testOutsideEveryFestivalDayIsOutsideSchedule() {
        let a = match("2026-07-05T20:00")
        XCTAssertEqual(a.reason, .outsideSchedule)
        XCTAssertNil(a.set)
    }

    // MARK: - Session hints (boost, never override)

    func testMatchingHintBoostsAWithinSetTag() {
        let a = match("2026-06-27T20:41",
                      hints: [hint("Little Simz", "2026-06-27T20:00", "2026-06-27T21:15")])
        XCTAssertEqual(a.set?.artist, "Little Simz")
        XCTAssertEqual(a.confidence, FestivalSetMatcher.maxConfidence, accuracy: 0.0001)
    }

    func testHintNeverOverridesTimeEvidence() {
        // The user says "I'm here — Fred again.." but the clock says Little Simz is the only set on.
        // Time wins; the hint is ignored, not blended.
        let a = match("2026-06-27T20:41",
                      hints: [hint("Fred again..", "2026-06-27T20:00", "2026-06-27T21:15")])
        XCTAssertEqual(a.set?.artist, "Little Simz")
        XCTAssertEqual(a.confidence, FestivalSetMatcher.withinSetConfidence)
    }

    func testHintBreaksTheTieBetweenLiveCandidates() {
        // 23:58, two stages live; the hint says the user was at Overmono → Overmono leads, boosted but
        // still gap-of-evidence honest (share + boost, under the cap).
        let a = match("2026-06-27T23:58",
                      hints: [hint("Overmono", "2026-06-27T23:30", "2026-06-28T01:00")])
        XCTAssertEqual(a.set?.artist, "Overmono")
        XCTAssertEqual(a.confidence, 0.65 * (780.0 / 1800.0) + 0.1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(a.confidence, FestivalSetMatcher.multipleLiveCap)
    }

    func testHintFlipsAGapTowardItsSide() {
        // 21:50 is nearer Fred again.. (25 min) than Little Simz (35 min), but the session hint says
        // the user lingered at Simz — choose Simz, scored by ITS true distance (no boost past evidence).
        let a = match("2026-06-27T21:50",
                      hints: [hint("Little Simz", "2026-06-27T20:00", "2026-06-27T22:00")])
        XCTAssertEqual(a.set?.artist, "Little Simz")
        XCTAssertEqual(a.confidence, FestivalSetMatcher.gapFloorConfidence, accuracy: 0.0001)
        guard case .betweenSets = a.reason else { return XCTFail("expected betweenSets") }
    }

    func testHintOutsideItsIntervalDoesNothing() {
        // The hint covered an earlier stretch — this clip is outside it, so no boost applies.
        let a = match("2026-06-27T20:41",
                      hints: [hint("Little Simz", "2026-06-27T18:00", "2026-06-27T19:00")])
        XCTAssertEqual(a.confidence, FestivalSetMatcher.withinSetConfidence)
    }

    // MARK: - Batch shape

    func testAssignmentsComeBackOnePerClipInOrder() {
        let clips = [
            ClipStamp(id: "one", captureDate: FestivalFixtures.date("2026-06-27T20:41"), duration: nil),
            ClipStamp(id: "two", captureDate: FestivalFixtures.date("2026-06-27T21:21"), duration: nil),
            ClipStamp(id: "three", captureDate: FestivalFixtures.date("2026-07-05T20:00"), duration: nil),
        ]
        let out = FestivalSetMatcher.assignments(for: clips, in: pack)
        XCTAssertEqual(out.map(\.clipID), ["one", "two", "three"])
        XCTAssertEqual(FestivalSetMatcher.assignments(for: [], in: pack), [])
    }

    func testSingleDayOverloadMatchesTheSameWay() {
        let clip = ClipStamp(id: "c", captureDate: FestivalFixtures.date("2026-06-27T20:41"),
                             duration: nil)
        let a = FestivalSetMatcher.assignments(for: [clip], on: pack.days[0],
                                               utcOffsetSeconds: pack.utcOffsetSeconds)[0]
        XCTAssertEqual(a.set?.artist, "Little Simz")
    }
}
