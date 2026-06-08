import XCTest
import HighlightEngine
@testable import Snappet

/// Unit tests for the **pure** `UserHRProfile` derivations (fitness-band Phase 2) — no device, no
/// HealthKit, no simulator. Covers the max-HR resolution precedence, the energy gating, the Keytel
/// pass-through, and the prefill merge (blank-fields-only). The HealthKit *reads* themselves and the
/// live watch/widget zone tints are device-pending; this is the math that drives them.
final class UserHRProfileTests: XCTestCase {

    func testResolvedMaxHRPrecedence() {
        // Explicit override wins outright.
        XCTAssertEqual(UserHRProfile(age: 30, restingHR: nil, maxHROverride: 185,
                                     weightKg: nil, sex: .unspecified).resolvedMaxHR, 185)
        // No override → Tanaka 208 − 0.7·age.
        XCTAssertEqual(try XCTUnwrap(UserHRProfile(age: 40, restingHR: nil, maxHROverride: nil,
                                                   weightKg: nil, sex: .male).resolvedMaxHR),
                       208 - 0.7 * 40, accuracy: 0.001)
        // Neither → nil (the honest bpm-only state; callers fall back to defaultMaxHR).
        XCTAssertNil(UserHRProfile.empty.resolvedMaxHR)
        // Garbage ages don't resolve.
        XCTAssertNil(UserHRProfile(age: 0, restingHR: nil, maxHROverride: nil, weightKg: nil, sex: .male).resolvedMaxHR)
        XCTAssertNil(UserHRProfile(age: 200, restingHR: nil, maxHROverride: nil, weightKg: nil, sex: .male).resolvedMaxHR)
    }

    func testRestingBound() {
        XCTAssertEqual(UserHRProfile(age: nil, restingHR: 52, maxHROverride: nil, weightKg: nil, sex: .unspecified).restingBound, 52)
        XCTAssertNil(UserHRProfile(age: nil, restingHR: 0, maxHROverride: nil, weightKg: nil, sex: .unspecified).restingBound)
        XCTAssertNil(UserHRProfile.empty.restingBound)
    }

    func testEnergyGating() {
        // Complete (age + weight + male/female) → can estimate.
        XCTAssertTrue(UserHRProfile(age: 30, restingHR: nil, maxHROverride: nil, weightKg: 75, sex: .male).canEstimateEnergy)
        // Unspecified sex → no estimate (the regression has only male/female terms).
        XCTAssertFalse(UserHRProfile(age: 30, restingHR: nil, maxHROverride: nil, weightKg: 75, sex: .unspecified).canEstimateEnergy)
        // Missing weight → no estimate.
        XCTAssertFalse(UserHRProfile(age: 30, restingHR: nil, maxHROverride: nil, weightKg: nil, sex: .male).canEstimateEnergy)
        // Missing age → no estimate.
        XCTAssertFalse(UserHRProfile(age: nil, restingHR: nil, maxHROverride: nil, weightKg: 75, sex: .male).canEstimateEnergy)
    }

    func testEstimatedKcalGatesAndComputes() {
        let series = (0...600).filter { $0 % 60 == 0 }.map { HRPoint(t: Double($0), bpm: 150) }
        // Gated off when the profile is incomplete.
        XCTAssertNil(UserHRProfile(age: 30, restingHR: nil, maxHROverride: nil, weightKg: 75, sex: .unspecified)
            .estimatedKcal(forSeries: series, durationSec: 600))
        // Computes a positive figure when complete, matching the engine's Keytel total.
        let profile = UserHRProfile(age: 30, restingHR: nil, maxHROverride: nil, weightKg: 75, sex: .male)
        let kcal = try! XCTUnwrap(profile.estimatedKcal(forSeries: series, durationSec: 600))
        let expected = try! XCTUnwrap(EnergyExpenditure.keytelKcal(
            samples: series.map { HRSample(t: $0.t, bpm: $0.bpm) },
            durationSec: 600, ageYears: 30, weightKg: 75, male: true))
        XCTAssertEqual(kcal, expected, accuracy: 0.001)
        XCTAssertGreaterThan(kcal, 0)
    }

    func testMergingFillsOnlyBlanks() {
        let user = UserHRProfile(age: 28, restingHR: nil, maxHROverride: nil, weightKg: nil, sex: .female)
        let prefill = UserHRProfile(age: 99, restingHR: 50, maxHROverride: 190, weightKg: 68, sex: .male)
        let merged = user.merging(prefill: prefill)
        XCTAssertEqual(merged.age, 28)            // user-typed age is preserved, not clobbered
        XCTAssertEqual(merged.sex, .female)       // user-set sex preserved
        XCTAssertEqual(merged.restingHR, 50)      // blank → filled from prefill
        XCTAssertEqual(merged.maxHROverride, 190) // blank → filled
        XCTAssertEqual(merged.weightKg, 68)       // blank → filled
    }
}
