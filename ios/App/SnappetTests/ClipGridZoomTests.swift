import XCTest
@testable import Snappet

/// 2026-10-10 — the Photos-style zoom's pure half: where every cover sits at each level, how far a pinch has
/// carried the grid, when a release finishes, and the scroll offset that keeps the pinched cover under the fingers.
final class ClipGridZoomTests: XCTestCase {

    /// Two months — 7 covers then 4 — on a 304-pt-wide grid.
    private func geometry(_ level: ClipGridLevel, header: CGFloat = 60) -> ClipGridGeometry {
        ClipGridGeometry(level: level, width: 304, sections: [.init(count: 7, headerHeight: header),
                                                             .init(count: 4, headerHeight: header)])
    }

    func testLevelsPinchOrder() {
        XCTAssertEqual(ClipGridLevel.all.denser, .months)
        XCTAssertEqual(ClipGridLevel.months.denser, .year)
        XCTAssertNil(ClipGridLevel.year.denser)
        XCTAssertEqual(ClipGridLevel.year.bigger, .months)
        XCTAssertNil(ClipGridLevel.all.bigger)
        XCTAssertEqual(ClipGridLevel(columns: 5), .months)
        XCTAssertEqual(ClipGridLevel(columns: 4), .all)            // unknown stored value → All
        XCTAssertFalse(ClipGridLevel.year.pinsHeaders)
    }

    func testGeometryPlacesCoversUnderTheirMonth() {
        let g = geometry(.all)
        XCTAssertEqual(g.side, (304 - 4 - 4) / 3, accuracy: 0.001)    // 2-pt edges + 2 gaps of 2
        XCTAssertEqual(g.itemFrame(0, 0).origin, CGPoint(x: 2, y: 60))
        XCTAssertEqual(g.itemFrame(0, 4).minX, 2 + g.side + 2, accuracy: 0.001)   // row 1, col 1
        XCTAssertEqual(g.itemFrame(0, 4).minY, 60 + g.side + 2, accuracy: 0.001)
        // 7 covers = 3 rows; month 2 starts after them.
        XCTAssertEqual(g.tops[1], 60 + 3 * (g.side + 2), accuracy: 0.001)
        XCTAssertEqual(g.contentHeight, g.tops[1] + 60 + 2 * (g.side + 2), accuracy: 0.001)
    }

    func testPinnedHeaderSticksThenIsPushedUp() {
        let g = geometry(.all)
        XCTAssertEqual(g.pinnedHeaderFrame(0, offset: 0).minY, 0)
        XCTAssertEqual(g.pinnedHeaderFrame(0, offset: 100).minY, 100)                       // stuck to the top
        XCTAssertEqual(g.pinnedHeaderFrame(0, offset: g.tops[1] - 10).maxY, g.tops[1], accuracy: 0.001) // pushed
    }

    func testOnlyVisibleRowsAndSectionsAreReturned() {
        let g = geometry(.all)
        XCTAssertEqual(g.sections(from: 0, to: 50), 0..<1)
        XCTAssertEqual(g.sections(from: g.tops[1] - 5, to: g.tops[1] + 5), 0..<2)
        XCTAssertEqual(g.sections(from: g.tops[1] + 5, to: g.contentHeight), 1..<2)
        XCTAssertEqual(g.items(in: 0, from: 0, to: 70), 0..<3)                 // just the first row
        XCTAssertEqual(g.items(in: 0, from: 60 + g.side + 10, to: 60 + g.side + 20), 3..<6)
        XCTAssertEqual(g.items(in: 0, from: 0, to: 5000), 0..<7)
    }

    func testItemNearAPoint() {
        let g = geometry(.all)
        XCTAssertEqual(g.item(near: CGPoint(x: 10, y: 10))?.item, 0)          // on the header → its first cover
        let f = g.itemFrame(0, 5)
        let hit = g.item(near: CGPoint(x: f.midX, y: f.midY))
        XCTAssertEqual(hit?.section, 0); XCTAssertEqual(hit?.item, 5)
        let last = g.item(near: CGPoint(x: 290, y: g.itemFrame(0, 6).midY))   // empty slot after the last cover
        XCTAssertEqual(last?.item, 6)
    }

    func testProgressTracksTheCoversSize() {
        XCTAssertEqual(ClipGridZoom.progress(scale: 1, from: .all, to: .months), 0)
        XCTAssertEqual(ClipGridZoom.progress(scale: 0.6, from: .all, to: .months), 1, accuracy: 0.001)   // 3/5
        XCTAssertEqual(ClipGridZoom.progress(scale: 5.0 / 3, from: .months, to: .all), 1, accuracy: 0.001)
        XCTAssertGreaterThan(ClipGridZoom.progress(scale: 0.4, from: .all, to: .months), 1)              // carry on
        XCTAssertEqual(ClipGridZoom.progress(scale: 1.3, from: .all, to: .months), 0)                    // wrong way
        XCTAssertEqual(ClipGridZoom.progress(scale: .nan, from: .all, to: .months), 0)
    }

    func testReleaseFinishesPastHalfwayOrOnAFlick() {
        XCTAssertTrue(ClipGridZoom.settles(progress: 0.6, towardVelocity: 0))
        XCTAssertFalse(ClipGridZoom.settles(progress: 0.6, towardVelocity: -2))     // flicked back
        XCTAssertFalse(ClipGridZoom.settles(progress: 0.3, towardVelocity: 0))
        XCTAssertTrue(ClipGridZoom.settles(progress: 0.2, towardVelocity: 1.5))     // flicked on
        XCTAssertFalse(ClipGridZoom.settles(progress: 0.01, towardVelocity: 3))     // barely started
    }

    /// The pinched cover stays at the same height on screen after the zoom (until the content edge clamps it).
    func testAnchoredOffsetKeepsTheCoverUnderTheFingers() {
        let tall = ClipGridGeometry(level: .all, width: 304,
                                    sections: (0..<6).map { _ in .init(count: 30, headerHeight: 60) })
        let dense = ClipGridGeometry(level: .months, width: 304, sections: tall.sections)
        let item = (section: 3, item: 10), screenY: CGFloat = 300
        let o1 = ClipGridZoom.anchoredOffset(item: item, fraction: 0.5, screenY: screenY, in: dense, viewport: 700)
        let f1 = dense.itemFrame(3, 10)
        XCTAssertEqual(f1.midY - o1, screenY, accuracy: 0.001)
        // Near the top it can't scroll above 0; at the bottom not past the end.
        XCTAssertEqual(ClipGridZoom.anchoredOffset(item: (0, 0), fraction: 0, screenY: 500, in: dense, viewport: 700), 0)
        let end = ClipGridZoom.anchoredOffset(item: (5, 29), fraction: 1, screenY: 0, in: dense, viewport: 700)
        XCTAssertEqual(end, dense.contentHeight - 700, accuracy: 0.001)
    }

    func testEaseAndLerp() {
        XCTAssertEqual(ClipGridZoom.ease(0), 0); XCTAssertEqual(ClipGridZoom.ease(1), 1); XCTAssertEqual(ClipGridZoom.ease(2), 1)
        XCTAssertGreaterThan(ClipGridZoom.ease(0.5), 0.5)                       // ease-out: fast start
        let r = ClipGridZoom.lerp(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 20, width: 30, height: 30), 0.5)
        XCTAssertEqual(r, CGRect(x: 5, y: 10, width: 20, height: 20))
    }

    // MARK: year level (wireframe option A)

    func testYearsSumClipsAndSessions() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func post(_ id: String, _ session: UUID, year: Int, month: Int) -> ClipFeedPost {
            let d = cal.date(from: DateComponents(year: year, month: month, day: 3, hour: 12))!
            return ClipFeedPost(id: id, sessionID: session, kind: .kilter, moduleID: "kilter", discipline: .climbing,
                                title: id, subtitle: "", overlayDetail: "", climbUUID: nil, exerciseID: nil,
                                captureAt: d, sessionStartedAt: d, sessionEndedAt: nil, isFromAppleWatch: false,
                                clips: [], aspect: ClipFeedComposer.defaultAspect)
        }
        let s1 = UUID(), s2 = UUID()
        let months = ClipGridModel.months([post("a", s1, year: 2026, month: 10), post("b", s1, year: 2026, month: 10),
                                           post("c", s2, year: 2026, month: 9), post("d", UUID(), year: 2025, month: 12)],
                                          peak: { _ in nil }, calendar: cal, locale: Locale(identifier: "en_US"))
        let years = ClipGridModel.years(months)
        XCTAssertEqual(years["2026"]?.sessions, 2)
        XCTAssertEqual(years["2025"]?.sessions, 1)
        XCTAssertEqual(years["2026"]?.summary, "0 clips · 2 sessions")          // these test posts carry no media
        XCTAssertEqual(ClipGridModel.Year(id: "y", title: "y", clips: 1, sessions: 1).summary, "1 clip · 1 session")
        XCTAssertEqual(ClipGridModel.shortMonth(months[0], calendar: cal, locale: Locale(identifier: "en_US")), "OCT")
    }
}
