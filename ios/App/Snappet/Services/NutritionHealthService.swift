import Foundation
import HealthKit

/// Writes logged meals to HealthKit and reads the day's energy burned for the net-calorie
/// budget. Platform I/O lives here (never in `HighlightEngine`) and the nutrition math is in
/// the pure `NutritionMath` types, so this stays a thin edge.
///
/// `@unchecked Sendable`: the only stored property is `HKHealthStore`, documented thread-safe
/// (same justification as `HealthKitService`). HealthKit is **device-only** — it does not run
/// in the simulator, so this is a clean type-check here, not a verified write.
protocol NutritionHealthWriting: Sendable {
    /// Whether HealthKit is usable on this device at all.
    var isAvailable: Bool { get }
    /// Request write access for the food correlation + nutrient types, and read access for
    /// active/basal energy (Phase 2 budget). Throws if Health data is unavailable.
    func requestAuthorization() async throws
    /// Save one logged food as a `.food` correlation bundling its nutrient samples.
    func saveMeal(name: String, nutrients: Nutrients, date: Date) async throws
    /// Today's energy burned (active, basal) in kcal — `nil` entries when unavailable.
    func todayEnergyBurned() async throws -> (active: Double?, basal: Double?)
}

final class NutritionHealthService: NutritionHealthWriting, @unchecked Sendable {
    private let store = HKHealthStore()

    enum NutritionHealthError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Health data isn't available on this device." }
    }

    // The nutrient types Phase 1 writes (energy + the four macro pillars + the optional
    // micros we capture). Sodium is stored in grams (HealthKit's canonical unit).
    private static let energy = HKQuantityType(.dietaryEnergyConsumed)
    private static let protein = HKQuantityType(.dietaryProtein)
    private static let carbs = HKQuantityType(.dietaryCarbohydrates)
    private static let fat = HKQuantityType(.dietaryFatTotal)
    private static let fiber = HKQuantityType(.dietaryFiber)
    private static let sugar = HKQuantityType(.dietarySugar)
    private static let sodium = HKQuantityType(.dietarySodium)
    private static let foodType = HKCorrelationType(.food)
    private static let activeEnergy = HKQuantityType(.activeEnergyBurned)
    private static let basalEnergy = HKQuantityType(.basalEnergyBurned)

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isAvailable else { throw NutritionHealthError.unavailable }
        let share: Set<HKSampleType> = [Self.foodType, Self.energy, Self.protein, Self.carbs,
                                        Self.fat, Self.fiber, Self.sugar, Self.sodium]
        let read: Set<HKObjectType> = [Self.energy, Self.activeEnergy, Self.basalEnergy]
        try await store.requestAuthorization(toShare: share, read: read)
    }

    func saveMeal(name: String, nutrients n: Nutrients, date: Date) async throws {
        guard isAvailable else { throw NutritionHealthError.unavailable }
        let g = HKUnit.gram()
        var samples: Set<HKSample> = [
            HKQuantitySample(type: Self.energy, quantity: .init(unit: .kilocalorie(), doubleValue: n.kcal), start: date, end: date),
            HKQuantitySample(type: Self.protein, quantity: .init(unit: g, doubleValue: n.proteinG), start: date, end: date),
            HKQuantitySample(type: Self.carbs, quantity: .init(unit: g, doubleValue: n.carbsG), start: date, end: date),
            HKQuantitySample(type: Self.fat, quantity: .init(unit: g, doubleValue: n.fatG), start: date, end: date),
        ]
        if let fiberG = n.fiberG {
            samples.insert(HKQuantitySample(type: Self.fiber, quantity: .init(unit: g, doubleValue: fiberG), start: date, end: date))
        }
        if let sugarG = n.sugarG {
            samples.insert(HKQuantitySample(type: Self.sugar, quantity: .init(unit: g, doubleValue: sugarG), start: date, end: date))
        }
        if let sodiumG = n.sodiumG {
            samples.insert(HKQuantitySample(type: Self.sodium, quantity: .init(unit: g, doubleValue: sodiumG), start: date, end: date))
        }
        let meal = HKCorrelation(type: Self.foodType, start: date, end: date,
                                 objects: samples, metadata: [HKMetadataKeyFoodType: name])
        try await store.save(meal)
    }

    func todayEnergyBurned() async throws -> (active: Double?, basal: Double?) {
        guard isAvailable else { throw NutritionHealthError.unavailable }
        let active = try? await sumToday(Self.activeEnergy)
        let basal = try? await sumToday(Self.basalEnergy)
        return (active, basal)
    }

    /// Cumulative-sum of a kcal quantity type since the start of today. Uses an
    /// `HKStatisticsQuery` so multiple sources are de-duplicated by HealthKit.
    private func sumToday(_ type: HKQuantityType) async throws -> Double {
        let start = Calendar.current.startOfDay(for: .now)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: .now)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0)
            }
            store.execute(q)
        }
    }
}
</content>
