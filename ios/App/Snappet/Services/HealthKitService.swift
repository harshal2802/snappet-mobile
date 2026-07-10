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
    /// Measured totals from the `HKWorkout`, when it recorded them (watch import carries them onto the
    /// anchor for the session detail); `nil` for the recent-workouts list path which doesn't read them.
    var energyKcal: Double? = nil
    var distanceMeters: Double? = nil
    /// The workout's specific `HKWorkoutActivityType`, mapped to a display label ("Outdoor Run",
    /// "Functional Strength", …) — finer than the coarse engine `Activity`. `nil` on the list path.
    var activityLabel: String? = nil
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

    /// The long-lived observer for workout background delivery (P2) — retained so it isn't deallocated.
    /// `@unchecked Sendable` on the service covers this; it's written once from the main actor.
    private var workoutObserver: HKObserverQuery?

    /// Register HealthKit **background delivery** for workouts (watch-workouts-clips P2): an
    /// `HKObserverQuery` that fires `onChange` whenever a workout is added/changed — including while the
    /// app is backgrounded — plus `enableBackgroundDelivery` so the system relaunches us for it. The
    /// observer MUST call its completion handler or HealthKit throttles/stops delivery, so we call it
    /// unconditionally after handing off. No-ops where Health is unavailable; needs the
    /// `com.apple.developer.healthkit.background-delivery` entitlement + granted read auth to actually
    /// wake in the background (foreground observation still works without the entitlement).
    func enableWorkoutBackgroundDelivery(onChange: @escaping @Sendable () -> Void) {
        guard HKHealthStore.isHealthDataAvailable(), workoutObserver == nil else { return }
        let type = HKObjectType.workoutType()
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            if error == nil { onChange() }
            completion()   // ALWAYS — or HealthKit backs off future deliveries.
        }
        workoutObserver = query
        store.execute(query)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
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

    /// Completed workouts ending on/after `since`, oldest→newest, for the Apple Watch → Clips import
    /// (`WatchWorkoutImportService`). `since = .distantPast` on first install ⇒ the whole history, so the
    /// Clips feed has content out of the box (only media-bearing workouts actually mint — see the
    /// reconciler). Unlike `recentWorkouts`, this reads each workout's **measured energy + distance**
    /// (carried onto the anchor for the session detail) and a fine-grained activity label.
    func workoutsForImport(since: Date) async throws -> [WorkoutSummary] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)
        let samples = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKSample], Error>) in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: pred,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, result, error in
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
                maxBpm: nil,
                energyKcal: wk.statistics(for: HKQuantityType(.activeEnergyBurned))?
                    .sumQuantity()?.doubleValue(for: .kilocalorie()),
                distanceMeters: Self.distanceMeters(of: wk),
                activityLabel: Self.label(wk.workoutActivityType))
        }
    }

    /// Total distance across the distance quantity types a workout might carry (walk/run, cycling,
    /// swimming, wheelchair, downhill snow), in metres; `nil` when none was recorded.
    private static func distanceMeters(of wk: HKWorkout) -> Double? {
        let types: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
            .distanceWheelchair, .distanceDownhillSnowSports,
        ]
        let total = types.reduce(0.0) { acc, id in
            acc + (wk.statistics(for: HKQuantityType(id))?.sumQuantity()?.doubleValue(for: .meter()) ?? 0)
        }
        return total > 0 ? total : nil
    }

    /// Heart-rate samples for a workout, as engine `HRSample`s (t = seconds from start).
    func heartRateSamples(for summary: WorkoutSummary) async throws -> [HRSample] {
        try await heartRateSamples(start: summary.start, end: summary.end)
    }

    /// Heart-rate samples in an arbitrary `[start, end]` window, as engine `HRSample`s
    /// (`t` = seconds from `start`). The post-hoc read the watch-HR densification uses (HR-granularity
    /// epic / prompt 102): the on-wrist `HKWorkoutSession` stores HR at its full native cadence
    /// (~1 per 1–5 s), denser than the live `WCSession` relay surfaced — so re-reading the session
    /// window recovers the detail the relay thinned. RR is not in `heartRate` samples (watch path has
    /// none anyway). Empty when Health is unavailable / unauthorized / nothing stored for the window.
    func heartRateSamples(start: Date, end: Date) async throws -> [HRSample] {
        guard HKHealthStore.isHealthDataAvailable(), end > start else { return [] }
        let hrType = HKQuantityType(.heartRate)
        let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
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
            HRSample(t: s.startDate.timeIntervalSince(start),
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

    /// A human display label for a workout's `HKWorkoutActivityType` — used as the watch anchor's
    /// `routineName` + Clips title. Deliberately finer than the coarse engine `Activity` (which
    /// collapses everything non-climb/run/dance/strength to `.other`) so a cycle reads "Cycling", not
    /// "Workout". `HKWorkoutActivityType` is an open enum, so the fallback covers everything unlisted.
    static func label(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running:                     return "Run"
        case .walking:                     return "Walk"
        case .hiking:                      return "Hike"
        case .cycling:                     return "Cycling"
        case .climbing:                    return "Climbing"
        case .swimming:                    return "Swim"
        case .rowing:                      return "Rowing"
        case .elliptical:                  return "Elliptical"
        case .traditionalStrengthTraining: return "Strength Training"
        case .functionalStrengthTraining:  return "Functional Strength"
        case .coreTraining:                return "Core Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga:                        return "Yoga"
        case .pilates:                     return "Pilates"
        case .cardioDance, .socialDance:   return "Dance"
        case .barre:                       return "Barre"
        case .cooldown:                    return "Cooldown"
        case .flexibility:                 return "Flexibility"
        case .mixedCardio:                 return "Cardio"
        case .kickboxing:                  return "Kickboxing"
        case .boxing:                      return "Boxing"
        case .jumpRope:                    return "Jump Rope"
        case .stairs, .stepTraining:       return "Stairs"
        default:                           return "Workout"
        }
    }
}
