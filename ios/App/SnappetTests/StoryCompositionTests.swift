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
