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
    /// Phone asked to start a workout of this `HKWorkoutActivityType` raw value.
    var onStart: ((UInt) -> Void)?
    /// Phone asked to stop the workout.
    var onStop: (() -> Void)?

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
        guard let session, session.activationState == .activated else { return }
        let message = LiveWorkoutMessage.metrics(hrBpm: hrBpm, energyKcal: energyKcal, t: t)
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
        case .start(let activityType): onStart?(activityType)
        case .stop: onStop?()
        case .metrics, .none: break   // metrics flow watch → phone only
        }
    }
}
