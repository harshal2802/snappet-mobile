import Foundation
import Observation
import HealthKit
import HighlightEngine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Apple-Watch live-metrics source: the phone-side host for the watch relay. Starts the
/// matching `HKWorkoutActivityType` on the paired Apple Watch (the watch runs the actual
/// `HKWorkoutSession` + `HKLiveWorkoutBuilder`) and receives streamed heart-rate / energy
/// samples back over `WCSession`, exposing the latest values to the UI and buffering them
/// as engine `HRSample`s for later persistence (B2/B4).
///
/// This is the A1 `LiveWorkoutService` logic, conformed to the `MetricsSource` protocol
/// with **identical behavior** (decisions.md 2026-06-01, A3): the watch-specific
/// `isWatchReachable` was renamed to the protocol's `isReachable`, and the existing
/// `connectionState` is mapped onto the source-agnostic `state`. The phone never touches a
/// live `HKWorkoutSession` itself — that lives on the watch — so this stays a thin
/// connectivity host, not a second HealthKit path next to `HealthKitService`.
///
/// **Verification honesty:** the relay only truly runs on a paired physical Apple
/// Watch + iPhone; a simulator/type-check proves the shape, not the live stream
/// (RESEARCH.md §3.1, the PLAN's "after A1" device gate).
@MainActor
@Observable
final class AppleWatchMetricsSource: NSObject, MetricsSource {

    /// Watch-specific connection lifecycle. Kept internal (and mapped onto the
    /// source-agnostic `MetricsSourceState` for the protocol) so the coordinator's
    /// default-selection logic can still ask whether a workout is running on the watch.
    enum ConnectionState: Equatable, Sendable {
        /// `WCSession` unsupported on this device (e.g. iPad / no paired watch capability).
        case unsupported
        /// Supported, not yet activated.
        case inactive
        /// Activated; `isReachable` reports live reachability.
        case active
        /// A live workout is running on the watch.
        case workoutRunning
    }

    private(set) var connectionState: ConnectionState = .inactive
    private(set) var latestHR: Double?
    private(set) var energy: Double = 0
    /// Whether the live workout is paused. Pause can be initiated from the phone (the player's
    /// pause control) or from the watch (its controls page); both sides converge on this flag
    /// via the bidirectional `.pause`/`.resume` relay.
    private(set) var isPaused = false
    /// Whether the watch app is currently reachable for an immediate `sendMessage`.
    /// (A1's `isWatchReachable`, renamed to the `MetricsSource` surface.)
    private(set) var isReachable = false

    private(set) var samples: [HRSample] = []

    let displayName = "Apple Watch"

    /// Map the watch-specific `connectionState` (+ whether a sample has arrived) onto the
    /// source-agnostic `MetricsSourceState` the protocol exposes.
    var state: MetricsSourceState {
        switch connectionState {
        case .unsupported: return .unavailable
        case .inactive: return .idle
        case .active: return isReachable ? .connecting : .idle
        case .workoutRunning: return latestHR != nil ? .streaming : .connected
        }
    }

    /// The wall-clock start of the session we're buffering against. Incoming watch
    /// samples carry `t` relative to the *watch* session start; we re-base them onto
    /// the `WorkoutSession.startedAt` timeline so the buffer matches the post-hoc
    /// `HealthKitService` convention (HRSample.t = seconds since the session began).
    private var sessionStart: Date?

    #if canImport(WatchConnectivity)
    private let session: WCSession?
    #endif

    override init() {
        #if canImport(WatchConnectivity)
        session = WCSession.isSupported() ? WCSession.default : nil
        #endif
        super.init()
        #if canImport(WatchConnectivity)
        if let session {
            session.delegate = self
            session.activate()
        } else {
            connectionState = .unsupported
        }
        #else
        connectionState = .unsupported
        #endif
    }

    // MARK: - Start / stop

    func start(_ context: LiveMetricsContext) {
        start(activityType: context.activityType, sessionStart: context.startedAt,
              maxHR: context.maxHR, restHR: context.restHR)
    }

    /// Lower-level start used by `start(_:)` and by tests/A3. `maxHR` (the profile's resolved max,
    /// Phase 2) + `restHR` (Phase 4) ride the start message so the watch personalizes its HR zone and
    /// computes the recovery-ready nudge; `nil` → the watch keeps the default ceiling / shows no nudge.
    func start(activityType: HKWorkoutActivityType, sessionStart: Date,
               maxHR: Double? = nil, restHR: Double? = nil) {
        self.sessionStart = sessionStart
        samples.removeAll()
        latestHR = nil
        energy = 0
        isPaused = false
        send(.start(activityType: activityType.rawValue, maxHR: maxHR, restHR: restHR))
        // Only claim "running" when there's actually a watch to run it — otherwise the
        // A4 overlay would sit at "Waiting for heart rate…" forever (no watch installed).
        if watchUsable { connectionState = .workoutRunning }
    }

    func stop() {
        send(.stop)
        sessionStart = nil
        isPaused = false
        if connectionState == .workoutRunning { connectionState = .active }
    }

    /// Pause the workout on the watch (UI-initiated on the phone). Tells the watch to pause its
    /// `HKWorkoutSession` and flips the local flag. The watch applies the pause without echoing
    /// it back, so this can't ping-pong.
    func pause() { setPaused(true, propagate: true) }
    /// Resume the workout on the watch (UI-initiated on the phone).
    func resume() { setPaused(false, propagate: true) }

    /// Apply a paused state. `propagate == true` relays the change to the watch (phone-initiated);
    /// `false` means we're *reacting* to a watch-initiated change and must not echo it back.
    private func setPaused(_ paused: Bool, propagate: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if propagate { send(paused ? .pause : .resume) }
    }

    // MARK: - Sample ingestion (also the test seam)

    /// Ingest one relayed metrics message. Pure given `sessionStart`, so it is
    /// unit-testable without a device: it computes the HR sample's offset on the
    /// *session* timeline and appends it to the buffer.
    func ingest(hrBpm: Double, energyKcal: Double, watchOffset t: Double, receivedAt: Date = .now) {
        latestHR = hrBpm
        energy = energyKcal
        let offset = Self.sessionOffset(watchOffset: t, sessionStart: sessionStart, receivedAt: receivedAt)
        samples.append(HRSample(t: offset, bpm: hrBpm))
    }

    /// Re-base a watch-relative sample offset onto the session timeline.
    ///
    /// The watch reports `t` seconds since *its* session started. The phone's
    /// `WorkoutSession.startedAt` is the authoritative zero for the engine's
    /// `HRSample.t`. When we don't yet know the session start (a stray sample before
    /// `start(for:)`), fall back to `receivedAt − sessionStart`, and otherwise to the
    /// raw watch offset. The result is clamped to ≥ 0 so a clock skew can't produce a
    /// negative engine offset.
    static func sessionOffset(watchOffset t: Double, sessionStart: Date?, receivedAt: Date) -> Double {
        guard let sessionStart else { return max(0, t) }
        // The watch session is started right after the phone stamps `startedAt`, so
        // the watch offset is a good proxy for the session offset; we keep the wall-
        // clock arrival only as a sanity floor. Prefer the watch's own monotonic `t`.
        let elapsed = receivedAt.timeIntervalSince(sessionStart)
        // If the relayed offset is wildly ahead of wall-clock elapsed (shouldn't
        // happen), trust the wall clock; otherwise trust the watch's monotonic clock.
        let chosen = (t <= elapsed + 5) ? t : elapsed
        return max(0, chosen)
    }

    /// Whether a paired watch with our companion app installed is available. Used to
    /// avoid promoting to `.workoutRunning` (and stranding the UI at "Waiting for heart
    /// rate…") when there is no watch that can actually start a session. The coordinator
    /// reads this for its default source selection (prefer the watch when usable).
    var watchUsable: Bool {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated else { return false }
        return session.isPaired && session.isWatchAppInstalled
        #else
        return false
        #endif
    }

    // MARK: - Send

    private func send(_ message: LiveWorkoutMessage) {
        #if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message.payload, replyHandler: nil) { [weak self] _ in
                // Delivery failed (watch asleep / unreachable) — queue it instead so
                // a start/stop isn't silently dropped.
                Task { @MainActor [weak self] in self?.queue(message) }
            }
        } else {
            queue(message)
        }
        #endif
    }

    #if canImport(WatchConnectivity)
    private func queue(_ message: LiveWorkoutMessage) {
        session?.transferUserInfo(message.payload)
    }
    #endif
}

#if canImport(WatchConnectivity)
extension AppleWatchMetricsSource: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        let activated = (state == .activated)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectionState = activated ? .active : .inactive
            self.isReachable = reachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.isReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(payload: message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(payload: userInfo)
    }

    private nonisolated func handle(payload: [String: Any]) {
        switch LiveWorkoutMessage(payload: payload) {
        case let .metrics(hr, kcal, t)?:
            Task { @MainActor [weak self] in
                self?.ingest(hrBpm: hr, energyKcal: kcal, watchOffset: t)
            }
        case .pause?:
            // Watch-initiated pause → reflect it locally without echoing back.
            Task { @MainActor [weak self] in self?.setPaused(true, propagate: false) }
        case .resume?:
            Task { @MainActor [weak self] in self?.setPaused(false, propagate: false) }
        case .start?, .stop?, .none:
            break   // start/stop flow phone → watch only
        }
    }

    // iOS requires these two delegate stubs; the watch can deactivate when paired
    // with a new device, so we re-activate to keep the relay alive.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#endif
