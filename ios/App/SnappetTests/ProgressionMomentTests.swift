import XCTest
@testable import Snappet

/// Progression P3 (prompt 151): which moment a session earns, once per level, never for history.
final class ProgressionMomentTests: XCTestCase {
    private func info(_ level: Int) -> Progression.LevelInfo {
        Progression.LevelInfo(level: level, xpIntoLevel: 0, levelCost: Progression.levelCost(level))
    }

    func testCrossingALevelIsALevelUp() {
        XCTAssertEqual(Progression.moment(before: info(12), after: info(13), celebrated: 12), .levelUp(level: 13))
    }

    func testCrossingIntoANewStageIsGrowingUp() {
        XCTAssertEqual(Progression.moment(before: info(9), after: info(10), celebrated: 9),
                       .grewUp(from: .sprout, to: .adult, level: 10))
        XCTAssertEqual(Progression.moment(before: info(19), after: info(20), celebrated: nil),
                       .grewUp(from: .adult, to: .legend, level: 20))
    }

    func testNoLevelNoMoment() {
        XCTAssertNil(Progression.moment(before: info(12), after: info(12), celebrated: 12))
    }

    func testEachLevelIsCelebratedOnce() {
        // Already celebrated 13 (e.g. an edit re-earned it): no second moment.
        XCTAssertNil(Progression.moment(before: info(12), after: info(13), celebrated: 13))
    }

    func testBackfilledHistoryNeverTriggersAMoment() {
        // Never celebrated: the level your history already earned counts as seen.
        XCTAssertNil(Progression.moment(before: info(12), after: info(12), celebrated: nil))
        XCTAssertEqual(Progression.moment(before: info(12), after: info(13), celebrated: nil), .levelUp(level: 13))
    }

    func testEveryStageButEggNamesWhatItUnlocks() {
        XCTAssertTrue(BuddyStage.egg.unlocks.isEmpty)
        for s in BuddyStage.allCases.dropFirst() { XCTAssertFalse(s.unlocks.isEmpty, "\(s)") }
    }

    func testDetailReasonsAreShort() {
        let award = Progression.Award(items: [
            .init(label: "Session finished", xp: 50), .init(label: "42 active minutes", xp: 42),
            .init(label: "On plan · Thursday", xp: 20), .init(label: "🏆 Bench PR", xp: 25),
            .init(label: "🔥 5-week streak", xp: 50)], total: 187, capped: false)
        XCTAssertEqual(SessionXPRow.reasons(award), ["on plan", "Bench PR", "5-week streak"])
    }
}
