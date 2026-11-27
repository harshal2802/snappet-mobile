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
        // Prompt 265 (F10): a tap for a match / drill no screen here shows (the phone was closed mid-match and
        // relaunched) is answered with `.clear`, so the Watch goes back to its usual face instead of tapping into nothing.
        if RacketWatchClearRule.answersWithClear(commandFor: c.sessionID, attached: attachedID) {
            send(.clear(sessionID: c.sessionID))
            return
        }
        guard ledger.firstTime(c.id) else { return }
        let before = revision
        handler?(c.command, Date())
        // Every tap gets an answer: a tap that changed nothing on the phone (Undo with nothing to undo) re-sends the
        // snapshot, so the Watch can tell "the phone heard me" from "the phone is gone" (`RacketWatchFreshness`).
        let id = c.sessionID
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.attachedID == id, self.revision == before else { return }
            self.republish()
        }
    }

    // MARK: Clearing (prompt 265, F10)

    /// The phone (re)launched: nothing is attached yet, so any racket face on the Watch is left over from before
    /// (an app kill mid-match). Called when WatchConnectivity activates.
    func clearStale() {
        guard RacketWatchClearRule.broadcasts(attached: attachedID, ending: nil) else { return }
        clearAll()
    }

    /// A session ended (finished, discarded, deleted): its racket screens are gone, so is the Watch face.
    /// `exerciseIDs`: the session's exercises (the Watch's `sessionID` is the match / drill entity).
    func sessionEnded(exerciseIDs: Set<UUID>) {
        guard RacketWatchClearRule.broadcasts(attached: attachedID, ending: exerciseIDs) else { return }
        attachedID = nil
        handler = nil
        lastSent = nil
        clearAll()
    }

    private func clearAll() {
        revision += 1
        send(.clearAll(through: revision))
    }

    // MARK: Out

    private func send(_ message: RacketWatchMessage) {
        #if canImport(WatchConnectivity)
        guard WatchSendGate.allowed, isAvailable else { return }   // a UI test never drives the real Watch
        let session = WCSession.default
        if session.isReachable {
            // `@Sendable` (prompt 322): WatchConnectivity runs the error handler on a background queue; a
            // plain closure here would be a main-actor closure that Swift 6 stops the app for there.
            session.sendMessage(message.payload, replyHandler: nil) { @Sendable _ in
                // Delivery failed (the Watch app went to sleep): queue it instead.
                WCSession.default.transferUserInfo(message.payload)
            }
        } else {
            session.transferUserInfo(message.payload)
        }
        #endif
    }
}
