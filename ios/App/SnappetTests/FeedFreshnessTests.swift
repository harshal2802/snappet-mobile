import XCTest
@testable import Snappet

/// F1: pure freshness ("N new" diff + pill copy) + lens filtering via F0's post-filters.
final class FeedFreshnessTests: XCTestCase {

    private func card(_ id: String, _ category: FeedCategory = .climbing, _ kind: FeedCardKind = .a1Session) -> FeedCard {
        FeedCard(id: id, kind: kind, category: category, salience: 0.5, anchorDate: Date(),
                 sourceRefs: [], payload: .streak(StreakPayload(days: 3, weeks: 0)))
    }

    func testNewCountCountsLeadingFreshRun() {
        let current = [card("n1"), card("n2"), card("old1"), card("old2")]
        XCTAssertEqual(FeedFreshness.newCount(current: current, seen: ["old1", "old2"]), 2)
    }

    func testNewCountZeroWhenNothingSeenYet() {
        XCTAssertEqual(FeedFreshness.newCount(current: [card("a")], seen: []), 0)
    }

    func testNewCountStopsAtFirstSeen() {
        let current = [card("n1"), card("old"), card("n2")]
        XCTAssertEqual(FeedFreshness.newCount(current: current, seen: ["old"]), 1)
    }

    func testPillText() {
        XCTAssertNil(FeedFreshness.pillText(newCount: 0))
        XCTAssertEqual(FeedFreshness.pillText(newCount: 1), "1 new · tap to refresh")
        XCTAssertEqual(FeedFreshness.pillText(newCount: 4), "4 new · tap to refresh")
    }

    func testLensFiltersViaComposer() {
        let cards = [card("a", .climbing, .a1Session),
                     card("b", .milestone, .b1GradePR),
                     card("c", .strength, .a2Session)]
        XCTAssertEqual(FeedComposer.filter(cards, lens: .sessionsOnly).map(\.id).sorted(), ["a", "c"])
        XCTAssertEqual(FeedComposer.filter(cards, lens: .category(.milestone)).map(\.id), ["b"])
        XCTAssertEqual(FeedComposer.filter(cards, lens: .all).count, 3)
    }
}
