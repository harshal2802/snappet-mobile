import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// The phone end of the racket Watch wire (prompt 245, issue #438 step 2): sends `RacketWatchState` snapshots to the
/// Watch and hands its taps to whichever racket screen is attached. No decisions here — the mapping is
/// `RacketWatchBridge` / `RacketWatchMatch` (pure, tested); the message shape is `Shared/RacketWatchMessage.swift`.
///
/// The phone's `WCSessionDelegate` is `AppleWatchMetricsSource` (created by `AppModel` at launch); it forwards racket
/// payloads here (`receive(payload:)`). Sending uses `WCSession.default` directly, like `HouseholdSurfaces`:
/// `sendMessage` while reachable (a live screen), else `transferUserInfo` (queued; the revision makes a late copy
/// harmless). Application context stays household's.
///
/// **Verification honesty:** the relay only runs on a paired iPhone + Apple Watch; tests pin the mapping and the wire.
@MainActor
final class RacketWatchRelay {
    static let shared = RacketWatchRelay()

    /// Rises with every snapshot; seeded from the clock so it keeps rising across relaunches.
    private var revision = Int(Date().timeIntervalSince1970 * 10)
    private var attachedID: UUID?
    private var handler: ((RacketWatchCommand, Date) -> Void)?
    private var attachToken = UUID()
    private var lastSent: RacketWatchState?
    private var ledger = RacketWatchCommandLedger()

    private init() {}

    /// A paired Watch with Snappet installed (the simulator and an iPad say no).
    var isAvailable: Bool {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return false }
        let s = WCSession.default
        return s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
        #else
        return false
        #endif
    }

    /// The racket screen now on the phone takes the Watch's taps for `sessionID` (one at a time: the recording
    /// screen covers the match page, so the latest attach wins).
    @discardableResult
    func attach(_ sessionID: UUID, handler: @escaping (RacketWatchCommand, Date) -> Void) -> UUID {
        if attachedID != sessionID { lastSent = nil }
        attachedID = sessionID
        self.handler = handler
        attachToken = UUID()
        return attachToken
    }

    /// Detach only if `token`'s attach is still the current one: a screen leaving after the page re-attached the same
    /// match (the game-by-game screen closing, prompt 249) must not take the Watch away from the page.
    func detach(_ sessionID: UUID, token: UUID) {
        guard token == attachToken else { return }
        detach(sessionID)
    }

    /// The screen left. The Watch goes back to its usual face.
    func detach(_ sessionID: UUID) {
        guard attachedID == sessionID else { return }
        attachedID = nil
        handler = nil
        lastSent = nil
        send(.clear(sessionID: sessionID))
    }

    /// Send `state` if it differs from the last one sent (states carry absolute times, so they only change on events).
    func publish(_ state: RacketWatchState) {
        guard state.sessionID == attachedID else { return }
        var s = state
        if let last = lastSent {
            var cmp = last
            cmp.revision = s.revision
            if cmp == s { return }
        }
        revision += 1
        s.revision = revision
        lastSent = s
        send(.state(s))
    }

    /// Re-send the last snapshot (the Watch became reachable, or asked).
    func republish() {
        guard let last = lastSent else { return }
        revision += 1
        var s = last
        s.revision = revision
        lastSent = s
        send(.state(s))
    }

    // MARK: In

    /// Called off the main actor by the phone's `WCSessionDelegate`. `true` ⇒ it was a racket message.
    nonisolated static func receive(payload: [String: Any]) -> Bool {
        guard payload[RacketWatchMessage.kindKey] != nil else { return false }
        guard case .command(let c)? = RacketWatchMessage(payload: payload) else { return true }
        Task { @MainActor in RacketWatchRelay.shared.deliver(c) }
        return true
    }

    func deliver(_ c: RacketWatchCommandEnvelope) {
        guard c.sessionID == attachedID, ledger.firstTime(c.id) else { return }
        handler?(c.command, Date())
    }

    // MARK: Out

    private func send(_ message: RacketWatchMessage) {
        #if canImport(WatchConnectivity)
        guard isAvailable else { return }
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(message.payload, replyHandler: nil) { _ in
                // Delivery failed (the Watch app went to sleep): queue it instead.
                WCSession.default.transferUserInfo(message.payload)
            }
        } else {
            session.transferUserInfo(message.payload)
        }
        #endif
    }
}
