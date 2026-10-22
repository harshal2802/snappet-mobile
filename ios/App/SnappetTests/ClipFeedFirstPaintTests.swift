import XCTest
@testable import Snappet

/// The Clips feed paints with only the newest sessions' HR overlays; the rest follow off main (prompt 202).
final class ClipFeedFirstPaintTests: XCTestCase {
    func testTheNewestSessionsPaintFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<12).map { _ in UUID() }
        let starts = Dictionary(uniqueKeysWithValues: ids.enumerated().map { i, id in (id, now.addingTimeInterval(Double(-i) * 86_400)) })
        let first = ClipFeedComposer.firstPaintSessions(starts, count: 8)
        XCTAssertEqual(first, Set(ids.prefix(8)), "the 8 newest — the top of the feed (posts sort newest session first)")
        XCTAssertEqual(ClipFeedComposer.firstPaintSessions(starts, count: 50).count, 12, "fewer sessions than the budget → all")
        XCTAssertTrue(ClipFeedComposer.firstPaintSessions([:], count: 8).isEmpty)
    }

    func testTiesAreDeterministic() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<5).map { _ in UUID() }
        let starts = Dictionary(uniqueKeysWithValues: ids.map { ($0, t) })
        XCTAssertEqual(ClipFeedComposer.firstPaintSessions(starts, count: 2), ClipFeedComposer.firstPaintSessions(starts, count: 2))
    }
}
