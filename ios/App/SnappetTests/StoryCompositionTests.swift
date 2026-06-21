import XCTest
@testable import Snappet

/// F6: pure Story composition — 3..8 clamp, Year-in-Climb arc order, rail eligibility (degrade-by-absence).
final class StoryCompositionTests: XCTestCase {

    private func card(_ kind: FeedCardKind, _ salience: Double) -> FeedCard {
        FeedCard(id: kind.rawValue, contentId: "c", kind: kind, category: .trend, salience: salience,
                 anchorDate: Date(), sourceRefs: [], payload: .streak(StreakPayload(days: 3, weeks: 0)))
    }

    func testSparseClampsToThree() {
        let scenes = StoryComposition.scenes(periodTitle: "This Week", sessionCount: 1, cards: [])
        XCTAssertEqual(scenes.count, 3, "cover + padded closers reach the 3-scene floor")
        XCTAssertEqual(scenes.first?.id, "cover")
    }

    func testRichClampsToEight() {
        let kinds: [FeedCardKind] = [.b1GradePR, .c1Pyramid, .b3MostClimbs, .d1WeeklyVolume, .b5Streak, .e1Effort, .e3HRTrend, .b4LiftPR]
        let scenes = StoryComposition.scenes(periodTitle: "Year in Climb", sessionCount: 48, cards: kinds.map { card($0, 0.5) })
        XCTAssertEqual(scenes.count, 8, "cover + 7 highlights, clamped at 8")
    }

    func testArcOrderPRBeforePyramidBeforeStreak() {
        let scenes = StoryComposition.scenes(periodTitle: "X", sessionCount: 5,
                                             cards: [card(.b5Streak, 0.8), card(.b1GradePR, 1.0), card(.c1Pyramid, 0.6)])
        XCTAssertEqual(scenes.dropFirst().compactMap { $0.card?.kind }, [.b1GradePR, .c1Pyramid, .b5Streak])
    }

    func testArcOrderIncludesAllF6FollowOnKinds() {
        // Scrambled input across the new F6 tiers; expect ascending arc rank in the output.
        // ranks: g1=0, b2=1, c3=2, c2=3, d4=5, c5=6, consistencyMap=7 → 7 cards fit under the 8-scene budget.
        let scrambled: [FeedCardKind] = [.consistencyMap, .g1ProjectSent, .c5AngleDist, .b2FirstAtGrade,
                                         .d4TrendArrows, .c3Progression, .c2PyramidHealth]
        let scenes = StoryComposition.scenes(periodTitle: "Year in Climb", sessionCount: 40,
                                             cards: scrambled.map { card($0, 0.5) })
        XCTAssertEqual(scenes.dropFirst().compactMap { $0.card?.kind },
                       [.g1ProjectSent, .b2FirstAtGrade, .c3Progression, .c2PyramidHealth,
                        .d4TrendArrows, .c5AngleDist, .consistencyMap])
    }

    func testArcWithinRankBreaksTieBySalienceThenEffortTail() {
        // Three effort cards: e4 (rank 8, salience .62) and e1 (rank 8, salience .55) tie on rank →
        // higher salience first; e3 is rank 9 so it always trails both.
        let scenes = StoryComposition.scenes(periodTitle: "X", sessionCount: 5,
                                             cards: [card(.e3HRTrend, 0.9), card(.e1Effort, 0.55), card(.e4EffortEfficiency, 0.62)])
        XCTAssertEqual(scenes.dropFirst().compactMap { $0.card?.kind }, [.e4EffortEfficiency, .e1Effort, .e3HRTrend],
                       "within rank 8 salience wins (e4 > e1); rank 9 (e3) trails despite its higher salience")
    }

    func testEffortAndMemoryTiersAreClippedFirstWhenOverBudget() {
        // 9 highlights > 7-slot budget. restNudge (rank 8) and onThisDay (rank 10) are the lowest in the
        // arc, so they're the two dropped — the story leads with milestones, not nudges.
        let kinds: [FeedCardKind] = [.b1GradePR, .b4LiftPR, .c3Progression, .c1Pyramid, .b3MostClimbs,
                                     .d1WeeklyVolume, .c5AngleDist, .restNudge, .onThisDay]
        let scenes = StoryComposition.scenes(periodTitle: "Year in Climb", sessionCount: 50,
                                             cards: kinds.map { card($0, 0.5) })
        let shown = scenes.dropFirst().compactMap { $0.card?.kind }
        XCTAssertEqual(scenes.count, 8, "cover + 7 highlights")
        XCTAssertFalse(shown.contains(.restNudge), "a rest nudge never outranks a milestone in the recap")
        XCTAssertFalse(shown.contains(.onThisDay), "memory tier is last and clipped when over budget")
    }

    func testRailEligibilityDegradesByAbsence() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 20))!
        let eightMonthsAgo = cal.date(byAdding: .month, value: -8, to: now)!

        let all = StoryComposition.eligiblePeriods(sessionDates: [now, eightMonthsAgo], now: now, calendar: cal)
        XCTAssertEqual(all, [.week, .month, .year])

        let onlyOld = StoryComposition.eligiblePeriods(sessionDates: [eightMonthsAgo], now: now, calendar: cal)
        XCTAssertFalse(onlyOld.contains(.week)); XCTAssertFalse(onlyOld.contains(.month)); XCTAssertTrue(onlyOld.contains(.year))

        XCTAssertTrue(StoryComposition.eligiblePeriods(sessionDates: [], now: now, calendar: cal).isEmpty)
    }
}
