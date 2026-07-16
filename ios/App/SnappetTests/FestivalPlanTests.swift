import XCTest
@testable import Snappet

/// The starred-plan interval math (festival prompt 01): clash detection (wireframe frame 4's
/// "⚠︎ clash"), the reminder instants prompt 04 schedules, and the gaps the recommender fills —
/// including sets that cross midnight, which belong to the previous poster day.
final class FestivalPlanTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()

    private func plan(_ artists: String...) -> FestivalPlan {
        FestivalPlan(starredSetIDs: Set(artists.map {
            FestivalFixtures.set(named: $0, in: pack).id
        }))
    }

    // MARK: - Starred sets

    func testStarredSetsResolveChronologically() {
        let starred = plan("Overmono", "Little Simz", "Eric Prydz").starredSets(in: pack)
        XCTAssertEqual(starred.map(\.artist), ["Little Simz", "Eric Prydz", "Overmono"])
    }

    func testStaleStarFromARevisedLineupJustDoesNotResolve() {
        var p = plan("Little Simz")
        p.starredSetIDs.insert(UUID())   // a set id from a pack revision that dropped the set
        XCTAssertEqual(p.starredSets(in: pack).map(\.artist), ["Little Simz"])
        XCTAssertTrue(p.clashes(in: pack).isEmpty)
        XCTAssertEqual(p.reminderDates(in: pack, lead: 900).count, 1)
    }

    func testToggleStarsAndUnstars() {
        var p = FestivalPlan()
        let simz = FestivalFixtures.set(named: "Little Simz", in: pack).id
        p.toggle(simz)
        XCTAssertTrue(p.isStarred(simz))
        p.toggle(simz)
        XCTAssertFalse(p.isStarred(simz))
    }

    func testPlanRoundTripsThroughCodable() throws {
        let p = plan("Overmono", "Eric Prydz")
        let decoded = try JSONDecoder().decode(FestivalPlan.self,
                                               from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
    }

    // MARK: - Clashes (frame 4: "Prydz vs Overmono")

    func testOverlappingStarsClashWithTheOverlapInterval() {
        let clashes = plan("Overmono", "Eric Prydz").clashes(in: pack)
        XCTAssertEqual(clashes.count, 1)
        XCTAssertEqual(clashes[0].first.artist, "Eric Prydz", "earlier-starting set leads the pair")
        XCTAssertEqual(clashes[0].second.artist, "Overmono")
        XCTAssertEqual(clashes[0].overlap,
                       DateInterval(start: FestivalFixtures.date("2026-06-27T23:30"),
                                    end: FestivalFixtures.date("2026-06-28T00:30")))
    }

    func testSequentialStarsDoNotClash() {
        XCTAssertTrue(plan("Little Simz", "Fred again..").clashes(in: pack).isEmpty)
    }

    func testBackToBackStarsDoNotClash() {
        // Overmono ends at 01:00 exactly as Jayda G starts — a handover, not a clash.
        XCTAssertTrue(plan("Overmono", "Jayda G").clashes(in: pack).isEmpty)
    }

    func testThreeWayOverlapReportsEveryPair() {
        let clashes = plan("Fred again..", "Overmono", "Eric Prydz").clashes(in: pack)
        XCTAssertEqual(clashes.map { "\($0.first.artist)×\($0.second.artist)" },
                       ["Fred again..×Eric Prydz", "Fred again..×Overmono", "Eric Prydz×Overmono"])
    }

    // MARK: - Reminders (prompt 04 hands these to UNUserNotificationCenter)

    func testReminderDatesFireLeadSecondsBeforeEachStar() {
        let reminders = plan("Overmono", "Little Simz").reminderDates(in: pack, lead: 15 * 60)
        XCTAssertEqual(reminders.map(\.set.artist), ["Little Simz", "Overmono"])
        XCTAssertEqual(reminders[0].fireDate, FestivalFixtures.date("2026-06-27T19:45"))
        XCTAssertEqual(reminders[1].fireDate, FestivalFixtures.date("2026-06-27T23:15"))
    }

    func testMidnightCrossingSetRemindsOnItsRealNight() {
        // Jayda G starts 01:00 calendar-Sunday; the reminder is 00:45 that same night.
        let reminders = plan("Jayda G").reminderDates(in: pack, lead: 15 * 60)
        XCTAssertEqual(reminders[0].fireDate, FestivalFixtures.date("2026-06-28T00:45"))
    }

    // MARK: - Gaps (what the recommender fills)

    func testGapsBetweenConsecutiveStarsWithinADay() {
        // Simz → Fred leaves 21:15–22:15; Fred → Jayda leaves 23:45–01:00 (crossing midnight, still
        // poster-Saturday). Both are Saturday gaps.
        let gaps = plan("Little Simz", "Fred again..", "Jayda G").gaps(in: pack)
        XCTAssertEqual(gaps, [
            DateInterval(start: FestivalFixtures.date("2026-06-27T21:15"),
                         end: FestivalFixtures.date("2026-06-27T22:15")),
            DateInterval(start: FestivalFixtures.date("2026-06-27T23:45"),
                         end: FestivalFixtures.date("2026-06-28T01:00")),
        ])
    }

    func testBackToBackAndClashingStarsLeaveNoGap() {
        XCTAssertTrue(plan("Overmono", "Jayda G").gaps(in: pack).isEmpty)
        XCTAssertTrue(plan("Eric Prydz", "Overmono").gaps(in: pack).isEmpty)
    }

    func testGapsNeverSpanFestivalDays() {
        // Fred again.. (Saturday) → Four Tet (Sunday): the overnight stretch is not a "gap" to fill.
        XCTAssertTrue(plan("Fred again..", "Four Tet").gaps(in: pack).isEmpty)
    }

    func testSingleStarHasNoGaps() {
        XCTAssertTrue(plan("Little Simz").gaps(in: pack).isEmpty)
    }
}
