import XCTest
@testable import Snappet

/// The night-aware festival clock + running-order rows (prompt 232): every time editor treats a time
/// before the 06:00 rollover as after midnight of that poster day.
final class FestivalClockTests: XCTestCase {

    private let offset = FestivalFixtures.utcOffsetSeconds
    private func at(_ s: String) -> Date { FestivalFixtures.date(s) }

    func testTimesBeforeRolloverAreTheNextMorning() {
        XCTAssertEqual(FestivalClock.date(day: "2026-06-27", hour: 23, minute: 30, offsetSeconds: offset),
                       at("2026-06-27T23:30"))
        XCTAssertEqual(FestivalClock.date(day: "2026-06-27", hour: 1, minute: 0, offsetSeconds: offset),
                       at("2026-06-28T01:00"))
        XCTAssertNil(FestivalClock.date(day: "", hour: 1, minute: 0, offsetSeconds: offset))
    }

    func testPickerValuesReanchorOntoTheDay() {
        // A picker hands back today's date with the chosen time — only hour:minute matter.
        let picked = at("2031-01-05T02:15")
        XCTAssertEqual(FestivalClock.onDay(picked, day: "2026-06-27", offsetSeconds: offset),
                       at("2026-06-28T02:15"))
        let start = at("2026-06-27T23:00")
        XCTAssertEqual(FestivalClock.end(at("2031-01-05T00:30"), after: start, day: "2026-06-27",
                                         offsetSeconds: offset), at("2026-06-28T00:30"))
        // 05:00 → 07:00 crosses the rollover and still ends after it starts.
        let early = at("2026-06-28T05:00")
        XCTAssertEqual(FestivalClock.end(at("2031-01-05T07:00"), after: early, day: "2026-06-27",
                                         offsetSeconds: offset), at("2026-06-28T07:00"))
    }

    func testLabels() {
        XCTAssertEqual(FestivalClock.hhmm(at("2026-06-28T01:05"), offsetSeconds: offset), "01:05")
        XCTAssertEqual(FestivalClock.durationLabel(5400), "1 h 30")
        XCTAssertEqual(FestivalClock.durationLabel(2700), "45 min")
        XCTAssertEqual(FestivalClock.durationLabel(7200), "2 h")
    }

    func testAddAnotherArtistChainsBackToBackWithTheSameLength() {
        let first = FestivalSetRow.next(after: [], fallback: at("2026-06-27T18:00"))
        XCTAssertEqual(first.start, at("2026-06-27T18:00"))
        XCTAssertEqual(first.end, at("2026-06-27T19:00"))
        let long = FestivalSetRow(artist: "A", start: at("2026-06-27T22:00"), end: at("2026-06-27T23:30"))
        let next = FestivalSetRow.next(after: [first, long], fallback: .now)
        XCTAssertEqual(next.start, at("2026-06-27T23:30"), "starts when the latest set ends")
        XCTAssertEqual(next.end, at("2026-06-28T01:00"), "same length as it")
    }

    func testClashesFlagOverlapsButNotBackToBack() {
        let a = FestivalSetRow(artist: "A", start: at("2026-06-27T20:00"), end: at("2026-06-27T21:00"))
        let b = FestivalSetRow(artist: "B", start: at("2026-06-27T21:00"), end: at("2026-06-27T22:00"))
        let c = FestivalSetRow(artist: "C", start: at("2026-06-27T21:30"), end: at("2026-06-27T22:30"))
        let blank = FestivalSetRow(artist: " ", start: at("2026-06-27T20:00"), end: at("2026-06-27T23:00"))
        XCTAssertEqual(FestivalSetRow.clashing([a, b, blank]), [], "back-to-back is fine; blank rows don't count")
        XCTAssertEqual(FestivalSetRow.clashing([a, b, c]), [b.id, c.id])
        let existing = FestivalSet(artist: "On already", start: at("2026-06-27T20:30"), end: at("2026-06-27T21:30"))
        XCTAssertEqual(FestivalSetRow.clashing([a], existing: [existing]), [a.id])
    }

    func testDraftTimesAfterMidnightValidate() throws {
        var draft = FestivalDraft.blank(now: at("2026-06-27T12:00"), timeZone: TimeZone(secondsFromGMT: offset)!)
        draft.name = "Late Night"
        draft.days[0].stages[0].sets = [
            .init(artist: "Late", start: "23:30", end: "01:00"),
            .init(artist: "Later", start: "01:00", end: "02:30"),
        ]
        let pack = draft.toPack()
        XCTAssertNoThrow(try FestivalPackValidator.validate(pack), "a 01:00 start is the next morning")
        XCTAssertEqual(pack.allSets.first { $0.artist == "Later" }?.start, at("2026-06-28T01:00"))
    }
}
