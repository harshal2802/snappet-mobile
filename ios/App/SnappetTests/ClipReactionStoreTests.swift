import XCTest
@testable import Snappet

/// Unit tests for the Clips favorite-reactions store (prompt 88) — toggle semantics + UserDefaults
/// persistence, against a throwaway suite (no shared state).
@MainActor
final class ClipReactionStoreTests: XCTestCase {

    private func freshStore() -> (ClipReactionStore, UserDefaults) {
        let suite = "ClipReactionStoreTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }   // don't leak the throwaway suite
        return (ClipReactionStore(defaults: d), d)
    }

    func testToggleFlipsFavorite() {
        let (store, _) = freshStore()
        XCTAssertFalse(store.isFavorite("p1"))
        store.toggle("p1")
        XCTAssertTrue(store.isFavorite("p1"))
        XCTAssertEqual(store.favoriteCount, 1)
        store.toggle("p1")
        XCTAssertFalse(store.isFavorite("p1"))
        XCTAssertEqual(store.favoriteCount, 0)
    }

    func testFavoritesPersistAcrossStores() {
        let (store, defaults) = freshStore()
        store.toggle("a"); store.toggle("b")
        let reloaded = ClipReactionStore(defaults: defaults)   // a fresh store over the same defaults
        XCTAssertTrue(reloaded.isFavorite("a"))
        XCTAssertTrue(reloaded.isFavorite("b"))
        XCTAssertFalse(reloaded.isFavorite("c"))
        XCTAssertEqual(reloaded.favoriteCount, 2)
    }
}
