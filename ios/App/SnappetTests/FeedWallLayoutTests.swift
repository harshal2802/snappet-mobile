import XCTest
@testable import Snappet

final class FeedWallLayoutTests: XCTestCase {

    // MARK: - Fixtures

    /// A minimal, deterministic FeedCard whose only meaningful field for layout
    /// purposes is `id`. The payload is an arbitrary valid case.
    private func card(_ id: String) -> FeedCard {
        FeedCard(
            id: id,
            kind: .restNudge,
            category: .trend,
            salience: 0.50,
            anchorDate: Date(timeIntervalSince1970: 0),
            sourceRefs: [ActivityRef(objectKind: "aggregate", ref: id)],
            payload: .restNudge(RestNudgePayload(hardDays: 3, note: "go gentler"))
        )
    }

    private func cards(_ count: Int) -> [FeedCard] {
        (0..<count).map { card("c\($0)") }
    }

    // MARK: - No drop / no dup

    func testNoDropNoDuplicate() {
        let input = cards(11)
        let columns = FeedWallLayout.distribute(input, columns: 3)
        let flattened = columns.flatMap { $0 }

        XCTAssertEqual(flattened.count, input.count, "no card dropped or duplicated")
        XCTAssertEqual(Set(flattened.map { $0.id }), Set(input.map { $0.id }),
                       "the same set of cards comes back")
    }

    // MARK: - Shortest-column balance

    func testBalancedCountsDifferByAtMostOne() {
        for n in 0...30 {
            for cols in 1...5 {
                let columns = FeedWallLayout.distribute(cards(n), columns: cols)
                let counts = columns.map { $0.count }
                let spread = (counts.max() ?? 0) - (counts.min() ?? 0)
                XCTAssertLessThanOrEqual(spread, 1,
                    "n=\(n) cols=\(cols): column counts must differ by <= 1, got \(counts)")
            }
        }
    }

    func testEvenlyDivisibleIsPerfectlyBalanced() {
        // 12 cards / 3 columns => exactly 4 each.
        let columns = FeedWallLayout.distribute(cards(12), columns: 3)
        XCTAssertEqual(columns.map { $0.count }, [4, 4, 4])
    }

    func testAlwaysReturnsRequestedColumnCount() {
        let columns = FeedWallLayout.distribute(cards(2), columns: 4)
        XCTAssertEqual(columns.count, 4, "returns one array per column even when sparse")
        XCTAssertEqual(columns.map { $0.count }, [1, 1, 0, 0],
                       "fewer cards than columns leaves trailing columns empty")
    }

    // MARK: - Deterministic placement (ties -> lowest index)

    func testDeterministicRoundRobinPlacement() {
        // With shortest-first + ties-to-lowest-index, 6 cards over 3 columns
        // round-robins: col0=[0,3], col1=[1,4], col2=[2,5].
        let columns = FeedWallLayout.distribute(cards(6), columns: 3)
        XCTAssertEqual(columns[0].map { $0.id }, ["c0", "c3"])
        XCTAssertEqual(columns[1].map { $0.id }, ["c1", "c4"])
        XCTAssertEqual(columns[2].map { $0.id }, ["c2", "c5"])
    }

    // MARK: - Order within column preserved

    func testOrderWithinColumnPreserved() {
        let columns = FeedWallLayout.distribute(cards(10), columns: 2)
        // col0 = c0,c2,c4,c6,c8 ; col1 = c1,c3,c5,c7,c9 — each strictly ascending.
        for column in columns {
            let ids = column.map { $0.id }
            let sortedByInputOrder = ids.sorted { lhs, rhs in
                let li = Int(lhs.dropFirst())!
                let ri = Int(rhs.dropFirst())!
                return li < ri
            }
            XCTAssertEqual(ids, sortedByInputOrder, "input order preserved within a column")
        }
        XCTAssertEqual(columns[0].map { $0.id }, ["c0", "c2", "c4", "c6", "c8"])
        XCTAssertEqual(columns[1].map { $0.id }, ["c1", "c3", "c5", "c7", "c9"])
    }

    // MARK: - Clamp columns >= 1

    func testColumnsClampedToAtLeastOne() {
        for cols in [-3, 0] {
            let columns = FeedWallLayout.distribute(cards(5), columns: cols)
            XCTAssertEqual(columns.count, 1, "columns clamp to >= 1 (got \(cols))")
            XCTAssertEqual(columns[0].map { $0.id }, cards(5).map { $0.id },
                           "single column holds all cards in input order")
        }
    }

    // MARK: - Empty input

    func testEmptyInputReturnsEmptyColumns() {
        let columns = FeedWallLayout.distribute([], columns: 3)
        XCTAssertEqual(columns.count, 3)
        XCTAssertTrue(columns.allSatisfy { $0.isEmpty })
    }

    func testEmptyInputClampedColumns() {
        let columns = FeedWallLayout.distribute([], columns: 0)
        XCTAssertEqual(columns.count, 1)
        XCTAssertTrue(columns[0].isEmpty)
    }

    // MARK: - columnCount thresholds

    func testColumnCountThresholds() {
        XCTAssertEqual(FeedWallLayout.columnCount(forWidth: 0), 2)
        XCTAssertEqual(FeedWallLayout.columnCount(forWidth: 320), 2)
        XCTAssertEqual(FeedWallLayout.columnCount(forWidth: 499.999), 2)
        XCTAssertEqual(FeedWallLayout.columnCount(forWidth: 500), 3, "500 is the >= boundary -> 3")
        XCTAssertEqual(FeedWallLayout.columnCount(forWidth: 768), 3)
        XCTAssertEqual(FeedWallLayout.columnCount(forWidth: 1024), 3)
    }
}
