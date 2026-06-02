import XCTest
@testable import Snappet

/// Unit tests for the **pure** nutrition math — no device, no simulator, no SwiftUI/SwiftData/
/// HealthKit. Exercises serving scaling, total aggregation (incl. optional-micro handling), the
/// macro-energy split, the calorie-budget model (with and without HealthKit burn data) and the
/// Mifflin–St Jeor BMR. The diary's *visual* and the actual HealthKit write are device-pending;
/// these prove the math's shape (mirrors WorkoutHRStatsTests / ClipEditGeometryTests).
final class NutritionMathTests: XCTestCase {

    // MARK: - ServingMath.scale

    func testScaleMultipliesEveryNutrient() {
        let perServing = Nutrients(kcal: 100, proteinG: 5, carbsG: 10, fatG: 2,
                                   fiberG: 1, sugarG: 4, sodiumG: 0.1)
        let total = ServingMath.scale(perServing, by: 2.5)
        XCTAssertEqual(total.kcal, 250)
        XCTAssertEqual(total.proteinG, 12.5)
        XCTAssertEqual(total.carbsG, 25)
        XCTAssertEqual(total.fatG, 5)
        XCTAssertEqual(total.fiberG, 2.5)
        XCTAssertEqual(total.sugarG, 10)
        XCTAssertEqual(total.sodiumG ?? 0, 0.25, accuracy: 1e-9)
    }

    func testScaleClampsNegativeAndNonFiniteToZero() {
        let n = Nutrients(kcal: 100, proteinG: 5, carbsG: 10, fatG: 2)
        XCTAssertEqual(ServingMath.scale(n, by: -3).kcal, 0)
        XCTAssertEqual(ServingMath.scale(n, by: .nan).kcal, 0)
        XCTAssertEqual(ServingMath.scale(n, by: .infinity).kcal, 0)
    }

    func testScalePreservesNilMicros() {
        let n = Nutrients(kcal: 100, proteinG: 5, carbsG: 10, fatG: 2) // fiber/sugar/sodium nil
        let scaled = ServingMath.scale(n, by: 3)
        XCTAssertNil(scaled.fiberG)
        XCTAssertNil(scaled.sugarG)
        XCTAssertNil(scaled.sodiumG)
    }

    // MARK: - ServingMath.total

    func testTotalSumsEnergyAndMacros() {
        let a = Nutrients(kcal: 100, proteinG: 5, carbsG: 10, fatG: 2)
        let b = Nutrients(kcal: 250, proteinG: 30, carbsG: 0, fatG: 5)
        let total = ServingMath.total([a, b])
        XCTAssertEqual(total.kcal, 350)
        XCTAssertEqual(total.proteinG, 35)
        XCTAssertEqual(total.carbsG, 10)
        XCTAssertEqual(total.fatG, 7)
    }

    func testTotalEmptyIsZero() {
        XCTAssertEqual(ServingMath.total([]), .zero)
    }

    func testTotalMicroIsNilOnlyWhenNoEntryProvidesIt() {
        let withFiber = Nutrients(kcal: 100, proteinG: 0, carbsG: 0, fatG: 0, fiberG: 3)
        let withoutFiber = Nutrients(kcal: 100, proteinG: 0, carbsG: 0, fatG: 0)
        // One provides fiber → fiber sums (treating the other as 0).
        XCTAssertEqual(ServingMath.total([withFiber, withoutFiber]).fiberG, 3)
        // Neither provides sugar → stays nil.
        XCTAssertNil(ServingMath.total([withFiber, withoutFiber]).sugarG)
    }

    // MARK: - MacroSplit

    func testMacroSplitUsesAtwaterFactors() {
        let split = MacroSplit(proteinG: 10, carbsG: 20, fatG: 5)
        XCTAssertEqual(split.proteinKcal, 40)   // 10 × 4
        XCTAssertEqual(split.carbsKcal, 80)     // 20 × 4
        XCTAssertEqual(split.fatKcal, 45)       // 5 × 9
        XCTAssertEqual(split.totalMacroKcal, 165)
    }

    func testMacroFractionsSumToOneAndHandleEmpty() {
        let split = MacroSplit(proteinG: 10, carbsG: 20, fatG: 5)
        let f = split.fractions
        XCTAssertEqual(f.protein + f.carbs + f.fat, 1, accuracy: 1e-9)
        // Empty day → all zero, no NaN.
        let empty = MacroSplit(proteinG: 0, carbsG: 0, fatG: 0).fractions
        XCTAssertEqual(empty.protein, 0)
        XCTAssertEqual(empty.carbs, 0)
        XCTAssertEqual(empty.fat, 0)
    }

    // MARK: - NutritionBudget

    func testBudgetWithoutBurnData() {
        let b = NutritionBudget(targetKcal: 2000, consumedKcal: 1500)
        XCTAssertNil(b.burnedKcal)
        XCTAssertEqual(b.remainingKcal, 500)
        XCTAssertEqual(b.progress, 0.75, accuracy: 1e-9)
        XCTAssertFalse(b.isOverBudget)
    }

    func testBudgetEatsBackBurnedEnergy() {
        let b = NutritionBudget(targetKcal: 2000, consumedKcal: 2200, activeKcal: 300, basalKcal: 1500)
        XCTAssertEqual(b.burnedKcal, 1800)
        // remaining = 2000 − 2200 + 1800 = 1600
        XCTAssertEqual(b.remainingKcal, 1600)
        XCTAssertFalse(b.isOverBudget)
    }

    func testBudgetOverAndProgressClamped() {
        let b = NutritionBudget(targetKcal: 2000, consumedKcal: 2500)
        XCTAssertTrue(b.isOverBudget)
        XCTAssertEqual(b.remainingKcal, -500)
        XCTAssertEqual(b.progress, 1) // clamped, never exceeds a full ring
    }

    func testBudgetZeroTargetDoesNotDivideByZero() {
        let b = NutritionBudget(targetKcal: 0, consumedKcal: 100)
        XCTAssertEqual(b.progress, 1) // adjustedTarget 0 → clamped; no NaN
    }

    // MARK: - BasalEnergy (Mifflin–St Jeor)

    func testMifflinStJeorMaleAndFemale() {
        // 80 kg, 180 cm, 30 y. Male: 10·80 + 6.25·180 − 5·30 + 5 = 1780.
        XCTAssertEqual(BasalEnergy.mifflinStJeor(weightKg: 80, heightCm: 180, ageYears: 30, sex: .male),
                       1780, accuracy: 1e-6)
        // Female: same minus 166 → 1780 − 5 − 161 ... recompute: 800 + 1125 − 150 − 161 = 1614.
        XCTAssertEqual(BasalEnergy.mifflinStJeor(weightKg: 80, heightCm: 180, ageYears: 30, sex: .female),
                       1614, accuracy: 1e-6)
    }

    func testMifflinStJeorClampsToNonNegative() {
        XCTAssertEqual(BasalEnergy.mifflinStJeor(weightKg: 0, heightCm: 0, ageYears: 200, sex: .female), 0)
    }
}
</content>
