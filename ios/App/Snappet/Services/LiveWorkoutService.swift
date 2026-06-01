import Foundation
import Observation
import HealthKit
import HighlightEngine
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone-side host for the live workout relay. Starts the matching
/// `HKWorkoutActivityType` on the paired Apple Watch (the watch runs the actual
/// `HKWorkoutSession` + `HKLiveWorkoutBuilder`) and receives streamed heart-rate /
/// energy samples back over `WCSession`, exposing the latest values to the UI and
/// buffering them as engine `HRSample`s for later persistence (B2/B4).
///
/// **Pluggability (A3):** the public surface — `connectionState`, `latestHR`,
/// `energy`, `isWatchReachable`, `start(for:)`, `stop()` and the `HRSample` buffer —
/// is shaped to become a `MetricsSource` protocol with a `BLEHeartRateSource`
/// conformer **without changing call sites**, mirroring how `HighlightSelector` is a
/// protocol with swappable implementations (decisions.md 2026-05-30). The phone never
/// touches a live `HKWorkoutSession` itself — that lives on the watch — so this stays
/// a thin connectivity host, not a second HealthKit path next to `HealthKitService`.
///
/// **Verification honesty:** the relay only truly runs on a paired physical Apple
/// Watch + iPhone; a simulator/type-check proves the shape, not the live stream
/// (RESEARCH.md §3.1, the PLAN's "after A1" device gate).
@MainActor
@Observable
final class LiveWorkoutService: NSObject {

    /// Connection lifecycle, exposed so the UI can show a graceful "no source" state
    /// (A4) without the view knowing about `WCSession`.
    enum ConnectionState: Equatable, Sendable {
        /// `WCSession` unsupported on this device (e.g. iPad / no paired watch capability).
        case unsupported
        /// Supported, not yet activated.
        case inactive
        /// Activated; `isWatchReachable` reports live reachability.
        case active
        /// A live workout is running on the watch.
        case workoutRunning
    }

    private(set) var connectionState: ConnectionState = .inactive
    /// Latest heart rate relayed from the watch (bpm), or `nil` before the first sample.
    private(set) var latestHR: Double?
    /// Latest cumulative active energy relayed from the watch (kcal).
    private(set) var energy: Double = 0
    /// Whether the watch app is currently reachable for an immediate `sendMessage`.
    private(set) var isWatchReachable = false

    /// Buffered HR series for the active session, `t` relative to its `startedAt`.
    /// Kept here (not persisted yet) so B2 can flush it to a per-session HR series.
    private(set) var samples: [HRSample] = []

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

    /// Start a live workout for a session: map its routine sport/category to an
    /// `HKWorkoutActivityType`, tell the watch to begin, and reset the HR buffer
    /// onto this session's `startedAt` timeline.
    func start(for session: WorkoutSession, sport: SportTag?, category: ExerciseCategory?) {
        let type = WorkoutActivityMapping.activityType(sport: sport, category: category)
        start(activityType: type, sessionStart: session.startedAt)
    }

    /// Lower-level start used by the routine-driven `start(for:)` and by tests/A3.
    func start(activityType: HKWorkoutActivityType, sessionStart: Date) {
        self.sessionStart = sessionStart
        samples.removeAll()
        latestHR = nil
        energy = 0
        send(.start(activityType: activityType.rawValue))
        connectionState = .workoutRunning
    }

    /// End the live workout on the watch. The buffered `samples` are retained for B2.
    func stop() {
        send(.stop)
        sessionStart = nil
        if connectionState == .workoutRunning { connectionState = .active }
    }

    // MARK: - Sample ingestion (also the A3 / test seam)

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
extension LiveWorkoutService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        let activated = (state == .activated)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectionState = activated ? .active : .inactive
            self.isWatchReachable = reachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.isWatchReachable = reachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(payload: message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(payload: userInfo)
    }

    private nonisolated func handle(payload: [String: Any]) {
        guard case let .metrics(hr, kcal, t)? = LiveWorkoutMessage(payload: payload) else { return }
        Task { @MainActor [weak self] in
            self?.ingest(hrBpm: hr, energyKcal: kcal, watchOffset: t)
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
