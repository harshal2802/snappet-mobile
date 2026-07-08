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
    /// The user's resting HR, sent by the phone on start (Phase 4); with `maxHR` it drives the
    /// recovery-ready nudge. `nil` → no nudge.
    private(set) var restHR: Double?

    /// Whether the wrist HR has dropped back near rest — "rested enough for the next set/climb"
    /// (Phase 4). Computed inline (the watch target doesn't link the engine): ready when current
    /// %HRR ≤ 0.40. `false` without both bounds / before the first sample — so no profile ⇒ no nudge,
    /// matching `RecoveryReadiness` on the phone.
    var recoveryReady: Bool {
        guard latestHR > 0, let rest = restHR, let mx = maxHR, mx > rest else { return false }
        let hrr = (latestHR - rest) / (mx - rest)
        return hrr <= 0.40
    }

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var startDate: Date?
    /// Running sample-weighted average for the metrics page (pure, `Shared/`). Folded only
    /// when a builder batch actually collected a new HR statistic — kcal-only batches must
    /// not re-count the stale `latestHR` (#272).
    private var hrAverage = WatchHRAverage()
    /// Pure start/stop gate (`Shared/`): blocks duplicate starts while `start()`'s async
    /// authorization window is open AND absorbs a stop arriving inside that window, so the
    /// stop cancels the start instead of being dropped (#272).
    private var gate = WatchWorkoutStartGate()

    /// The relay back to the phone. The manager forwards each new HR/energy sample here.
    let link = WatchConnectivityLink()

    override init() {
        super.init()
        link.onStart = { [weak self] activityType, maxHR, restHR in
            Task { @MainActor [weak self] in
                self?.start(activityType: activityType, maxHR: maxHR, restHR: restHR)
            }
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

    func start(activityType raw: UInt, maxHR: Double? = nil, restHR: Double? = nil) {
        guard gate.beginStart(isRunning: isRunning) else { return }
        self.maxHR = maxHR
        self.restHR = restHR
        Task {
            try? await requestAuthorization()
            startSession(activityType: HKWorkoutActivityType(rawValue: raw) ?? .other)
        }
    }

    private func startSession(activityType: HKWorkoutActivityType) {
        // A stop relayed while the authorization window was open already cancelled this
        // start — don't create the HKWorkoutSession at all (pre-fix it ran orphaned on the
        // wrist until manually ended).
        guard gate.completeStart() == .proceed else {
            resetState()
            return
        }
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
            hrAverage.reset()
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
        guard let session, let builder else {
            // A stop with no live session yet: if a start's async window is open, absorb it
            // so startSession abandons instead of starting a workout that was already
            // cancelled (pre-fix the stop was silently dropped). A stray stop stays a no-op.
            gate.absorbEndDuringStart()
            return
        }
        session.end()
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            builder.finishWorkout { _, _ in }
            Task { @MainActor [weak self] in self?.resetState() }
        }
    }

    private func resetState() {
        isRunning = false
        gate.reset()
        paused = false
        session = nil
        builder = nil
        startDate = nil
        elapsed = 0
        latestHR = 0
        avgHR = 0
        energyKcal = 0
        hrAverage.reset()
    }

    /// Forward the latest metrics to the phone, stamping the watch-relative offset. `hrUpdated`
    /// says whether THIS builder batch collected a new HR statistic: only then does the reading
    /// fold into the on-watch average and ride the wire as a sample. Kcal-only batches send
    /// `hrBpm: 0` — the shared "no new HR in this message" sentinel the phone's `ingest` honors
    /// (records energy, appends no phantom sample).
    fileprivate func relay(hrUpdated: Bool) {
        if hrUpdated {
            hrAverage.fold(latestHR)
            avgHR = hrAverage.average
        }
        let t = startDate.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = t
        link.sendMetrics(hrBpm: hrUpdated ? latestHR : 0, energyKcal: energyKcal, t: t)
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
            self.relay(hrUpdated: newHR != nil)
        }
    }
}
