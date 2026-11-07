import Foundation
import Observation
import WatchKit

/// The Watch end of a racket match / drill running on the phone (prompt 245, issue #438 step 2). Holds the phone's
/// latest snapshot, sends taps back, shows a score tap at once (the phone's next snapshot wins) and taps the wrist
/// when the phase changes. Every rule here is the pure, tested `Shared/RacketWatchMessage.swift`
/// (`accepts`, `applyingOptimistically`, `RacketWatchCue`); this class only holds state and plays haptics.
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

    var showsNotice: Bool {
        guard let n = state?.notice else { return false }
        return n != dismissedNotice
    }

    func receive(_ message: RacketWatchMessage) {
        switch message {
        case .state(let s):
            guard RacketWatchState.accepts(s, over: state) else { return }
            let cue = RacketWatchCue.between(state, s)
            if s.surface.kind != "start" || s.sessionID != state?.sessionID { startDeferred = false }
            state = s
            play(cue)
        case .clear(let id):
            if state?.sessionID == id {
                state = nil
                startDeferred = false
                dismissedNotice = nil
            }
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
    }

    func dismissNotice() { dismissedNotice = state?.notice }

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
