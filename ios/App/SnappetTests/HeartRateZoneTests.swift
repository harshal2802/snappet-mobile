import XCTest
@testable import Snappet

/// Unit tests for the **pure** A4 heart-rate zone mapping — no device, no `MetricsSource`,
/// no SwiftUI rendering. Exercises the bpm→zone boundaries, the nil/no-data case, and a
/// custom max HR. The live overlay's *visual* (zone colors with a real HR stream) is
/// device-pending (decisions.md 2026-06-01, A4); these tests prove the mapping's shape.
final class HeartRateZoneTests: XCTestCase {

    // MARK: - No-data / nil case

    func testNilBpmIsNone() {
        XCTAssertEqual(HeartRateZone.forBpm(nil), .none)
    }

    func testNonPositiveBpmIsNone() {
        XCTAssertEqual(HeartRateZone.forBpm(0), .none)
        XCTAssertEqual(HeartRateZone.forBpm(-5), .none)
    }

    func testNonPositiveMaxHRIsNone() {
        // A degenerate max HR can't yield a meaningful zone → no-data, not a crash.
        XCTAssertEqual(HeartRateZone.forBpm(120, maxHR: 0), .none)
    }

    // MARK: - Boundaries at the default max HR (190)

    func testDefaultMaxHRBoundaries() {
        // < 60% of 190 = < 114 → recovery
        XCTAssertEqual(HeartRateZone.forBpm(100), .recovery)
        XCTAssertEqual(HeartRateZone.forBpm(113), .recovery)
        // exactly 60% (114) is inclusive of the next zone → easy
        XCTAssertEqual(HeartRateZone.forBpm(114), .easy)
        // 70% = 133
        XCTAssertEqual(HeartRateZone.forBpm(132), .easy)
        XCTAssertEqual(HeartRateZone.forBpm(133), .aerobic)
        // 80% = 152
        XCTAssertEqual(HeartRateZone.forBpm(151), .aerobic)
        XCTAssertEqual(HeartRateZone.forBpm(152), .threshold)
        // 90% = 171
        XCTAssertEqual(HeartRateZone.forBpm(170), .threshold)
        XCTAssertEqual(HeartRateZone.forBpm(171), .max)
        // well above max → still max (clamps, never out of range)
        XCTAssertEqual(HeartRateZone.forBpm(210), .max)
    }

    // MARK: - Custom max HR

    func testCustomMaxHRShiftsBoundaries() {
        // With maxHR 200, 70% = 140 → 139 is easy, 140 is aerobic.
        XCTAssertEqual(HeartRateZone.forBpm(139, maxHR: 200), .easy)
        XCTAssertEqual(HeartRateZone.forBpm(140, maxHR: 200), .aerobic)
        // The same 140 bpm at a lower maxHR (160 → 87.5%) is threshold.
        XCTAssertEqual(HeartRateZone.forBpm(140, maxHR: 160), .threshold)
    }

    // MARK: - Labels / pill text

    func testLabels() {
        XCTAssertEqual(HeartRateZone.none.label, "—")
        XCTAssertEqual(HeartRateZone.aerobic.label, "Aerobic")
        XCTAssertEqual(HeartRateZone.max.label, "Max")
    }

    func testPillLabelIncludesZoneNumberExceptNone() {
        XCTAssertEqual(HeartRateZone.aerobic.pillLabel, "Z3 · Aerobic")
        XCTAssertEqual(HeartRateZone.recovery.pillLabel, "Z1 · Recovery")
        // .none has no zone number — it's the inert no-source state.
        XCTAssertEqual(HeartRateZone.none.pillLabel, "—")
    }

    func testAllRealZonesHaveDistinctRawValues() {
        let real = HeartRateZone.allCases.filter { $0 != .none }
        XCTAssertEqual(Set(real.map(\.rawValue)).count, real.count)
        XCTAssertEqual(HeartRateZone.none.rawValue, 0)
    }
}
