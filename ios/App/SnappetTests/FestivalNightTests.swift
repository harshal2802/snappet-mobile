import XCTest
@testable import Snappet

/// The night (prompt 232) — the Halloween fix: a claim ends with its set, then carries on to the
/// next starred set or asks "Where are you now?" with the running-late sets included.
final class FestivalNightTests: XCTestCase {

    private let pack = FestivalFixtures.glastonbury()
    private func set(_ name: String) -> FestivalSet { FestivalFixtures.set(named: name, in: pack) }
    private func at(_ local: String) -> Date { FestivalFixtures.date(local) }

    func testClaimEndsWithItsSet() {
        let fred = set("Fred again..")
        XCTAssertFalse(FestivalNight.claimHasEnded(set: fred, claimedAt: fred.start, now: fred.end - 1))
        XCTAssertTrue(FestivalNight.claimHasEnded(set: fred, claimedAt: fred.start, now: fred.end))
        XCTAssertFalse(FestivalNight.claimHasEnded(set: fred, claimedAt: fred.end + 300, now: fred.end + 600),
                       "a claim made after the scheduled end is a running-late set — leave it")
    }

    func testOutcomeMovesToTheNextStarredSet() {
        let fred = set("Fred again..")       // ends 23:45
        let overmono = set("Overmono")       // 23:30–01:00 (playing at 23:45)
        let jayda = set("Jayda G")           // 01:00
        XCTAssertEqual(FestivalNight.outcome(after: fred, in: pack, starred: [overmono.id, jayda.id]),
                       .moveTo(overmono))
    }

    func testOutcomeAsksWhenNothingStarredIsNext() {
        let simz = set("Little Simz")        // ends 21:15; Fred starts 22:15 (> 30 min)
        XCTAssertEqual(FestivalNight.outcome(after: simz, in: pack, starred: [set("Fred again..").id]),
                       .ask)
        XCTAssertEqual(FestivalNight.outcome(after: simz, in: pack, starred: []), .ask)
    }

    func testOutcomePrefersTheSameStageOnATie() {
        let overmono = set("Overmono")       // West Holts, ends 01:00
        let jayda = set("Jayda G")           // West Holts, 01:00
        var edits = FestivalLineupEdits()
        let other = edits.add(artist: "Other", stage: "Arcadia", start: jayda.start, end: jayda.end,
                              festivalID: pack.id)
        let edited = edits.apply(to: pack)
        XCTAssertEqual(FestivalNight.outcome(after: overmono, in: edited, starred: [jayda.id, other]),
                       .moveTo(jayda))
    }

    func testWhereOptionsIncludeRunningLateAndUpNext() {
        let now = at("2026-06-27T23:50")
        let o = FestivalNight.whereOptions(in: pack, starred: [set("Overmono").id],
                                           excluding: set("Eric Prydz").id, now: now)
        XCTAssertEqual(o.onNow.map(\.artist), ["Overmono"], "starred first; the current set left out")
        XCTAssertEqual(o.runningLate.map(\.artist), ["Fred again.."], "ended 5 min ago — running late?")
        XCTAssertEqual(o.upNext.map(\.artist), ["Jayda G"])
    }

    func testStatus() {
        let id = UUID()
        XCTAssertEqual(FestivalNight.status(.init(nightOn: false)), .off)
        XCTAssertEqual(FestivalNight.status(.init(nightOn: true, openSetID: id)), .atSet(id))
        let t = at("2026-06-27T22:00")
        XCTAssertEqual(FestivalNight.status(.init(nightOn: true, openStretch: (.rest, t))),
                       .stretch(.rest, since: t))
        XCTAssertEqual(FestivalNight.status(.init(nightOn: true, lastClosedAt: t, nightStartedAt: t - 600)),
                       .between(since: t))
        XCTAssertEqual(FestivalNight.status(.init(nightOn: true, nightStartedAt: t)), .between(since: t))
    }

    func testStillOutAndAbandoned() {
        let t = at("2026-06-27T22:00")
        let between = FestivalNight.Status.between(since: t)
        XCTAssertFalse(FestivalNight.isStillOut(between, now: t + 3600))
        XCTAssertTrue(FestivalNight.isStillOut(between, now: t + 2 * 3600))
        XCTAssertTrue(FestivalNight.isStillOut(.stretch(.rest, since: t), now: t + 3 * 3600))
        XCTAssertFalse(FestivalNight.isStillOut(.atSet(UUID()), now: t + 9 * 3600))
        XCTAssertFalse(FestivalNight.isAbandoned(between, now: t + 5 * 3600))
        XCTAssertTrue(FestivalNight.isAbandoned(between, now: t + 6 * 3600))
        XCTAssertFalse(FestivalNight.isAbandoned(.stretch(.rest, since: t), now: t + 9 * 3600),
                       "a break the user told us about is never auto-ended")
    }

    func testSetEndNotificationCopy() {
        let fred = set("Fred again..")
        let ask = FestivalNotifications.setEndContent(ended: fred, next: nil)
        XCTAssertEqual(ask.title, "Fred again.. ended")
        XCTAssertTrue(ask.body.contains("Where are you now?"))
        let moved = FestivalNotifications.setEndContent(ended: fred, next: set("Overmono"))
        XCTAssertEqual(moved.body, "Moved you to ★ Overmono · West Holts. Not there? Tap to change.")
    }

    func testTimelineLanesStackOverlappingSets() {
        let sat = pack.days[0].allSets
        let layout = FestivalTagTimeline.layout(sets: sat, stamps: [], needsYou: [])
        XCTAssertEqual(layout.laneCount, 3, "Eric Prydz overlaps Fred and Overmono")
        // No two blocks in a lane overlap.
        for lane in 0..<layout.laneCount {
            let blocks = layout.blocks.filter { $0.lane == lane }.sorted { $0.x < $1.x }
            for (a, b) in zip(blocks, blocks.dropFirst()) {
                XCTAssertLessThanOrEqual(a.x + a.width, b.x + 1e-9)
            }
        }
    }
}
