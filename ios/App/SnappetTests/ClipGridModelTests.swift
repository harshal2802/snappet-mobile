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

    // MARK: select mode (prompt 175)

    private func clip(_ kind: String, reel: Bool = false) -> ClipFeedItem {
        var m = MediaInput(id: UUID(), kind: kind, offsetSec: 0, durationSec: 5, exerciseId: nil, setIndex: nil,
                           climbUUID: nil, localIdentifier: "L-\(UUID().uuidString.prefix(4))")
        if reel { m.reelTitle = "R" }
        return ClipFeedItem(media: m, attemptLabel: nil)
    }

    func testSelectionCoversClipsSharesFirstVideoAndBulkHeart() {
        var a = post("a", session: UUID(), day: 1); a.clips = [clip("photo"), clip("video"), clip("video")]
        var b = post("b", session: UUID(), day: 2); b.clips = [clip("photo")]
        var c = post("c", session: UUID(), day: 3); c.clips = [clip("video")]
        let posts = [a, b, c]
        XCTAssertEqual(ClipGridModel.mediaIDs(of: ["a", "b"], in: posts), Set((a.clips + b.clips).map(\.media.id)))
        XCTAssertEqual(ClipGridModel.shareables(of: ["a", "b", "c"], in: posts),
                       [a.clips[1].media.localIdentifier, c.clips[0].media.localIdentifier])   // photo-only post skipped
        XCTAssertTrue(ClipGridModel.allFavorite(["a", "c"], in: posts, isFavorite: { $0.id != "b" }))
        XCTAssertFalse(ClipGridModel.allFavorite(["a", "b"], in: posts, isFavorite: { $0.id != "b" }))
        XCTAssertFalse(ClipGridModel.allFavorite([], in: posts, isFavorite: { _ in true }))
    }

    // MARK: move fast (prompt 176)

    func testScrubberMappingPinchAndLabels() {
        XCTAssertEqual(ClipGridModel.monthIndex(atFraction: 0, count: 4), 0)
        XCTAssertEqual(ClipGridModel.monthIndex(atFraction: 0.49, count: 4), 1)
        XCTAssertEqual(ClipGridModel.monthIndex(atFraction: 1, count: 4), 3)          // bottom edge = last month
        XCTAssertEqual(ClipGridModel.monthIndex(atFraction: -2, count: 4), 0)          // past the ends clamps
        XCTAssertNil(ClipGridModel.monthIndex(atFraction: 0.5, count: 0))
        XCTAssertEqual(ClipGridModel.columns(afterPinch: 0.6, current: 3), 5)
        XCTAssertEqual(ClipGridModel.columns(afterPinch: 1.5, current: 5), 3)
        XCTAssertEqual(ClipGridModel.columns(afterPinch: 1.0, current: 5), 5)

    }
}
