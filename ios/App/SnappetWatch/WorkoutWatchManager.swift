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
    private(set) var avgHR: Double = 0
    private(set) var energyKcal: Double = 0
    private(set) var isRunning = false
    /// Whether the session is paused. Pause can be tapped on the watch (its controls page) or
    /// driven from the phone; both converge here via the bidirectional `.pause`/`.resume` relay.
    private(set) var paused = false
    private(set) var elapsed: TimeInterval = 0
    /// The user's resolved max HR, sent by the phone on start (Phase 2). Drives the on-wrist HR-zone
    /// tint via `HeartRateZone.forBpm(_:maxHR:)`; `nil` → the shared `defaultMaxHR`, as before.
    private(set) var maxHR: Double?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var startDate: Date?
    /// Running sum/count of HR samples, for the average shown on the metrics page.
    private var hrSum: Double = 0
    private var hrCount: Int = 0
    /// Set synchronously the instant a start is requested (before the async auth await)
    /// so a second start arriving mid-authorization can't spawn a 2nd `HKWorkoutSession`.
    private var starting = false

    /// The relay back to the phone. The manager forwards each new HR/energy sample here.
    let link = WatchConnectivityLink()

    override init() {
        super.init()
        link.onStart = { [weak self] activityType, maxHR in
            Task { @MainActor [weak self] in self?.start(activityType: activityType, maxHR: maxHR) }
        }
        link.onStop = { [weak self] in
            Task { @MainActor [weak self] in self?.end() }
        }
        link.onPause = { [weak self] in
            Task { @MainActor [weak self] in self?.setPaused(true, propagate: false) }
        }
        link.onResume = { [weak self] in
            Task { @MainActor [weak self] in self?.setPaused(false, propagate: false) }
        }
        link.activate()
    }

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

    func start(activityType raw: UInt, maxHR: Double? = nil) {
        guard !isRunning, !starting else { return }
        starting = true
        self.maxHR = maxHR
        Task {
            try? await requestAuthorization()
            startSession(activityType: HKWorkoutActivityType(rawValue: raw) ?? .other)
        }
    }

    private func startSession(activityType: HKWorkoutActivityType) {
        defer { starting = false }
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
            paused = false
            hrSum = 0
            hrCount = 0
            avgHR = 0
        } catch {
            isRunning = false
        }
    }

    // MARK: - Pause / resume

    /// Pause the workout from the watch UI (relays the pause to the phone).
    func pause() { setPaused(true, propagate: true) }
    /// Resume the workout from the watch UI (relays the resume to the phone).
    func resume() { setPaused(false, propagate: true) }

    /// Apply a paused state. `propagate == true` is a watch-initiated change we relay to the phone;
    /// `false` is us reacting to a phone-initiated change (don't echo it back). Pausing/resuming
    /// the `HKWorkoutSession` stops/restarts HR + energy collection on the wrist.
    private func setPaused(_ shouldPause: Bool, propagate: Bool) {
        guard isRunning, shouldPause != paused else { return }
        paused = shouldPause
        if shouldPause { session?.pause() } else { session?.resume() }
        if propagate { link.sendControl(shouldPause ? .pause : .resume) }
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
        starting = false
        paused = false
        session = nil
        builder = nil
        startDate = nil
        elapsed = 0
        latestHR = 0
        avgHR = 0
        energyKcal = 0
        hrSum = 0
        hrCount = 0
    }

    /// Forward the latest metrics to the phone, stamping the watch-relative offset, and fold the
    /// new HR sample into the running average shown on the metrics page.
    fileprivate func relay() {
        if latestHR > 0 {
            hrSum += latestHR
            hrCount += 1
            avgHR = hrSum / Double(hrCount)
        }
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
            guard let self else { return }
            // A paused session is still "running" for the UI (we keep showing the live face);
            // only an ended/stopped session clears it. `paused` tracks the pause sub-state.
            switch toState {
            case .running:        self.isRunning = true;  self.paused = false
            case .paused:         self.isRunning = true;  self.paused = true
            case .ended, .stopped: self.isRunning = false; self.paused = false
            default:              break
            }
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
