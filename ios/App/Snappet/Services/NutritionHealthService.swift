import Foundation
import HealthKit

/// Writes food correlations to Apple Health and reads active+basal energy.
/// `@unchecked Sendable`: HKHealthStore is documented thread-safe.
final class NutritionHealthService: @unchecked Sendable {
    private let store = HKHealthStore()

    enum HealthError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Health data is not available on this device." }
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        let write: Set<HKSampleType> = [
            HKQuantityType(.dietaryEnergyConsumed),
            HKQuantityType(.dietaryProtein),
            HKQuantityType(.dietaryCarbohydrates),
            HKQuantityType(.dietaryFatTotal),
        ]
        try await store.requestAuthorization(toShare: write, read: [])
    }

    /// Write one food log entry as an HKCorrelation of type .food.
    func write(entry: FoodLogEntry) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let date = entry.loggedAt

        func sample(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit) -> HKQuantitySample {
            HKQuantitySample(
                type: HKQuantityType(id),
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: date, end: date
            )
        }

        let samples: Set<HKSample> = [
            sample(.dietaryEnergyConsumed, entry.kcal,     .kilocalorie()),
            sample(.dietaryProtein,        entry.proteinG, .gram()),
            sample(.dietaryCarbohydrates,  entry.carbsG,   .gram()),
            sample(.dietaryFatTotal,       entry.fatG,     .gram()),
        ]

        let correlation = HKCorrelation(
            type: HKCorrelationType(.food),
            start: date, end: date,
            objects: samples
        )
        try? await store.save(correlation)
    }
}
