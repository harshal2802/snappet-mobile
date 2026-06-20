import XCTest
@testable import Snappet

/// Pure unit tests for the **P1 board-detect** store + rules — `KilterBoardMemory`, its serial/angle/
/// place rules, and the pure `KilterPlaceMatcher`. No `CoreBluetooth`, no `CoreLocation`, no device: an
/// **isolated, injected `UserDefaults`** suite keeps every case hermetic (the same honesty bar as
/// `BandMemory` / `isLikelyBoard`). The live BLE-connect + CoreLocation legs are device-pending.
@MainActor
final class KilterBoardMemoryTests: XCTestCase {
    /// A fresh, isolated `UserDefaults` suite per test — created lazily in `makeMemory` and torn down by
    /// name. Kept `nonisolated(unsafe)` so the (nonisolated) XCTest `tearDown` can clean up without an
    /// actor hop; access is single-threaded across setUp → the test body → tearDown.
    nonisolated(unsafe) private var suiteName = ""
    nonisolated(unsafe) private var defaults: UserDefaults?

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    private func makeMemory() -> KilterBoardMemory {
        if defaults == nil {
            suiteName = "kilter.boardmemory.test.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)
        }
        return KilterBoardMemory(defaults: defaults!)
    }

    // MARK: - Remember / recall by identifier

    func testRememberThenRecallByIdentifierRestoresLayoutSizeAngle() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17, label: "8×12 Home")
        memory.confirmAngle(identifier: id, angle: 40)

        let recalled = memory.recall(identifier: id)
        XCTAssertNotNil(recalled)
        XCTAssertEqual(recalled?.layoutId, 8)
        XCTAssertEqual(recalled?.productSizeId, 17)
        XCTAssertEqual(recalled?.usualAngle, 40)
        XCTAssertEqual(recalled?.label, "8×12 Home")
    }

    func testUnknownBoardRecallsNilSoNothingIsRestored() {
        let memory = makeMemory()
        memory.remember(identifier: UUID(), layoutId: 1, productSizeId: 1)
        XCTAssertNil(memory.recall(identifier: UUID()), "an unknown identifier must not restore anything")
    }

    func testRememberPersistsAcrossInstancesViaUserDefaults() {
        let id = UUID()
        makeMemory().remember(identifier: id, layoutId: 3, productSizeId: 9)
        // A fresh instance over the SAME injected defaults must see it.
        XCTAssertEqual(makeMemory().recall(identifier: id)?.layoutId, 3)
    }

    func testRememberUpdatesLayoutAndSizeOnReconnect() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 1, productSizeId: 1)
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17)
        let recalled = memory.recall(identifier: id)
        XCTAssertEqual(recalled?.layoutId, 8)
        XCTAssertEqual(recalled?.productSizeId, 17)
    }

    // MARK: - Angle recording is split (F1): identity-remember NEVER appends an angle

    func testRememberDoesNotRecordAnyAngle() {
        let memory = makeMemory()
        let id = UUID()
        // A plain connect (identity remember) — even several of them — appends nothing to the history,
        // so the pre-selected angle can never self-reinforce when the climber ignores the connect.
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17)
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17)
        let recalled = memory.recall(identifier: id)
        XCTAssertEqual(recalled?.angleHistory, [], "remember must not append an angle")
        XCTAssertNil(recalled?.usualAngle, "a never-confirmed board has no usual angle (no pre-select)")
    }

    func testConfirmAngleIsTheOnlyPathThatRecordsHistory() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17)
        memory.confirmAngle(identifier: id, angle: 40)
        memory.confirmAngle(identifier: id, angle: 40)
        memory.confirmAngle(identifier: id, angle: 30)
        XCTAssertEqual(memory.recall(identifier: id)?.angleHistory, [40, 40, 30],
                       "angle history accumulates only on explicit confirm")
        XCTAssertEqual(memory.recall(identifier: id)?.usualAngle, 40, "most-frequent confirmed angle")
    }

    func testConfirmAngleIsNoOpForUnknownBoard() {
        let memory = makeMemory()
        memory.confirmAngle(identifier: UUID(), angle: 40)
        XCTAssertTrue(memory.isEmpty, "confirming an angle for an unknown board does nothing")
    }

    func testBrandNewBoardStartsWithEmptyHistoryAndNoPreSelect() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17)
        XCTAssertEqual(memory.recall(identifier: id)?.angleHistory, [])
        XCTAssertNil(memory.recall(identifier: id)?.usualAngle)
    }

    // MARK: - Serial parse + cross-check fallback

    func testSerialParseFromAuroraLocalName() {
        XCTAssertEqual(KilterBoardMemory.serial(fromLocalName: "Kilter#A1B2C3@3"), "A1B2C3")
        XCTAssertEqual(KilterBoardMemory.serial(fromLocalName: "Aurora Board#XYZ@2"), "XYZ")
        XCTAssertEqual(KilterBoardMemory.serial(fromLocalName: "Kilter#NoApiSuffix"), "NoApiSuffix")
    }

    func testSerialParseReturnsNilWhenAbsent() {
        XCTAssertNil(KilterBoardMemory.serial(fromLocalName: "Kilter Board A1B2"))
        XCTAssertNil(KilterBoardMemory.serial(fromLocalName: "Kilter#@3"), "empty serial → nil")
        XCTAssertNil(KilterBoardMemory.serial(fromLocalName: nil))
    }

    func testRecallFallsBackToSerialWhenIdentifierChanges() {
        let memory = makeMemory()
        let oldID = UUID()
        memory.remember(identifier: oldID, layoutId: 8, productSizeId: 17, serial: "SER-1")

        // A phone reinstall mints a NEW identifier, but the board still advertises the same serial.
        let newID = UUID()
        let recalled = memory.recall(identifier: newID, serial: "SER-1")
        XCTAssertEqual(recalled?.layoutId, 8, "serial cross-check should find the board under a new id")
    }

    func testRecallPrefersIdentifierOverSerial() {
        let memory = makeMemory()
        let idA = UUID(), idB = UUID()
        memory.remember(identifier: idA, layoutId: 1, productSizeId: 1, serial: "SHARED")
        memory.remember(identifier: idB, layoutId: 8, productSizeId: 17, serial: "SHARED")
        // Recalling idB by identifier must return idB's board even though both share a serial.
        XCTAssertEqual(memory.recall(identifier: idB, serial: "SHARED")?.layoutId, 8)
    }

    func testRecallNilWhenSerialAlsoMisses() {
        let memory = makeMemory()
        memory.remember(identifier: UUID(), layoutId: 8, productSizeId: 17, serial: "SER-1")
        XCTAssertNil(memory.recall(identifier: UUID(), serial: "SER-OTHER"))
    }

    /// F2: when several entries share a serial (identifier miss), recall must be DETERMINISTIC — the
    /// most-recently-seen entry, never an arbitrary `dict.values.first`.
    func testSerialCrossCheckReturnsMostRecentEntry() {
        let memory = makeMemory()
        let older = UUID(), newer = UUID()
        memory.remember(identifier: older, layoutId: 1, productSizeId: 1, serial: "DUP",
                        at: Date(timeIntervalSince1970: 1000))
        memory.remember(identifier: newer, layoutId: 8, productSizeId: 17, serial: "DUP",
                        at: Date(timeIntervalSince1970: 2000))
        // A brand-new identifier that only matches by serial must resolve to the newest of the two.
        let recalled = memory.recall(identifier: UUID(), serial: "DUP")
        XCTAssertEqual(recalled?.layoutId, 8, "serial cross-check picks the most-recently-seen entry")
        XCTAssertEqual(recalled?.productSizeId, 17)
    }

    func testRememberNeverDropsAKnownSerial() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17, serial: "SER-1")
        // A later connect from the adopt path (no advert → nil serial) must not erase the known serial.
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17, serial: nil)
        XCTAssertEqual(memory.recall(identifier: id)?.serial, "SER-1")
    }

    // MARK: - Most-frequent angle

    func testMostFrequentAngle() {
        XCTAssertEqual(KilterBoardMemory.mostFrequentAngle([40, 40, 30, 40, 25]), 40)
        XCTAssertNil(KilterBoardMemory.mostFrequentAngle([]))
        XCTAssertEqual(KilterBoardMemory.mostFrequentAngle([35]), 35)
    }

    func testMostFrequentAngleTieBreaksToMostRecent() {
        // 30 and 40 are tied (2 each) — the more recent (40, appearing last) wins.
        XCTAssertEqual(KilterBoardMemory.mostFrequentAngle([30, 30, 40, 40]), 40)
        XCTAssertEqual(KilterBoardMemory.mostFrequentAngle([40, 40, 30, 30]), 30)
    }

    func testUsualAngleTracksHistoryHabit() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17)
        for a in [40, 40, 30, 40] { memory.confirmAngle(identifier: id, angle: a) }
        XCTAssertEqual(memory.recall(identifier: id)?.usualAngle, 40)
    }

    // MARK: - Forget / rename

    func testForgetRemovesBoard() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17)
        memory.forget(identifier: id)
        XCTAssertNil(memory.recall(identifier: id))
        XCTAssertTrue(memory.isEmpty)
    }

    func testForgetIsScopedToOneBoard() {
        let memory = makeMemory()
        let keep = UUID(), drop = UUID()
        memory.remember(identifier: keep, layoutId: 1, productSizeId: 1)
        memory.remember(identifier: drop, layoutId: 8, productSizeId: 17)
        memory.forget(identifier: drop)
        XCTAssertNotNil(memory.recall(identifier: keep))
        XCTAssertNil(memory.recall(identifier: drop))
    }

    func testRenamePreservedAcrossReconnect() {
        let memory = makeMemory()
        let id = UUID()
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17, label: "Board SER-1")
        memory.rename(identifier: id, to: "8×12 Home")
        // A reconnect with no explicit label must NOT clobber the user's rename.
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17, label: nil)
        XCTAssertEqual(memory.recall(identifier: id)?.label, "8×12 Home")
    }

    func testRememberUsesProvidedDefaultLabelForNewBoard() {
        let memory = makeMemory()
        let id = UUID()
        // F8: the call site (which has the catalog) passes a clearer default label for a no-serial board.
        memory.remember(identifier: id, layoutId: 8, productSizeId: 17, defaultLabel: "Original 8×12")
        XCTAssertEqual(memory.recall(identifier: id)?.label, "Original 8×12")
    }

    func testRememberedSortedNewestFirst() {
        let memory = makeMemory()
        let older = UUID(), newer = UUID()
        memory.remember(identifier: older, layoutId: 1, productSizeId: 1,
                        at: Date(timeIntervalSince1970: 1000))
        memory.remember(identifier: newer, layoutId: 8, productSizeId: 17,
                        at: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(memory.rememberedSorted.first?.id, newer)
    }

    // MARK: - CoarsePlace match / no-match

    func testCoarsePlaceBucketsToSameSquare() {
        // Two nearby fixes that both round to the same 3-decimal bucket (37.331, -122.030).
        let a = CoarsePlace(latitude: 37.331234, longitude: -122.030123)
        let b = CoarsePlace(latitude: 37.331401, longitude: -122.030499)
        XCTAssertEqual(a.lat, b.lat, accuracy: 1e-9)
        XCTAssertEqual(a.lon, b.lon, accuracy: 1e-9)
        XCTAssertTrue(a.matches(b))
    }

    func testCoarsePlaceDistinctSquaresDoNotMatch() {
        let gymA = CoarsePlace(latitude: 37.3318, longitude: -122.0305)
        let gymB = CoarsePlace(latitude: 40.7128, longitude: -74.0060)
        XCTAssertFalse(gymA.matches(gymB))
    }

    func testCoarsePlaceNeverStoresPreciseCoordinate() {
        let p = CoarsePlace(latitude: 37.3312345678, longitude: -122.0305678)
        // 3 decimals only — the precise digits are gone.
        XCTAssertEqual(p.lat, 37.331, accuracy: 1e-9)
        XCTAssertEqual(p.lon, -122.031, accuracy: 1e-9)
    }

    func testPlaceMatcherSuggestsBoardAtSameSquare() {
        let memory = makeMemory()
        let here = UUID(), elsewhere = UUID()
        let gym = CoarsePlace(latitude: 37.3318, longitude: -122.0305)
        memory.remember(identifier: here, layoutId: 8, productSizeId: 17, coarsePlace: gym)
        memory.remember(identifier: elsewhere, layoutId: 1, productSizeId: 1,
                        coarsePlace: CoarsePlace(latitude: 40.7128, longitude: -74.0060))

        let suggestion = KilterPlaceMatcher.suggestion(for: gym, in: memory.rememberedSorted)
        XCTAssertEqual(suggestion?.id, here)
    }

    func testPlaceMatcherNoMatchAtUnknownPlace() {
        let memory = makeMemory()
        memory.remember(identifier: UUID(), layoutId: 8, productSizeId: 17,
                        coarsePlace: CoarsePlace(latitude: 37.3318, longitude: -122.0305))
        let away = CoarsePlace(latitude: 51.5074, longitude: -0.1278)
        XCTAssertNil(KilterPlaceMatcher.suggestion(for: away, in: memory.rememberedSorted))
    }

    func testPlaceMatcherPicksMostRecentAmongSamePlace() {
        let memory = makeMemory()
        let gym = CoarsePlace(latitude: 37.3318, longitude: -122.0305)
        let oldBoard = UUID(), todayBoard = UUID()
        memory.remember(identifier: oldBoard, layoutId: 1, productSizeId: 1,
                        coarsePlace: gym, at: Date(timeIntervalSince1970: 1000))
        memory.remember(identifier: todayBoard, layoutId: 8, productSizeId: 17,
                        coarsePlace: gym, at: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(KilterPlaceMatcher.suggestion(for: gym, in: memory.rememberedSorted)?.id, todayBoard)
    }

    func testPlaceMatcherIgnoresBoardsWithNoStoredPlace() {
        let memory = makeMemory()
        memory.remember(identifier: UUID(), layoutId: 8, productSizeId: 17, coarsePlace: nil)
        let here = CoarsePlace(latitude: 37.3318, longitude: -122.0305)
        XCTAssertNil(KilterPlaceMatcher.suggestion(for: here, in: memory.rememberedSorted))
    }
}
