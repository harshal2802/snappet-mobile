import XCTest
@testable import Snappet

/// The pure tagging layer of festival prompt 03: the media→stamp adaptation, the auto-vs-ask plan
/// (sticky user rows, stale auto removal, idempotency), the review captions/candidates, the
/// rollover-aware day label, and the review sheet's timeline geometry. All over the shared
/// Glastonbury fixture — no simulator, no SwiftData.
final class FestivalTaggingTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()

    private func set(_ artist: String) -> FestivalSet {
        pack.allSets.first { $0.artist == artist }!
    }

    /// A stamp at festival-local time (+01:00), matching the fixture's clock.
    private func stamp(_ id: UUID = UUID(), _ local: String, duration: Double? = nil) -> ClipStamp {
        ClipStamp(id: id.uuidString, captureDate: FestivalFixtures.date(local), duration: duration)
    }

    // MARK: - Media → ClipStamp (the #283 adaptation)

    func testStampsMapOffsetOntoSessionStartAndDropReels() {
        let start = FestivalFixtures.date("2026-06-27T20:00")
        let a = UUID(), b = UUID(), reel = UUID()
        let stamps = FestivalTagging.stamps(for: [
            .init(mediaID: a, offsetSec: 600, durationSec: 20, isReel: false),
            .init(mediaID: reel, offsetSec: 700, durationSec: 30, isReel: true),
            .init(mediaID: b, offsetSec: -5, durationSec: nil, isReel: false),  // clamped ≥ 0
        ], sessionStart: start)

        XCTAssertEqual(stamps.count, 2, "posted reels are not festival footage")
        XCTAssertEqual(stamps[0].id, a.uuidString)
        XCTAssertEqual(stamps[0].captureDate, start.addingTimeInterval(600))
        XCTAssertEqual(stamps[0].duration, 20)
        XCTAssertEqual(stamps[1].captureDate, start, "negative offsets pin to session start")
    }

    // MARK: - The plan (auto vs ask, sticky rows, stale removal)

    func testHighConfidenceAssignmentBecomesASilentUpsert() {
        let id = UUID()
        let clips = [stamp(id, "2026-06-27T20:30")]   // mid Little Simz, one stage live
        let assignments = FestivalSetMatcher.assignments(for: clips, in: pack)
        let plan = FestivalTagging.plan(assignments: assignments, existing: [])

        XCTAssertEqual(plan.upserts.count, 1)
        XCTAssertEqual(plan.upserts.first?.mediaID, id)
        XCTAssertEqual(plan.upserts.first?.set.artist, "Little Simz")
        XCTAssertEqual(plan.upserts.first?.reason, "mid-set")
        XCTAssertTrue(plan.reviewMediaIDs.isEmpty)
        XCTAssertTrue(plan.staleMediaIDs.isEmpty)
        XCTAssertGreaterThanOrEqual(plan.upserts.first!.confidence,
                                    FestivalSetMatcher.autoTagThreshold)
    }

    func testBelowThresholdQueuesForReviewAndNeverUpserts() {
        let gap = UUID(), twoLive = UUID()
        let clips = [stamp(gap, "2026-06-27T21:40"),        // Simz→Fred gap
                     stamp(twoLive, "2026-06-27T23:35")]    // Overmono × Fred × Prydz live
        let assignments = FestivalSetMatcher.assignments(for: clips, in: pack)
        let plan = FestivalTagging.plan(assignments: assignments, existing: [])

        XCTAssertTrue(plan.upserts.isEmpty)
        XCTAssertEqual(Set(plan.reviewMediaIDs), [gap, twoLive])
    }

    func testOutsideScheduleClipIsNeitherUpsertNorReview() {
        let id = UUID()
        let clips = [stamp(id, "2026-06-27T09:00")]         // hours before the first set
        let plan = FestivalTagging.plan(
            assignments: FestivalSetMatcher.assignments(for: clips, in: pack), existing: [])
        XCTAssertTrue(plan.upserts.isEmpty)
        XCTAssertTrue(plan.reviewMediaIDs.isEmpty, "campsite footage is nobody's homework")
    }

    func testStickyUserRowIsNeverTouched() {
        let id = UUID()
        let clips = [stamp(id, "2026-06-27T20:30")]         // would auto-tag Little Simz
        let assignments = FestivalSetMatcher.assignments(for: clips, in: pack)
        // The user already overrode this clip to Fred again..
        let plan = FestivalTagging.plan(assignments: assignments, existing: [
            .init(mediaID: id, setID: set("Fred again..").id, source: .user),
        ])
        XCTAssertTrue(plan.upserts.isEmpty, "a user decision outranks the matcher forever")
        XCTAssertTrue(plan.reviewMediaIDs.isEmpty)
        XCTAssertTrue(plan.staleMediaIDs.isEmpty)
    }

    func testNoneRowSuppressesReQueueing() {
        let id = UUID()
        let clips = [stamp(id, "2026-06-27T21:40")]         // gap clip → would queue
        let plan = FestivalTagging.plan(
            assignments: FestivalSetMatcher.assignments(for: clips, in: pack),
            existing: [.init(mediaID: id, setID: UUID(), source: .none)])
        XCTAssertTrue(plan.reviewMediaIDs.isEmpty, "'not from a set' is a resolution, not a snooze")
    }

    func testWeakenedAutoRowGoesStale() {
        let id = UUID()
        // Evidence weakened: the clip now sits in a gap (e.g. the row was written before a lineup
        // revision moved the set) — its old auto row must be removed, not left lying.
        let plan = FestivalTagging.plan(
            assignments: FestivalSetMatcher.assignments(for: [stamp(id, "2026-06-27T21:40")], in: pack),
            existing: [.init(mediaID: id, setID: set("Little Simz").id, source: .auto)])
        XCTAssertEqual(plan.staleMediaIDs, [id])
        XCTAssertEqual(plan.reviewMediaIDs, [id], "the clip still deserves a review row")
    }

    func testOrphanedAutoRowGoesStaleButStickyRowsStay() {
        let gone = UUID(), goneButUser = UUID()
        let plan = FestivalTagging.plan(assignments: [], existing: [
            .init(mediaID: gone, setID: set("Little Simz").id, source: .auto),
            .init(mediaID: goneButUser, setID: set("Little Simz").id, source: .user),
        ])
        XCTAssertEqual(plan.staleMediaIDs, [gone], "deleted media loses its auto tag; user rows stay")
    }

    func testPlanIsIdempotentAcrossPasses() {
        let id = UUID()
        let clips = [stamp(id, "2026-06-27T20:30")]
        let assignments = FestivalSetMatcher.assignments(for: clips, in: pack)
        let first = FestivalTagging.plan(assignments: assignments, existing: [])
        // Second pass: the store now holds the auto row the first pass wrote.
        let second = FestivalTagging.plan(assignments: assignments, existing: [
            .init(mediaID: id, setID: first.upserts[0].set.id, source: .auto),
        ])
        XCTAssertEqual(second.upserts, first.upserts, "same evidence → same write, no churn")
        XCTAssertTrue(second.staleMediaIDs.isEmpty)
    }

    // MARK: - Captions, candidates, labels (the review sheet's vocabulary)

    func testCaptionsMatchTheWireframeVocabulary() {
        let simz = set("Little Simz"), fred = set("Fred again..")
        XCTAssertEqual(FestivalTagging.caption(for: .withinSet), "mid-set")
        XCTAssertEqual(FestivalTagging.caption(for: .betweenSets(before: simz, after: fred)),
                       "between stages")
        XCTAssertEqual(FestivalTagging.caption(for: .multipleStagesLive([simz, fred])),
                       "two sets live")
        XCTAssertEqual(FestivalTagging.caption(for: .outsideSchedule), "off the schedule")
    }

    func testCandidatesComeFromTheAssignmentsOwnEvidence() {
        let gapAssignment = FestivalSetMatcher.assignment(
            for: stamp(UUID(), "2026-06-27T21:40"), days: pack.days,
            utcOffsetSeconds: pack.utcOffsetSeconds)
        let gapCandidates = FestivalTagging.candidates(for: gapAssignment)
        XCTAssertEqual(gapCandidates.map(\.artist), ["Little Simz", "Fred again.."],
                       "a gap offers its two neighbours, start-ordered, deduped")

        let multiAssignment = FestivalSetMatcher.assignment(
            for: stamp(UUID(), "2026-06-27T23:35"), days: pack.days,
            utcOffsetSeconds: pack.utcOffsetSeconds)
        let multi = FestivalTagging.candidates(for: multiAssignment)
        XCTAssertEqual(Set(multi.map(\.artist)), ["Fred again..", "Overmono", "Eric Prydz"],
                       "every live set is offerable")
        XCTAssertEqual(multi.count, Set(multi.map(\.id)).count, "candidates are deduped")
        XCTAssertNotNil(FestivalTagging.alternativeLabel(for: multiAssignment))
        XCTAssertNil(FestivalTagging.alternativeLabel(for: gapAssignment),
                     "gap rows caption their reason instead")
    }

    func testSummaryLine() {
        XCTAssertEqual(FestivalTagging.summaryLine(clipCount: 11, autoCount: 8, needsYouCount: 3),
                       "11 clips · 8 auto-tagged · 3 need you")
        XCTAssertEqual(FestivalTagging.summaryLine(clipCount: 1, autoCount: 1, needsYouCount: 0),
                       "1 clip · 1 auto-tagged")
    }

    func testPercentLabelRounds() {
        XCTAssertEqual(FestivalTagging.percentLabel(0.618), "62%")
        XCTAssertEqual(FestivalTagging.percentLabel(0.97), "97%")
    }

    // MARK: - Rollover-aware day label

    func testPosterWeekdayRollsOverAtSix() {
        // 2026-06-27 is a Saturday. A 01:00 Sunday clip is still Saturday's night; 07:00 is Sunday.
        XCTAssertEqual(FestivalTagging.posterWeekday(
            for: FestivalFixtures.date("2026-06-27T22:15"), utcOffsetSeconds: 3600), "Saturday")
        XCTAssertEqual(FestivalTagging.posterWeekday(
            for: FestivalFixtures.date("2026-06-28T01:30"), utcOffsetSeconds: 3600), "Saturday")
        XCTAssertEqual(FestivalTagging.posterWeekday(
            for: FestivalFixtures.date("2026-06-28T07:00"), utcOffsetSeconds: 3600), "Sunday")
    }

    // MARK: - Timeline geometry (frame 9)

    func testTimelineLayoutPositionsBlocksAndTicks() {
        let sets = pack.days[0].allSets
        let needy = UUID(), fine = UUID()
        let layout = FestivalTagTimeline.layout(
            sets: sets,
            stamps: [stamp(fine, "2026-06-27T20:30"), stamp(needy, "2026-06-27T21:40")],
            needsYou: [needy])

        XCTAssertEqual(layout.blocks.count, sets.count)
        // Blocks are start-ordered; every fraction is inside [0, 1] and widths are positive.
        XCTAssertEqual(layout.blocks.first?.artist, "Little Simz")
        XCTAssertEqual(layout.blocks.last?.artist, "Jayda G")
        for block in layout.blocks {
            XCTAssertGreaterThanOrEqual(block.x, 0)
            XCTAssertLessThanOrEqual(block.x + block.width, 1.0001)
            XCTAssertGreaterThan(block.width, 0)
        }
        // Ticks: chronological order maps to increasing x; the needs-you flag sticks.
        XCTAssertEqual(layout.ticks.count, 2)
        let tickByID = Dictionary(uniqueKeysWithValues: layout.ticks.map { ($0.mediaID, $0) })
        XCTAssertLessThan(tickByID[fine]!.x, tickByID[needy]!.x)
        XCTAssertTrue(tickByID[needy]!.needsYou)
        XCTAssertFalse(tickByID[fine]!.needsYou)
    }

    func testTimelineLayoutIsEmptyWithoutSets() {
        XCTAssertEqual(FestivalTagTimeline.layout(sets: [], stamps: [stamp(UUID(), "2026-06-27T20:30")],
                                                  needsYou: []),
                       FestivalTagTimeline.Layout())
    }
}
