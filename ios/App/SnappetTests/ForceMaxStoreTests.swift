import XCTest
@testable import Snappet

/// `ForceMaxStore` keeps the max per hand in UserDefaults. UI-test launches use a scratch suite that
/// starts empty each time (prompt 289).
@MainActor final class ForceMaxStoreTests: XCTestCase {
    private let suite = "snappet.unittest.force.\(UUID().uuidString)"

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func testAMaxIsKeptAndClearedByZero() {
        let defaults = UserDefaults(suiteName: suite)!
        let store = ForceMaxStore(defaults: defaults)
        XCTAssertNil(store.both)
        store.both = 52
        XCTAssertEqual(ForceMaxStore(defaults: defaults).both, 52, "kept for the next launch")
        store.both = nil
        XCTAssertNil(ForceMaxStore(defaults: defaults).both)
    }

    func testTheScratchSuiteStartsEmptyEveryTime() {
        ForceMaxStore(defaults: UserDefaults(suiteName: suite)!).both = 525   // what an interrupted test run left
        let fresh = ForceMaxStore(defaults: ForceMaxStore.emptyScratchDefaults(suiteName: suite))
        XCTAssertNil(fresh.both, "the next test launch must not find it")
        XCTAssertNil(fresh.left)
        XCTAssertNil(fresh.right)
    }
}
