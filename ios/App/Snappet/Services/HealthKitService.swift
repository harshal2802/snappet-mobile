import Foundation
import HealthKit
import HighlightEngine

/// A completed workout as surfaced to the UI (HealthKit-backed).
struct WorkoutSummary: Identifiable, Hashable {
    let id: UUID
    let activity: Activity
    let start: Date
    let end: Date
    let restingBpm: Double?
    let maxBpm: Double?
    var duration: Double { end.timeIntervalSince(start) }
    var dateInterval: DateInterval { DateInterval(start: start, end: end) }
}

/// Reads COMPLETED workouts + their heart-rate series from HealthKit.
///
/// v1 deliberately uses post-hoc reads (no live watchOS relay): the user does a
/// normal Apple Watch workout, then Snappet reads it once it has synced to the
/// phone. This is the authoritative HR series the research recommends for highlight
/// detection (#60 §3), and it makes v1 runnable today with existing workouts.
/// `@unchecked Sendable`: the only stored property is `HKHealthStore`, which Apple
/// documents as thread-safe, so this service can be called across actor boundaries.
final class HealthKitService: @unchecked Sendable {
    private let store = HKHealthStore()

    enum HealthError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Health data isn't available on this device." }
    }

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        let types: Set<HKObjectType> = [
            .workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            // Read-only characteristics + body mass, for the HR-profile prefill (Phase 2). Requesting
            // them here (alongside the existing reads) means the profile "Use Health data" button
            // doesn't trigger a second permission sheet.
            HKQuantityType(.bodyMass),
            HKCharacteristicType(.dateOfBirth),
            HKCharacteristicType(.biologicalSex),
        ]
        try await store.requestAuthorization(toShare: [], read: types)
    }

    /// Best-effort prefill for the user's HR profile from Health: age (from date-of-birth), biological
    /// sex, latest body mass, and resting heart rate. Each field is independent — a missing/denied one
    /// is simply left `nil` so the caller merges only what's available into blank profile fields
    /// (`UserHRProfile.merging(prefill:)`), never clobbering a user-typed value. Device-only; on the
    /// simulator / without authorization it returns an empty profile.
    func profilePrefill() async -> UserHRProfile {
        guard HKHealthStore.isHealthDataAvailable() else { return .empty }
        var out = UserHRProfile.empty

        if let dob = try? store.dateOfBirthComponents(),
           let years = Calendar.current.dateComponents([.year], from: dob.date ?? .distantPast, to: .now).year,
           years > 0, years < 120 {
            out.age = years
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            switch sex {
            case .female: out.sex = .female
            case .male:   out.sex = .male
            default:      out.sex = .unspecified
            }
        }
        if let kg = try? await latestBodyMassKg() { out.weightKg = kg }
        if let rest = try? await latestRestingHeartRate() { out.restingHR = Int(rest.rounded()) }
        return out
    }

    private func latestBodyMassKg() async throws -> Double? {
        let type = HKQuantityType(.bodyMass)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKSample], Error>) in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: r ?? []) }
            }
            store.execute(q)
        }
        return (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: .gramUnit(with: .kilo))
    }

    func recentWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKSample], Error>) in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: nil,
                                  limit: limit, sortDescriptors: [sort]) { _, result, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: result ?? []) }
            }
            store.execute(q)
        }
        let restingBpm = try? await latestRestingHeartRate()
        return samples.compactMap { $0 as? HKWorkout }.map { wk in
            WorkoutSummary(
                id: wk.uuid,
                activity: Self.map(wk.workoutActivityType),
                start: wk.startDate,
                end: wk.endDate,
                restingBpm: restingBpm,
                maxBpm: nil   // estimated by the engine if absent
            )
        }
    }

    /// Heart-rate samples for a workout, as engine `HRSample`s (t = seconds from start).
    func heartRateSamples(for summary: WorkoutSummary) async throws -> [HRSample] {
        let hrType = HKQuantityType(.heartRate)
        let pred = HKQuery.predicateForSamples(withStart: summary.start, end: summary.end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKSample], Error>) in
            let q = HKSampleQuery(sampleType: hrType, predicate: pred,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, result, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: result ?? []) }
            }
            store.execute(q)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.compactMap { $0 as? HKQuantitySample }.map { s in
            HRSample(t: s.startDate.timeIntervalSince(summary.start),
                     bpm: s.quantity.doubleValue(for: unit))
        }
    }

    private func latestRestingHeartRate() async throws -> Double? {
        let type = HKQuantityType(.restingHeartRate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKSample], Error>) in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: r ?? []) }
            }
            store.execute(q)
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return (samples.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
    }

    private static func map(_ t: HKWorkoutActivityType) -> Activity {
        switch t {
        case .climbing: return .climbing
        case .running: return .running
        case .cardioDance, .socialDance, .barre: return .dance
        case .traditionalStrengthTraining, .functionalStrengthTraining: return .strength
        default: return .other
        }
    }
}
