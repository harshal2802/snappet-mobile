import Foundation
import Observation
import WatchKit

/// The Watch end of a racket match / drill running on the phone (prompt 245, issue #438 step 2). Holds the phone's
/// latest snapshot, sends taps back, shows a score tap at once (the phone's next snapshot wins) and taps the wrist
/// when the phase changes. Every rule here is the pure, tested `Shared/RacketWatchMessage.swift`
/// (`accepts`, `applyingOptimistically`, `RacketWatchCue`) and `Shared/RacketWatchFreshness.swift` (prompt 265: leave a
/// face the phone has left); this class only holds state and plays haptics.
@MainActor
@Observable
final class RacketWatchModel {
    /// What the phone wants shown; `nil` ⇒ no racket screen is up on the phone.
    private(set) var state: RacketWatchState?
    /// "Not yet" on the start board: show a quieter waiting face until the phone moves on.
    private(set) var startDeferred = false
    /// The stopped notice the player already dismissed (a later, different one shows again).
    private(set) var dismissedNotice: RacketWatchState.Notice?

    @ObservationIgnored var send: ((RacketWatchCommandEnvelope) -> Void)?
    /// Whether the phone can be reached right now. Out of range (the phone in a bag across the hall) a tap is queued
    /// and the face must stay: only a reachable phone that doesn't answer has left the match.
    @ObservationIgnored var phoneReachable: (() -> Bool)?
    /// Prompt 265 (F10): has the phone answered our taps, and which snapshots are gone.
    @ObservationIgnored private var freshness = RacketWatchFreshness()

    var showsNotice: Bool {
        guard let n = state?.notice else { return false }
        return n != dismissedNotice
    }

    func receive(_ message: RacketWatchMessage) {
        switch message {
        case .state(let s):
            guard freshness.admits(s), RacketWatchState.accepts(s, over: state) else { return }
            freshness.heard()
            let cue = RacketWatchCue.between(state, s)
            if s.surface.kind != "start" || s.sessionID != state?.sessionID { startDeferred = false }
            state = s
            play(cue)
        case .clear(let id):
            if state?.sessionID == id {
                if let r = state?.revision { freshness.cleared(through: r) }
                leave()
            }
        case .clearAll(let revision):
            let drops = RacketWatchFreshness.clearAllDrops(state, through: revision)
            freshness.cleared(through: revision)
            if drops { leave() }
        case .command:
            break   // commands flow Watch → phone only
        }
    }

    /// A tap on the wrist.
    func tap(_ command: RacketWatchCommand) {
        guard let s = state else { return }
        if command == .notYet { startDeferred = true }
        if let shown = s.applyingOptimistically(command) { state = shown }
        send?(RacketWatchCommandEnvelope(sessionID: s.sessionID, command: command))
        WKInterfaceDevice.current().play(.click)
        guard RacketWatchFreshness.waitsForAnAnswer(phoneReachable: phoneReachable?() ?? false) else { return }
        freshness.tapped(at: Date())
        // No answer from the phone in time (it was closed mid-match): back to the usual face. The phone's next
        // snapshot brings the racket face back; the tap itself is queued for it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RacketWatchFreshness.answerWindowSec + 0.5))
            self?.leaveIfUnanswered()
        }
    }

    func dismissNotice() { dismissedNotice = state?.notice }

    private func leaveIfUnanswered() {
        // Went out of range while waiting: the tap is queued, keep the face and stop waiting.
        guard RacketWatchFreshness.waitsForAnAnswer(phoneReachable: phoneReachable?() ?? false) else {
            freshness.heard()
            return
        }
        guard let s = state, freshness.isStale(now: Date()) else { return }
        freshness.cleared(through: s.revision)
        leave()
    }

    private func leave() {
        state = nil
        startDeferred = false
        dismissedNotice = nil
    }

    private func play(_ cue: RacketWatchCue?) {
        guard let cue else { return }
        let haptic: WKHapticType
        switch cue {
        case .start: haptic = .start
        case .phase: haptic = .directionDown
        case .ask: haptic = .notification
        case .stopped: haptic = .failure
        case .done: haptic = .success
        }
        WKInterfaceDevice.current().play(haptic)
    }
}
