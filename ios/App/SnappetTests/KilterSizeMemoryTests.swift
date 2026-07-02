import XCTest
@testable import Snappet

/// Unit tests for the per-layout board-size memory behind the "resets board to 12 x 14" fix —
/// the pure `choose` resolution rule plus the `UserDefaults`-backed remember/recall map. No device:
/// an isolated, injected `UserDefaults` suite keeps every case hermetic (the `KilterBoardMemory`
/// pattern). The size ids mirror the real failure: 1 = the 12×14 default (lowest id), 10 = the
/// user's 12×12.
@MainActor
final class KilterSizeMemoryTests: XCTestCase {
    nonisolated(unsafe) private var suiteName = ""
    nonisolated(unsafe) private var defaults: UserDefaults?

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    private func makeMemory() -> KilterSizeMemory {
        if defaults == nil {
            suiteName = "kilter.sizememory.test.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)
        }
        return KilterSizeMemory(defaults: defaults!)
    }

    // MARK: - Pure resolution rule

    func testEmptyAvailableLeavesSelectionAlone() {
        // Catalog unreadable / mid-reload: the old guard reset to the default here; choose must not.
        XCTAssertNil(KilterSizeMemory.choose(remembered: 10, current: 10, available: []))
        XCTAssertNil(KilterSizeMemory.choose(remembered: nil, current: 0, available: []))
    }

    func testRememberedSizeWinsWhenStillOffered() {
        // Returning to a layout restores ITS size — even when something else is currently in effect.
        XCTAssertEqual(KilterSizeMemory.choose(remembered: 10, current: 7, available: [1, 7, 10]), 10)
    }

    func testValidCurrentCarriesOverWhenNothingRemembered() {
        // First visit to a layout that happens to offer the size already in effect: keep it.
        XCTAssertEqual(KilterSizeMemory.choose(remembered: nil, current: 7, available: [1, 7, 10]), 7)
    }

    func testFallsBackToLowestIdOnlyWhenNeitherIsOffered() {
        // The one legitimate reset: neither the remembered nor the current size exists here.
        XCTAssertEqual(KilterSizeMemory.choose(remembered: 99, current: 42, available: [1, 7, 10]), 1)
        XCTAssertEqual(KilterSizeMemory.choose(remembered: nil, current: 0, available: [1, 7, 10]), 1)
    }

    func testStaleRememberedFallsThroughToValidCurrent() {
        // A remembered size a catalog swap removed must not shadow a still-valid current one.
        XCTAssertEqual(KilterSizeMemory.choose(remembered: 99, current: 7, available: [1, 7, 10]), 7)
    }

    // MARK: - Remember / recall map

    func testRecallIsNilForUnknownLayout() {
        XCTAssertNil(makeMemory().recall(forLayout: 1))
    }

    func testRememberIsPerLayoutAndSurvivesReload() {
        let memory = makeMemory()
        memory.remember(sizeId: 10, forLayout: 1)   // Original → 12×12
        memory.remember(sizeId: 7, forLayout: 8)    // Homewall → 7×10

        XCTAssertEqual(memory.recall(forLayout: 1), 10)
        XCTAssertEqual(memory.recall(forLayout: 8), 7)

        // A fresh instance over the same defaults sees the same map (persistence, not instance state).
        let reloaded = KilterSizeMemory(defaults: defaults!)
        XCTAssertEqual(reloaded.recall(forLayout: 1), 10)
        XCTAssertEqual(reloaded.recall(forLayout: 8), 7)
    }

    func testRememberOverwritesTheLayoutsPreviousChoice() {
        let memory = makeMemory()
        memory.remember(sizeId: 1, forLayout: 1)
        memory.remember(sizeId: 10, forLayout: 1)
        XCTAssertEqual(memory.recall(forLayout: 1), 10)
    }

    // MARK: - The reported regression, end to end over the rule

    func testLayoutRoundTripKeepsTheChosenSize() {
        let memory = makeMemory()
        let original = [1, 10]      // 1 = 12×14 (lowest id = old default), 10 = the user's 12×12
        let homewall = [7, 8]

        // User picks 12×12 on Original.
        memory.remember(sizeId: 10, forLayout: 1)

        // Browse Homewall: its seed is the default (nothing remembered, current 10 not offered).
        let onHomewall = KilterSizeMemory.choose(remembered: memory.recall(forLayout: 8),
                                                 current: 10, available: homewall)
        XCTAssertEqual(onHomewall, 7)
        memory.remember(sizeId: onHomewall!, forLayout: 8)

        // Back to Original: the remembered 12×12 returns — NOT the 12×14 default.
        let backOnOriginal = KilterSizeMemory.choose(remembered: memory.recall(forLayout: 1),
                                                     current: onHomewall!, available: original)
        XCTAssertEqual(backOnOriginal, 10)
    }
}
