import XCTest
@testable import Snappet

/// Prompt 165 — Clips search finds posts by grade, angle, outcome and date words, every word must match,
/// and relative phrases ("last week") become date ranges. Fixed clock / calendar / locale.
final class ClipSearchTests: XCTestCase {

    private var ctx: ClipSearch.Context {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2                                           // Monday
        // Thu 8 Oct 2026, 12:00 UTC
        return .init(now: Date(timeIntervalSince1970: 1_791_460_800), calendar: cal,
                     locale: Locale(identifier: "en_GB"))
    }

    private func post(_ title: String, detail: String = "", subtitle: String = "", session: String = "",
                      at: Date, result: ClipFeedClimbResult? = nil) -> ClipFeedPost {
        var p = ClipFeedPost(id: title, sessionID: UUID(), kind: .kilter, moduleID: "kilter", discipline: .climbing,
                             title: title, subtitle: subtitle, overlayDetail: detail, climbUUID: nil, exerciseID: nil,
                             captureAt: at, sessionStartedAt: at, sessionEndedAt: nil, isFromAppleWatch: false,
                             clips: [], aspect: ClipFeedComposer.defaultAspect)
        p.climbResult = result
        p.sessionTitle = session
        return p
    }

    private let day: TimeInterval = 86_400
    private var now: Date { ctx.now }

    private func find(_ q: String, in posts: [ClipFeedPost]) -> [String] {
        let s = ClipSearch(query: q, context: ctx)
        return posts.filter(s.matches).map(\.id)
    }

    private var sample: [ClipFeedPost] {
        [post("Black v6", detail: "6c/V5 · 40°", subtitle: "Tuesday Session · 40°", session: "Tuesday Session",
              at: now.addingTimeInterval(-1 * day), result: .init(status: .sent, attempts: 3)),        // Wed 7 Oct
         post("Orange Crimp", detail: "7a/V6 · 45°", subtitle: "Comp Night · 45°",
              at: now.addingTimeInterval(-9 * day), result: .init(status: .flash, attempts: 1)),       // Tue 29 Sep
         post("Roof", detail: "7b/V8 · 50°", at: now.addingTimeInterval(-40 * day),
              result: .init(status: .project, attempts: 9)),                                          // Sat 29 Aug
         post("Bench Press", subtitle: "Push Day", at: now)]
    }

    func testGradeAngleAndName() {
        XCTAssertEqual(find("v5", in: sample), ["Black v6"])           // the grade, not the name's "v6"
        XCTAssertEqual(find("45°", in: sample), ["Orange Crimp"])
        XCTAssertEqual(find("crimp", in: sample), ["Orange Crimp"])
    }

    func testOutcomeWordsSentIncludesFlashes() {
        XCTAssertEqual(find("sent", in: sample), ["Black v6", "Orange Crimp"])
        XCTAssertEqual(find("flash", in: sample), ["Orange Crimp"])
        XCTAssertEqual(find("project", in: sample), ["Roof"])
    }

    func testDateWords() {
        XCTAssertEqual(find("august", in: sample), ["Roof"])
        XCTAssertEqual(find("aug", in: sample), ["Roof"])
        XCTAssertEqual(find("wednesday", in: sample), ["Black v6"])     // the capture weekday
        XCTAssertEqual(find("tuesday", in: sample), ["Black v6", "Orange Crimp"])   // session name + weekday
        XCTAssertEqual(find("29 sep", in: sample), ["Orange Crimp"])
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(find("sent sep", in: sample), ["Orange Crimp"])
        XCTAssertEqual(find("sent oct", in: sample), ["Black v6"])
        XCTAssertEqual(find("bench sent", in: sample), [])
    }

    func testRelativePhrases() {
        XCTAssertEqual(find("today", in: sample), ["Bench Press"])
        XCTAssertEqual(find("yesterday", in: sample), ["Black v6"])
        XCTAssertEqual(find("this week", in: sample), ["Black v6", "Bench Press"])   // Mon 5 – Sun 11 Oct
        XCTAssertEqual(find("last week", in: sample), ["Orange Crimp"])               // Mon 28 Sep – Sun 4 Oct
        XCTAssertEqual(find("last month", in: sample), ["Orange Crimp"])              // September
        XCTAssertEqual(find("sent last week", in: sample), ["Orange Crimp"])
    }

    /// The filter wires it in: a search narrows the feed through `apply`.
    func testFilterUsesTheSearch() {
        var f = ClipFeedFilter()
        f.query = "v8"
        XCTAssertEqual(f.apply(sample, isFavorite: { _ in false }, searchContext: ctx).map(\.id), ["Roof"])
    }
}
