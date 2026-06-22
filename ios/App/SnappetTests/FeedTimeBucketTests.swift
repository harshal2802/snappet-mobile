import XCTest
@testable import Snappet

/// The scroll date-bar orientation guard (F8). Pins en_US + UTC so weekday/month strings are
/// deterministic; "now" is fixed at Sun Jun 21 2026.
final class FeedTimeBucketTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US")
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: day, hour: 12))!
    }
    private var now: Date { d(2026, 6, 21) }   // Sunday

    private func era(_ date: Date) -> String { FeedTimeBucket.era(for: date, now: now, calendar: cal) }

    func testToday() { XCTAssertEqual(era(d(2026, 6, 21)), "Today") }
    func testFutureClampsToToday() { XCTAssertEqual(era(d(2026, 6, 25)), "Today") }
    func testYesterday() { XCTAssertEqual(era(d(2026, 6, 20)), "Yesterday") }

    func testThisWeek() {
        XCTAssertEqual(era(d(2026, 6, 19)), "This week")   // 2 days
        XCTAssertEqual(era(d(2026, 6, 17)), "This week")   // 4 days
        XCTAssertEqual(era(d(2026, 6, 15)), "This week")   // 6 days (boundary)
    }

    func testEarlierInCurrentMonth() {
        XCTAssertEqual(era(d(2026, 6, 14)), "Earlier in June")   // 7 days, still this calendar month
        XCTAssertEqual(era(d(2026, 6, 1)), "Earlier in June")
    }

    func testOlderMonthSameYear() {
        XCTAssertEqual(era(d(2026, 5, 24)), "May 2026")
        XCTAssertEqual(era(d(2026, 1, 3)), "January 2026")
    }

    func testPriorYear() {
        XCTAssertEqual(era(d(2025, 12, 31)), "December 2025")
        XCTAssertEqual(era(d(2024, 7, 9)), "July 2024")
    }

    func testDayLine() {
        XCTAssertEqual(FeedTimeBucket.day(for: d(2026, 6, 17), calendar: cal), "Wed · Jun 17")
        XCTAssertEqual(FeedTimeBucket.day(for: d(2026, 5, 24), calendar: cal), "Sun · May 24")
    }

    func testFullLabel() {
        let l = FeedTimeBucket.label(for: d(2026, 5, 24), now: now, calendar: cal)
        XCTAssertEqual(l.era, "May 2026")
        XCTAssertEqual(l.day, "Sun · May 24")
    }
}
