import XCTest
@testable import Snappet

/// Prompt 173 — the grid's months summarise themselves (sessions · sends · peak HR), know which days you trained,
/// and covers label their video length.
final class ClipGridModelTests: XCTestCase {

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func post(_ id: String, session: UUID, day: Int, month: Int = 10, sent: Bool = false) -> ClipFeedPost {
        let date = cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: 18))!
        var p = ClipFeedPost(id: id, sessionID: session, kind: .kilter, moduleID: "kilter", discipline: .climbing,
                             title: id, subtitle: "", overlayDetail: "", climbUUID: nil, exerciseID: nil,
                             captureAt: date, sessionStartedAt: date, sessionEndedAt: nil, isFromAppleWatch: false,
                             clips: [], aspect: ClipFeedComposer.defaultAspect)
        if sent { p.climbResult = .init(status: .sent, attempts: 2) }
        return p
    }

    func testMonthSummaryDaysAndPeak() throws {
        let a = UUID(), b = UUID()
        let posts = [post("x", session: a, day: 7, sent: true), post("y", session: a, day: 7),
                     post("z", session: b, day: 2, sent: true), post("old", session: UUID(), day: 30, month: 9)]
        let peaks: [String: Double] = ["x": 171.4, "z": 178.6]
        let months = ClipGridModel.months(posts, peak: { peaks[$0.id] }, calendar: cal,
                                          locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(months.map(\.title), ["October 2026", "September 2026"])
        let oct = try XCTUnwrap(months.first)
        XCTAssertEqual(oct.sessions, 2)
        XCTAssertEqual(oct.sends, 2)
        XCTAssertEqual(oct.peakHR, 179)
        XCTAssertEqual(oct.summary, "2 sessions · 2 sends · peak 179")
        XCTAssertEqual(oct.postsByDay, [7: 2, 2: 1])
        XCTAssertEqual(oct.daysInMonth, 31)
        XCTAssertEqual(oct.firstPost(onDay: 2, calendar: cal)?.id, "z")
        XCTAssertNil(oct.firstPost(onDay: 3, calendar: cal))
        XCTAssertEqual(oct.interval.start, cal.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        XCTAssertEqual(months[1].summary, "1 session")                 // no sends, no HR → just sessions
    }

    func testDayLevelsAndDurations() {
        XCTAssertEqual([0, 1, 2, 3, 4, 9].map(ClipGridModel.dayLevel), [0, 1, 2, 2, 3, 3])
        XCTAssertEqual(ClipGridModel.durationLabel(24.4), "0:24")
        XCTAssertEqual(ClipGridModel.durationLabel(65), "1:05")
        XCTAssertNil(ClipGridModel.durationLabel(nil))
        XCTAssertNil(ClipGridModel.durationLabel(0.2))
    }
}
