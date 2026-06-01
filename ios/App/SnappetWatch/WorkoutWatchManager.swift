import Foundation
import Observation
import HealthKit

/// Owns the live `HKWorkoutSession` + `HKLiveWorkoutBuilder` on the watch, plus their
/// delegates. Starts/ends a session for a given `HKWorkoutActivityType` (chosen by the
/// phone), and publishes the latest heart rate / active energy for the watch UI and for
/// relay over `WCSession`.
///
/// The watchOS *workout-processing* background mode (declared in the watch extension's
/// Info.plist) keeps the session — and therefore HR delivery — alive while the wrist
/// drops and the phone is pocketed; that's the whole reason a companion exists
/// (RESEARCH.md §3.2).
///
/// `@unchecked Sendable`: `HKHealthStore` is documented thread-safe; the mutable state
/// is only mutated on the main actor via the `@MainActor`-hopped delegate callbacks.
@MainActor
@Observable
final class WorkoutWatchManager: NSObject {
    private(set) var latestHR: Double = 0
    private(set) var energyKcal: Double = 0
    private(set) var isRunning = false
    private(set) var elapsed: TimeInterval = 0

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var startDate: Date?

    /// The relay back to the phone. The manager forwards each new HR/energy sample here.
    let link = WatchConnectivityLink()

    override init() {
        super.init()
        link.onStart = { [weak self] activityType in
            Task { @MainActor [weak self] in self?.start(activityType: activityType) }
        }
        link.onStop = { [weak self] in
            Task { @MainActor [weak self] in self?.end() }
        }
        link.activate()
    }

    private let hrUnit = HKUnit.count().unitDivided(by: .minute())
    private let kcalUnit = HKUnit.kilocalorie()

    // MARK: - Authorization

    /// Request the HealthKit types the live builder needs. Called before the first
    /// start (the phone-driven start awaits it).
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [
            HKQuantityType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate),
        ]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
        ]
        try await store.requestAuthorization(toShare: share, read: read)
    }

    // MARK: - Start / end

    func start(activityType raw: UInt) {
        guard !isRunning else { return }
        Task {
            try? await requestAuthorization()
            startSession(activityType: HKWorkoutActivityType(rawValue: raw) ?? .other)
        }
    }

    private func startSession(activityType: HKWorkoutActivityType) {
        let config = HKWorkoutConfiguration()
        config.activityType = activityType
        config.locationType = .unknown
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder
            let start = Date()
            self.startDate = start
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { _, _ in }
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func end() {
        guard let session, let builder else { return }
        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            builder.finishWorkout { _, _ in }
            Task { @MainActor [weak self] in self?.resetState() }
        }
    }

    private func resetState() {
        isRunning = false
        session = nil
        builder = nil
        startDate = nil
        elapsed = 0
    }

    /// Forward the latest metrics to the phone, stamping the watch-relative offset.
    fileprivate func relay() {
        let t = startDate.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = t
        link.sendMetrics(hrBpm: latestHR, energyKcal: energyKcal, t: t)
    }
}

// MARK: - Workout session delegate

extension WorkoutWatchManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor [weak self] in
            self?.isRunning = (toState == .running)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.resetState() }
    }
}

// MARK: - Live builder delegate

extension WorkoutWatchManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        // Read the just-collected statistics off the builder, then hop to the main
        // actor to publish + relay (the builder is the delegate's nonisolated source).
        let hrType = HKQuantityType(.heartRate)
        let kcalType = HKQuantityType(.activeEnergyBurned)
        var newHR: Double?
        var newKcal: Double?
        if collectedTypes.contains(hrType),
           let stats = workoutBuilder.statistics(for: hrType),
           let q = stats.mostRecentQuantity() {
            newHR = q.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }
        if collectedTypes.contains(kcalType),
           let stats = workoutBuilder.statistics(for: kcalType),
           let q = stats.sumQuantity() {
            newKcal = q.doubleValue(for: HKUnit.kilocalorie())
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let newHR { self.latestHR = newHR }
            if let newKcal { self.energyKcal = newKcal }
            self.relay()
        }
    }
}
