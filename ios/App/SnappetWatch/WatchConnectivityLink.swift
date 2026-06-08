import Foundation
import WatchConnectivity

/// Watch-side `WCSession` endpoint. Receives `start(activityType:)` / `stop` from the
/// phone and sends `metrics(hrBpm:energyKcal:t:)` back. Mirrors the phone's
/// `LiveWorkoutService`; both use the shared `LiveWorkoutMessage` wire shape so the
/// relay can't drift between sides.
///
/// `NSObject` subclass for `WCSessionDelegate`. Callbacks are delivered on a
/// background queue; the closures hop to the `@MainActor` manager themselves.
final class WatchConnectivityLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Phone asked to start a workout of this `HKWorkoutActivityType` raw value, with the user's
    /// resolved max HR (Phase 2) for the on-wrist HR zone and resting HR (Phase 4) for the
    /// recovery-ready nudge — either `nil` when the phone has no profile bound.
    var onStart: ((UInt, Double?, Double?) -> Void)?
    /// Phone asked to stop the workout.
    var onStop: (() -> Void)?
    /// Phone asked to pause the workout (applied without echoing back).
    var onPause: (() -> Void)?
    /// Phone asked to resume the workout.
    var onResume: (() -> Void)?

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Send a live metrics sample to the phone. Uses `sendMessage` when reachable
    /// (lowest latency for a live overlay) and falls back to `transferUserInfo` so a
    /// sample isn't dropped while the phone is briefly unreachable.
    func sendMetrics(hrBpm: Double, energyKcal: Double, t: Double) {
        send(.metrics(hrBpm: hrBpm, energyKcal: energyKcal, t: t))
    }

    /// Relay a watch-initiated control change (pause/resume) to the phone so its overlay +
    /// Live Activity stay in sync. Uses `transferUserInfo` when unreachable so a control isn't
    /// dropped while the phone is briefly away.
    func sendControl(_ message: LiveWorkoutMessage) { send(message) }

    private func send(_ message: LiveWorkoutMessage) {
        guard let session, session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message.payload, replyHandler: nil) { _ in }
        } else {
            session.transferUserInfo(message.payload)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        dispatch(message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        dispatch(userInfo)
    }

    private func dispatch(_ payload: [String: Any]) {
        switch LiveWorkoutMessage(payload: payload) {
        case .start(let activityType, let maxHR, let restHR): onStart?(activityType, maxHR, restHR)
        case .stop: onStop?()
        case .pause: onPause?()
        case .resume: onResume?()
        case .metrics, .none: break   // metrics flow watch → phone only
        }
    }
}
