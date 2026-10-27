import XCTest
@testable import Snappet

/// Charts spaced by session (2026-10-26): a tournament day's sessions are "24 Oct · 1/2/3", not 11 AM / 2 PM / 5 PM.
final class ActivityDashboardAxisTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func d(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private func label(_ x: Date) -> String { "\(cal.component(.day, from: x)) Oct" }

    func testSameDaySessionsAreNumbered() {
        let l = ActivityDashboard.sessionAxisLabels([d(20, 9), d(24, 8), d(24, 16), d(24, 17)], calendar: cal, day: label)
        XCTAssertEqual(l, [0: "20 Oct", 1: "24 Oct · 1", 2: "24 Oct · 2", 3: "24 Oct · 3"])
    }

    func testManySessionsGetAFewEvenLabelsIncludingFirstAndLast() {
        let dates = (1...10).map { d($0, 12) }
        let l = ActivityDashboard.sessionAxisLabels(dates, calendar: cal, day: label)
        XCTAssertEqual(l.keys.sorted(), [0, 3, 6, 9])
        XCTAssertEqual(l[9], "10 Oct")
        XCTAssertEqual(ActivityDashboard.sessionAxisLabels([], calendar: cal, day: label), [:])
    }
}
