import XCTest
@testable import Snappet

/// Prompt 212: the pure pieces behind Home's links — History's date window and the activity feed's collapsing.
final class HomeLinksTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        c.firstWeekday = 1
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testWeekContainingNowIsThisWeek() {
        let now = date(2026, 10, 29)
        let r = HistoryDateRange.week(containing: now, now: now, calendar: cal)
        XCTAssertEqual(r.label, "This week")
        XCTAssertTrue(r.contains(date(2026, 10, 25, 0)), "Sunday start is inside")
        XCTAssertTrue(r.contains(date(2026, 10, 31, 23)))
        XCTAssertFalse(r.contains(date(2026, 11, 1, 0)), "next Sunday is outside")
        XCTAssertFalse(r.contains(date(2026, 10, 24, 23)))
    }

    func testAnEarlierWeekIsNamedByItsStart() {
        let r = HistoryDateRange.week(containing: date(2026, 10, 14), now: date(2026, 10, 29), calendar: cal)
        XCTAssertNotEqual(r.label, "This week")
        XCTAssertTrue(r.label.hasPrefix("Week of"), r.label)
    }

    func testDayIsTodayOrNamed() {
        let now = date(2026, 10, 29)
        let today = HistoryDateRange.day(now, now: now, calendar: cal)
        XCTAssertEqual(today.label, "Today")
        XCTAssertTrue(today.contains(date(2026, 10, 29, 0)))
        XCTAssertFalse(today.contains(date(2026, 10, 30, 0)))
        XCTAssertNotEqual(HistoryDateRange.day(date(2026, 10, 26), now: now, calendar: cal).label, "Today")
    }

    func testFeedCollapsesBackToBackRepeatsOnly() {
        let items = ["kilter", "kilter", "kilter", "gym", "kilter", "gym", "gym"]
        let runs = FeedRuns.collapse(items, limit: 10) { $0 }
        XCTAssertEqual(runs.map(\.first), ["kilter", "gym", "kilter", "gym"])
        XCTAssertEqual(runs.map(\.count), [3, 1, 1, 2])
    }

    func testFeedLimitCountsRunsNotItems() {
        let runs = FeedRuns.collapse(["a", "a", "b", "c", "c", "d"], limit: 2) { $0 }
        XCTAssertEqual(runs.map(\.first), ["a", "b"])
        XCTAssertEqual(runs.map(\.count), [2, 1])
    }
}
