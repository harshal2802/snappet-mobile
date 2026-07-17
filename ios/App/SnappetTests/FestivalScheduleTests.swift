import XCTest
@testable import Snappet

/// The pure schedule derivation behind the day-schedule screen (festival prompt 02, wireframe
/// frame 4): day tabs, row states, ★/clash marks, the "I'm here" candidate, up next, and the
/// festival-local labels. All against the shared Glastonbury fixture (BST, +01:00).
final class FestivalScheduleTests: XCTestCase {
    private let pack = FestivalFixtures.glastonbury()

    // MARK: - Day tabs

    func testDayTabsAreFestivalLocalWeekdayAndDayNumber() {
        let tabs = FestivalSchedule.dayTabs(for: pack)
        XCTAssertEqual(tabs.map(\.date), ["2026-06-27", "2026-06-28"])
        XCTAssertEqual(tabs.map(\.weekday), ["SAT", "SUN"])
        XCTAssertEqual(tabs.map(\.dayNumber), ["27", "28"])
    }

    func testDefaultDayIsTheOneContainingNow() {
        // 01:30 Sunday morning still belongs to the SATURDAY poster day (06:00 rollover).
        let lateNight = FestivalFixtures.date("2026-06-28T01:30")
        XCTAssertEqual(FestivalSchedule.defaultDayDate(in: pack, now: lateNight), "2026-06-27")
    }

    func testDefaultDayBeforeTheFestivalIsDayOneAndAfterIsTheLastDay() {
        XCTAssertEqual(FestivalSchedule.defaultDayDate(
            in: pack, now: FestivalFixtures.date("2026-06-20T12:00")), "2026-06-27")
        XCTAssertEqual(FestivalSchedule.defaultDayDate(
            in: pack, now: FestivalFixtures.date("2026-07-04T12:00")), "2026-06-28")
    }

    // MARK: - Rows

    func testStageGroupsCarryPastNowAndUpcomingStates() {
        // 22:37 Saturday (the wireframe's moment): Little Simz done, Fred live, Overmono upcoming.
        let now = FestivalFixtures.date("2026-06-27T22:37")
        let groups = FestivalSchedule.stageGroups(for: "2026-06-27", in: pack, starred: [], now: now)
        XCTAssertEqual(groups.map(\.stage), ["Pyramid Stage", "West Holts", "Arcadia"])

        let pyramid = groups[0].rows
        XCTAssertEqual(pyramid.map(\.set.artist), ["Little Simz", "Fred again.."])
        XCTAssertEqual(pyramid[0].state, .past)
        guard case .now(let remaining) = pyramid[1].state else {
            return XCTFail("Fred again.. should be live at 22:37")
        }
        XCTAssertEqual(remaining, 68 * 60, accuracy: 1)   // 22:37 → 23:45

        guard case .upcoming(let startsIn) = groups[1].rows[0].state else {
            return XCTFail("Overmono should be upcoming")
        }
        XCTAssertEqual(startsIn, 53 * 60, accuracy: 1)    // 22:37 → 23:30
    }

    func testStarredOverlapMarksBothRowsAsClashingButUnstarredOverlapDoesNot() {
        let overmono = FestivalFixtures.set(named: "Overmono", in: pack)
        let prydz = FestivalFixtures.set(named: "Eric Prydz", in: pack)
        let jayda = FestivalFixtures.set(named: "Jayda G", in: pack)
        let now = FestivalFixtures.date("2026-06-27T22:37")

        // Overmono ★ + Prydz ★ overlap 23:30–00:30 → both clash; Jayda ★ is back-to-back → clean.
        let starred: Set<UUID> = [overmono.id, prydz.id, jayda.id]
        let rows = FestivalSchedule.stageGroups(for: "2026-06-27", in: pack,
                                                starred: starred, now: now)
            .flatMap(\.rows)
        let byArtist = Dictionary(uniqueKeysWithValues: rows.map { ($0.set.artist, $0) })
        XCTAssertTrue(byArtist["Overmono"]!.clashing)
        XCTAssertTrue(byArtist["Eric Prydz"]!.clashing)
        XCTAssertFalse(byArtist["Jayda G"]!.clashing)
        // Fred overlaps Prydz on the clock but isn't starred — programming, not a clash.
        XCTAssertFalse(byArtist["Fred again.."]!.clashing)
        XCTAssertTrue(byArtist["Overmono"]!.starred)
        XCTAssertFalse(byArtist["Fred again.."]!.starred)
    }

    // MARK: - "I'm here" / up next

    func testLiveSetPrefersStarredThenMostRecentlyStarted() {
        // 23:35 Saturday: Fred (22:15–23:45), Prydz (23:00–00:30), Overmono (23:30–01:00) all live.
        let now = FestivalFixtures.date("2026-06-27T23:35")
        // Unstarred: the most recently started set wins (Overmono, 23:30).
        XCTAssertEqual(FestivalSchedule.liveSet(in: pack, starred: [], now: now)?.artist, "Overmono")
        // A starred live set beats recency.
        let prydz = FestivalFixtures.set(named: "Eric Prydz", in: pack)
        XCTAssertEqual(FestivalSchedule.liveSet(in: pack, starred: [prydz.id], now: now)?.artist,
                       "Eric Prydz")
    }

    func testLiveSetIsNilBetweenSets() {
        // 21:30 Saturday: Simz done (21:15), nothing on until Fred (22:15).
        let now = FestivalFixtures.date("2026-06-27T21:30")
        XCTAssertNil(FestivalSchedule.liveSet(in: pack, starred: [], now: now))
    }

    func testLiveSetsAndUpNext() {
        let now = FestivalFixtures.date("2026-06-27T23:35")
        XCTAssertEqual(FestivalSchedule.liveSets(in: pack, now: now).map(\.artist),
                       ["Fred again..", "Eric Prydz", "Overmono"])
        // Next start after 23:35 is Jayda G at 01:00.
        XCTAssertEqual(FestivalSchedule.upNext(in: pack, now: now)?.artist, "Jayda G")
    }

    // MARK: - Labels

    func testTimeLabelsAreFestivalLocalRegardlessOfPhoneZone() {
        let fred = FestivalFixtures.set(named: "Fred again..", in: pack)
        XCTAssertEqual(FestivalSchedule.timeLabel(fred.start, offsetSeconds: 3600), "22:15")
        // Same instant read with a different offset shifts — proving the label is offset-driven.
        XCTAssertEqual(FestivalSchedule.timeLabel(fred.start, offsetSeconds: 0), "21:15")
    }

    func testCountdownLabels() {
        XCTAssertEqual(FestivalSchedule.startsInLabel(53 * 60), "in 53 min")
        XCTAssertEqual(FestivalSchedule.startsInLabel(90 * 60), "in 1 h 30")
        XCTAssertNil(FestivalSchedule.startsInLabel(3 * 3600), "beyond the 2 h horizon → no badge")
        XCTAssertNil(FestivalSchedule.startsInLabel(-60), "already started → no badge")
        XCTAssertEqual(FestivalSchedule.remainingLabel(46 * 60 + 30), "46 min left")
        XCTAssertEqual(FestivalSchedule.remainingLabel(72 * 60), "1 h 12 left")
        XCTAssertEqual(FestivalSchedule.elapsedLabel(since: Date(timeIntervalSince1970: 0),
                                                     now: Date(timeIntervalSince1970: 44 * 60 + 12)),
                       "44:12")
        XCTAssertEqual(FestivalSchedule.elapsedLabel(since: Date(timeIntervalSince1970: 0),
                                                     now: Date(timeIntervalSince1970: 3727)),
                       "1:02:07")
    }
}
