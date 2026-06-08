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

    // MARK: - Sensor-contact decode (flags bit 2 = SUPPORT, bit 1 = STATUS; NOT a 2-bit enum)

    func testContactStatusGatesOnSupportBit() {
        // No support → unknown, regardless of the status bit (the regression the review caught).
        XCTAssertNil(BLEHeartRateMetricsSource.contactStatus(flags: 0x00))   // support 0, status 0
        XCTAssertNil(BLEHeartRateMetricsSource.contactStatus(flags: 0x02))   // support 0, status 1 → still nil
        // Support set → report the status bit.
        XCTAssertEqual(BLEHeartRateMetricsSource.contactStatus(flags: 0x04), false)  // supported, no contact
        XCTAssertEqual(BLEHeartRateMetricsSource.contactStatus(flags: 0x06), true)   // supported, contact
        // The existing fixture's 0x0E (bits 1,2,3) has both contact bits set → true.
        XCTAssertEqual(BLEHeartRateMetricsSource.contactStatus(flags: 0x0E), true)
    }

    func testParseMeasurementCarriesBpmAndContact() {
        // UInt8, no contact support → bpm only, contact nil.
        XCTAssertEqual(BLEHeartRateMetricsSource.parseMeasurement(Data([0x00, 72])),
                       .init(bpm: 72, contact: nil))
        // UInt8, supported + contact lost (0x04) and supported + contact (0x06).
        XCTAssertEqual(BLEHeartRateMetricsSource.parseMeasurement(Data([0x04, 80])),
                       .init(bpm: 80, contact: false))
        XCTAssertEqual(BLEHeartRateMetricsSource.parseMeasurement(Data([0x06, 80])),
                       .init(bpm: 80, contact: true))
        // UInt8, status-without-support (0x02) → contact nil (not false).
        XCTAssertEqual(BLEHeartRateMetricsSource.parseMeasurement(Data([0x02, 80])),
                       .init(bpm: 80, contact: nil))
        // UInt16 (bit 0) + supported + contact (0x07): 300 = 0x012C.
        XCTAssertEqual(BLEHeartRateMetricsSource.parseMeasurement(Data([0x07, 0x2C, 0x01])),
                       .init(bpm: 300, contact: true))
        // Same short/empty contract as parseHeartRate.
        XCTAssertNil(BLEHeartRateMetricsSource.parseMeasurement(Data()))
        XCTAssertNil(BLEHeartRateMetricsSource.parseMeasurement(Data([0x00])))      // UInt8, no value
        XCTAssertNil(BLEHeartRateMetricsSource.parseMeasurement(Data([0x01, 0x2C]))) // UInt16, one byte
    }

    // MARK: - Ingest gating on contact (no-contact samples are dropped)

    @MainActor
    func testIngestDropsNoContactSampleKeepingLastGood() {
        let src = BLEHeartRateMetricsSource()
        src.ingest(bpm: 120, contact: true)            // good
        XCTAssertEqual(src.latestHR, 120)
        XCTAssertEqual(src.samples.count, 1)
        XCTAssertEqual(src.isContactLost, false)
        // Strap off-skin: drop the garbage bpm, keep the last good value, raise the flag.
        src.ingest(bpm: 0, contact: false)
        XCTAssertEqual(src.latestHR, 120)              // unchanged
        XCTAssertEqual(src.samples.count, 1)           // not appended
        XCTAssertEqual(src.isContactLost, true)
        // Strap back on: ingest resumes and the flag clears (count increments only on good samples).
        src.ingest(bpm: 130, contact: true)
        XCTAssertEqual(src.latestHR, 130)
        XCTAssertEqual(src.samples.count, 2)
        XCTAssertEqual(src.isContactLost, false)
    }

    @MainActor
    func testIngestNilContactLeavesFlagUntouched() {
        let src = BLEHeartRateMetricsSource()
        XCTAssertNil(src.isContactLost)
        src.ingest(bpm: 100, contact: nil)             // band can't report contact
        XCTAssertEqual(src.latestHR, 100)
        XCTAssertEqual(src.samples.count, 1)
        XCTAssertNil(src.isContactLost)                // untouched
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

    func testAutoConnectSkipsSuppressedLoneSystemBand() {
        // The user Forgot the only system-connected band → it must NOT be auto-grabbed, even
        // though it stays connected to iOS (the Fitbit "Forget doesn't stick" bug).
        let pick = BLEBands.bandToAutoConnect(remembered: nil,
                                              suppressed: dev(1).id,
                                              visible: [dev(1, system: true)])
        XCTAssertNil(pick)
    }

    func testAutoConnectUsesOtherSystemBandWhenOneSuppressed() {
        // Forgetting one band shouldn't stop a *different* system-connected band from auto-using.
        let pick = BLEBands.bandToAutoConnect(remembered: nil,
                                              suppressed: dev(1).id,
                                              visible: [dev(1, system: true), dev(2, system: true)])
        XCTAssertEqual(pick?.id, dev(2).id)
    }

    func testAutoConnectSkipsSuppressedRememberedBand() {
        // A remembered-but-Forgotten band must not reconnect via the remembered path either.
        let pick = BLEBands.bandToAutoConnect(remembered: dev(1).id,
                                              suppressed: dev(1).id,
                                              visible: [dev(1, system: true)])
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

    @MainActor
    func testSuppressAutoConnectSticksAndReVettedByAllow() throws {
        let suite = "snappet.test.bandmemory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let id = UUID()
        let memory = BandMemory(defaults: defaults)
        memory.remember(id: id, name: "Google Fitbit Air")

        // Forget → no longer remembered, and suppressed so auto-connect skips it…
        memory.suppressAutoConnect(id: id)
        XCTAssertFalse(memory.hasRemembered)
        XCTAssertEqual(memory.suppressedID, id)
        // …and the suppression survives a "relaunch".
        XCTAssertEqual(BandMemory(defaults: defaults).suppressedID, id)

        // An explicit re-pick clears the suppression (re-opts-in).
        memory.allowAutoConnect(id: id)
        XCTAssertNil(memory.suppressedID)
        // Forgetting a *different* band leaves this one's suppression alone.
        memory.suppressAutoConnect(id: id)
        memory.allowAutoConnect(id: UUID())
        XCTAssertEqual(memory.suppressedID, id)
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
        // Hermetic: back the BLE source with a clean, throwaway BandMemory so a *real* remembered
        // band on a physical device (e.g. "Google Fitbit Air") can't leak into displayName.
        let suite = "snappet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = LiveMetricsCoordinator(
            ble: BLEHeartRateMetricsSource(memory: BandMemory(defaults: defaults)))
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
    func testCoordinatorForwardsContactLost() {
        let suite = "snappet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = LiveMetricsCoordinator(
            ble: BLEHeartRateMetricsSource(memory: BandMemory(defaults: defaults)))
        // Watch path can't report contact → nil; switch to BLE and toggle it.
        coordinator.selectedSource = .appleWatch
        XCTAssertNil(coordinator.isContactLost)
        coordinator.selectedSource = .ble
        XCTAssertNil(coordinator.isContactLost)
        coordinator.ble.ingest(bpm: 0, contact: false)
        XCTAssertEqual(coordinator.isContactLost, true)
        coordinator.ble.ingest(bpm: 140, contact: true)
        XCTAssertEqual(coordinator.isContactLost, false)
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

    /// The `LiveMetricsContext` decoupling: starting via a context (the Kilter path) rebases ingested
    /// samples onto `context.startedAt`, exactly like the routine-driven `start(for:)`.
    @MainActor
    func testLiveMetricsContextRebasesSamples() {
        let start = Date(timeIntervalSince1970: 5_000)
        let source = AppleWatchMetricsSource()
        source.start(LiveMetricsContext(startedAt: start, activityType: .climbing))
        // A watch sample 30s into the session, arriving ~30s after start → engine offset ≈ 30.
        source.ingest(hrBpm: 140, energyKcal: 0, watchOffset: 30, receivedAt: start.addingTimeInterval(30))
        XCTAssertEqual(source.latestHR, 140)
        XCTAssertEqual(source.samples.last?.t ?? -1, 30, accuracy: 0.001)
    }

    /// The coordinator's `start(_:)` (used directly by Kilter sessions) also flips `isSessionActive`.
    @MainActor
    func testContextStartTracksSessionActive() {
        let coordinator = LiveMetricsCoordinator()
        coordinator.start(LiveMetricsContext(startedAt: .now, activityType: .climbing))
        XCTAssertTrue(coordinator.isSessionActive)
        coordinator.stop()
        XCTAssertFalse(coordinator.isSessionActive)
    }
}
