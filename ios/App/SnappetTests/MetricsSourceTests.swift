import XCTest
@testable import Snappet

/// Unit tests for the **pure** A3 pieces — no device, no CoreBluetooth, no band:
/// the Heart Rate Measurement byte parser and the source-selection rule. The live BLE
/// connect + HR stream is device-pending (decisions.md 2026-06-01, A3).
final class BLEHeartRateParserTests: XCTestCase {

    // MARK: - HR measurement parsing (flags byte: bit 0 = UInt8 vs UInt16)

    func testUInt8Format() {
        // flags 0x00 → bit 0 clear → next byte is UInt8 bpm.
        let data = Data([0x00, 72])
        XCTAssertEqual(BLEHeartRateMetricsSource.parseHeartRate(data), 72)
    }

    func testUInt16Format() {
        // flags 0x01 → bit 0 set → next two bytes are little-endian UInt16 bpm.
        // 300 = 0x012C → bytes [0x2C, 0x01].
        let data = Data([0x01, 0x2C, 0x01])
        XCTAssertEqual(BLEHeartRateMetricsSource.parseHeartRate(data), 300)
    }

    func testUInt8WithSensorContactAndEnergyFlags() {
        // flags 0x0E = bits 1,2,3 set (sensor-contact + energy-expended present), bit 0
        // clear → UInt8 bpm in byte 1. We only read bpm; trailing fields are ignored.
        let data = Data([0x0E, 88, 0x10, 0x00])   // 88 bpm + a 2-byte energy field
        XCTAssertEqual(BLEHeartRateMetricsSource.parseHeartRate(data), 88)
    }

    func testUInt16WithExtraFields() {
        // flags 0x09 = bit 0 (UInt16) + bit 3 (energy present). bpm 130 = 0x0082.
        let data = Data([0x09, 0x82, 0x00, 0x20, 0x00])
        XCTAssertEqual(BLEHeartRateMetricsSource.parseHeartRate(data), 130)
    }

    func testEmptyBufferIsNil() {
        XCTAssertNil(BLEHeartRateMetricsSource.parseHeartRate(Data()))
    }

    func testShortUInt8BufferIsNil() {
        // flags say UInt8 but no value byte present.
        XCTAssertNil(BLEHeartRateMetricsSource.parseHeartRate(Data([0x00])))
    }

    func testShortUInt16BufferIsNil() {
        // flags say UInt16 but only one value byte present.
        XCTAssertNil(BLEHeartRateMetricsSource.parseHeartRate(Data([0x01, 0x2C])))
    }

    func testFlagsOnlyUInt16BufferIsNil() {
        // flags say UInt16 but NO value bytes at all (a 1-byte packet) — must not crash.
        XCTAssertNil(BLEHeartRateMetricsSource.parseHeartRate(Data([0x01])))
    }

    // MARK: - Session-relative offset (wall-clock, clamped ≥ 0)

    func testBLEOffsetUsesWallClock() {
        let start = Date(timeIntervalSince1970: 2_000)
        let t = BLEHeartRateMetricsSource.sessionOffset(sessionStart: start,
                                                        receivedAt: start.addingTimeInterval(12))
        XCTAssertEqual(t, 12, accuracy: 0.001)
    }

    func testBLEOffsetClampsNonNegative() {
        let start = Date(timeIntervalSince1970: 2_000)
        let t = BLEHeartRateMetricsSource.sessionOffset(sessionStart: start,
                                                        receivedAt: start.addingTimeInterval(-3))
        XCTAssertGreaterThanOrEqual(t, 0)
    }

    func testBLEOffsetWithoutSessionStartIsZero() {
        XCTAssertEqual(BLEHeartRateMetricsSource.sessionOffset(sessionStart: nil, receivedAt: .now), 0)
    }

    @MainActor
    func testBLEIngestBuffersAndStreams() {
        let src = BLEHeartRateMetricsSource()
        let start = Date(timeIntervalSince1970: 9_000)
        // (no `start(for:)` available without a WorkoutSession here; ingest uses .now and
        // clamps, so just assert buffering + state + energy contract)
        src.ingest(bpm: 110, receivedAt: start.addingTimeInterval(5))
        XCTAssertEqual(src.latestHR, 110)
        XCTAssertEqual(src.samples.count, 1)
        XCTAssertEqual(src.energy, 0)                 // HR profile has no energy
        XCTAssertEqual(src.state, .streaming)
    }
}

/// Auto-detection / "remember my band" rules — all pure, no CoreBluetooth, no device.
/// These back the user-friendly band connection (auto-detect an already-connected band +
/// reconnect the last-used one without re-picking).
final class BLEBandAutoDetectTests: XCTestCase {

    private func dev(_ n: Int, name: String? = nil, system: Bool = false) -> BLEDevice {
        BLEDevice(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!,
                  name: name ?? "Band \(n)", isSystemConnected: system)
    }

    // MARK: - merge(systemConnected:scanned:)

    func testMergePutsSystemConnectedFirstAndDedupes() {
        let a = dev(1, system: true)
        let b = dev(2)
        let aScanned = dev(1)   // same id as `a` but found by scanning too
        let merged = BLEBands.merge(systemConnected: [a], scanned: [aScanned, b])
        XCTAssertEqual(merged.map(\.id), [a.id, b.id])     // no duplicate of id 1
        XCTAssertTrue(merged[0].isSystemConnected)          // system-connected entry wins
    }

    func testMergeKeepsScannedOnlyDevices() {
        let merged = BLEBands.merge(systemConnected: [], scanned: [dev(2), dev(3)])
        XCTAssertEqual(merged.map(\.id), [dev(2).id, dev(3).id])
    }

    // MARK: - displayList(discovered:rememberedID:rememberedName:)

    func testDisplayListSynthesizesUnseenRememberedBand() {
        let list = BLEBands.displayList(discovered: [dev(2)],
                                        rememberedID: dev(1).id,
                                        rememberedName: "Polar H10")
        XCTAssertEqual(list.first?.id, dev(1).id)           // remembered leads
        XCTAssertEqual(list.first?.name, "Polar H10")
        XCTAssertEqual(list.count, 2)
    }

    func testDisplayListDoesNotDuplicateVisibleRememberedBand() {
        let list = BLEBands.displayList(discovered: [dev(1), dev(2)],
                                        rememberedID: dev(1).id,
                                        rememberedName: "Band 1")
        XCTAssertEqual(list.map(\.id), [dev(1).id, dev(2).id])   // unchanged, no synthetic row
    }

    func testDisplayListWithNoMemoryIsJustDiscovered() {
        let list = BLEBands.displayList(discovered: [dev(2)], rememberedID: nil, rememberedName: nil)
        XCTAssertEqual(list.map(\.id), [dev(2).id])
    }

    // MARK: - bandToAutoConnect(remembered:visible:)

    func testAutoConnectPrefersRememberedWhenVisible() {
        let pick = BLEBands.bandToAutoConnect(remembered: dev(2).id,
                                              visible: [dev(1, system: true), dev(2)])
        XCTAssertEqual(pick?.id, dev(2).id)                 // remembered beats a system-connected other
    }

    func testAutoConnectUsesSingleSystemConnectedWhenNoMemory() {
        let pick = BLEBands.bandToAutoConnect(remembered: nil, visible: [dev(1, system: true)])
        XCTAssertEqual(pick?.id, dev(1).id)
    }

    func testAutoConnectAmbiguousReturnsNil() {
        // Two system-connected bands and no memory → a real choice, leave it to the user.
        let pick = BLEBands.bandToAutoConnect(remembered: nil,
                                              visible: [dev(1, system: true), dev(2, system: true)])
        XCTAssertNil(pick)
    }

    func testAutoConnectNoSystemConnectedScanOnlyReturnsNil() {
        let pick = BLEBands.bandToAutoConnect(remembered: nil, visible: [dev(1), dev(2)])
        XCTAssertNil(pick)
    }

    // MARK: - BandMemory round-trip (isolated UserDefaults suite)

    @MainActor
    func testBandMemoryRemembersAndForgets() throws {
        let suite = "snappet.test.bandmemory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = BandMemory(defaults: defaults)
        XCTAssertFalse(memory.hasRemembered)

        let id = UUID()
        memory.remember(id: id, name: "Wahoo TICKR")
        XCTAssertTrue(memory.hasRemembered)
        XCTAssertEqual(memory.rememberedID, id)
        XCTAssertEqual(memory.rememberedName, "Wahoo TICKR")

        // A fresh instance over the same suite sees the persisted band (survives "relaunch").
        let reloaded = BandMemory(defaults: defaults)
        XCTAssertEqual(reloaded.rememberedID, id)

        memory.forget()
        XCTAssertFalse(memory.hasRemembered)
        XCTAssertNil(BandMemory(defaults: defaults).rememberedID)
    }
}

/// Source-selection rule: explicit pick wins; else prefer the watch when usable; else BLE
/// if a band is known (chosen or remembered); else default to the watch (its `.unavailable`
/// drives the UI).
final class MetricsSourceSelectionTests: XCTestCase {

    func testPrefersWatchWhenUsable() {
        XCTAssertEqual(
            LiveMetricsCoordinator.resolve(selected: nil, watchUsable: true, hasBLEDevice: false),
            .appleWatch)
    }

    func testPrefersWatchEvenWhenBLEAlsoPresent() {
        XCTAssertEqual(
            LiveMetricsCoordinator.resolve(selected: nil, watchUsable: true, hasBLEDevice: true),
            .appleWatch)
    }

    func testFallsBackToBLEWhenNoWatchButBandChosen() {
        XCTAssertEqual(
            LiveMetricsCoordinator.resolve(selected: nil, watchUsable: false, hasBLEDevice: true),
            .ble)
    }

    func testDefaultsToWatchWhenNeitherAvailable() {
        XCTAssertEqual(
            LiveMetricsCoordinator.resolve(selected: nil, watchUsable: false, hasBLEDevice: false),
            .appleWatch)
    }

    func testExplicitBLEPickWinsOverUsableWatch() {
        XCTAssertEqual(
            LiveMetricsCoordinator.resolve(selected: .ble, watchUsable: true, hasBLEDevice: true),
            .ble)
    }

    func testExplicitWatchPickWinsEvenWithNoWatch() {
        XCTAssertEqual(
            LiveMetricsCoordinator.resolve(selected: .appleWatch, watchUsable: false, hasBLEDevice: true),
            .appleWatch)
    }

    @MainActor
    func testCoordinatorForwardsToActiveSource() {
        let coordinator = LiveMetricsCoordinator()
        // No watch usable in the test env; pick BLE explicitly and feed a sample.
        coordinator.selectedSource = .ble
        coordinator.ble.ingest(bpm: 142)
        XCTAssertEqual(coordinator.activeKind, .ble)
        XCTAssertEqual(coordinator.latestHR, 142)
        XCTAssertEqual(coordinator.energy, 0)
        XCTAssertEqual(coordinator.samples.count, 1)
        XCTAssertEqual(coordinator.displayName, "Heart-rate band")
    }

    @MainActor
    func testIsSessionActiveTracksStartStop() {
        let coordinator = LiveMetricsCoordinator()
        XCTAssertFalse(coordinator.isSessionActive)
        let session = WorkoutSession(routineName: "Test")
        coordinator.start(for: session, sport: nil, category: nil)
        XCTAssertTrue(coordinator.isSessionActive)   // resume guard relies on this (source-agnostic)
        coordinator.stop()
        XCTAssertFalse(coordinator.isSessionActive)
    }
}
