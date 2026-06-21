import XCTest
@testable import Snappet

/// F1: pure keyset pagination — stable across page boundaries (no dup/skip).
final class FeedPaginationTests: XCTestCase {

    private func cards(_ n: Int) -> [FeedCard] {
        (0..<n).map { i in
            FeedCard(id: "c\(i)", kind: .a1Session, category: .climbing, salience: 0.5,
                     anchorDate: Date(timeIntervalSince1970: Double(10_000 - i)), sourceRefs: [],
                     payload: .streak(StreakPayload(days: 3, weeks: 0)))
        }
    }

    func testPagesCoverEverythingWithoutDupOrSkip() {
        let all = cards(25)
        var collected: [String] = []
        var cursor: FeedPagination.Cursor? = nil
        var loops = 0
        repeat {
            let (page, next) = FeedPagination.page(all, after: cursor, limit: 10)
            collected += page.map(\.id)
            cursor = next
            loops += 1
        } while cursor != nil && loops < 100
        XCTAssertEqual(collected, all.map(\.id), "keyset paging must reproduce the exact order")
        XCTAssertEqual(Set(collected).count, 25, "no duplicates across boundaries")
    }

    func testWindow() {
        let all = cards(10)
        XCTAssertEqual(FeedPagination.window(all, count: 4).map(\.id), ["c0", "c1", "c2", "c3"])
        XCTAssertEqual(FeedPagination.window(all, count: 99).count, 10)
        XCTAssertTrue(FeedPagination.window(all, count: 0).isEmpty)
    }

    func testEmpty() {
        let (page, next) = FeedPagination.page([], after: nil, limit: 5)
        XCTAssertTrue(page.isEmpty)
        XCTAssertNil(next)
    }
}
