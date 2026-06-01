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

/// Source-selection rule: explicit pick wins; else prefer the watch when usable; else BLE
/// if a band was chosen; else default to the watch (its `.unavailable` drives the UI).
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
