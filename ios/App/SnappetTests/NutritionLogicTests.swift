import XCTest

/// Unit tests for Nutrition pure-logic value types.
/// No device, no HealthKit, no SwiftData — fully platform-free.
final class NutritionLogicTests: XCTestCase {

    // MARK: - NutritionBudget

    func testBudgetRemainingPositive() {
        let b = NutritionBudget(consumed: 1500, goal: 2000, activeBurned: 0)
        XCTAssertEqual(b.remaining, 500, accuracy: 0.01)
    }

    func testBudgetRemainingNegativeWhenOver() {
        let b = NutritionBudget(consumed: 2500, goal: 2000, activeBurned: 0)
        XCTAssertEqual(b.remaining, -500, accuracy: 0.01)
    }

    func testBudgetRingFractionClampedAt1() {
        let b = NutritionBudget(consumed: 4000, goal: 2000, activeBurned: 0)
        XCTAssertEqual(b.ringFraction, 1.0, accuracy: 0.001)
    }

    func testBudgetRingFractionZeroGoal() {
        let b = NutritionBudget(consumed: 0, goal: 0, activeBurned: 0)
        XCTAssertEqual(b.ringFraction, 0, accuracy: 0.001)
    }

    func testBudgetNetSubtractsActiveBurned() {
        let b = NutritionBudget(consumed: 1800, goal: 2000, activeBurned: 300)
        XCTAssertEqual(b.net, 1500, accuracy: 0.01)
    }

    func testMifflinBMRMale() {
        // 80 kg, 180 cm, 30 yr male → 10×80 + 6.25×180 − 5×30 + 5 = 1780
        let bmr = NutritionBudget.mifflinBMR(weightKg: 80, heightCm: 180, ageYears: 30, isMale: true)
        XCTAssertEqual(bmr, 1780, accuracy: 0.01)
    }

    func testMifflinBMRFemale() {
        // 60 kg, 165 cm, 25 yr female → 10×60 + 6.25×165 − 5×25 − 161 = 1345.25
        let bmr = NutritionBudget.mifflinBMR(weightKg: 60, heightCm: 165, ageYears: 25, isMale: false)
        XCTAssertEqual(bmr, 1345.25, accuracy: 0.01)
    }

    // MARK: - MacroSplit

    func testMacroSplitKcalConversions() {
        let m = MacroSplit(proteinG: 50, carbsG: 100, fatG: 20)
        XCTAssertEqual(m.kcalFromProtein, 200, accuracy: 0.01)
        XCTAssertEqual(m.kcalFromCarbs,   400, accuracy: 0.01)
        XCTAssertEqual(m.kcalFromFat,     180, accuracy: 0.01)
        XCTAssertEqual(m.totalKcal,       780, accuracy: 0.01)
    }

    func testMacroSplitFractionsSumToOne() {
        let m = MacroSplit(proteinG: 50, carbsG: 100, fatG: 20)
        let total = m.fraction(of: .protein) + m.fraction(of: .carbs) + m.fraction(of: .fat)
        XCTAssertEqual(total, 1.0, accuracy: 0.001)
    }

    func testMacroSplitAllZeroReturnsZero() {
        let m = MacroSplit(proteinG: 0, carbsG: 0, fatG: 0)
        XCTAssertEqual(m.fraction(of: .protein), 0)
        XCTAssertEqual(m.fraction(of: .carbs),   0)
        XCTAssertEqual(m.fraction(of: .fat),     0)
    }

    // MARK: - ServingMath

    func testServingMathScalesCorrectly() {
        // 100 kcal/100g, 1.5 servings × 200 g = 300 g → 300 kcal
        let s = ServingMath(kcalPer100g: 100, proteinPer100g: 10,
                            carbsPer100g: 20, fatPer100g: 5,
                            servingGrams: 200, quantity: 1.5)
        XCTAssertEqual(s.totalGrams, 300,  accuracy: 0.01)
        XCTAssertEqual(s.kcal,       300,  accuracy: 0.01)
        XCTAssertEqual(s.proteinG,   30,   accuracy: 0.01)
        XCTAssertEqual(s.carbsG,     60,   accuracy: 0.01)
        XCTAssertEqual(s.fatG,       15,   accuracy: 0.01)
    }

    func testServingMathHalfServing() {
        let s = ServingMath(kcalPer100g: 200, proteinPer100g: 20,
                            carbsPer100g: 40, fatPer100g: 10,
                            servingGrams: 100, quantity: 0.5)
        XCTAssertEqual(s.kcal, 100, accuracy: 0.01)
    }

    func testServingMathItemInit() {
        let item = FoodItem(id: "test", name: "Test", brand: nil,
                           kcalPer100g: 200, proteinPer100g: 10,
                           carbsPer100g: 30, fatPer100g: 5,
                           servingSize: 100, servingLabel: "100 g",
                           nutriScore: nil, dataSource: "USDA")
        let s = ServingMath(item: item, servingGrams: 100, quantity: 2)
        XCTAssertEqual(s.kcal, 400, accuracy: 0.01)
    }
}
