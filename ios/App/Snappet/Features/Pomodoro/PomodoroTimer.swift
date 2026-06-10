import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The two phases of a Pomodoro cycle.
enum PomodoroPhase {
    case focus, breakTime

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .breakTime: return "Break"
        }
    }
}

/// Drift-free Pomodoro countdown engine.
///
/// Rather than decrementing a counter each tick (which accumulates error), the engine
/// stores an absolute `endDate` and derives `remaining` from wall-clock time on every
/// tick. The 1s `Timer` only drives UI refreshes; the math stays exact even if a tick
/// is late. Pause captures the remaining interval; resume rebuilds `endDate` from it.
@MainActor
@Observable
final class PomodoroTimer {
    // Configuration (minutes).
    var focusMinutes: Int = 25
    var breakMinutes: Int = 5

    private(set) var phase: PomodoroPhase = .focus
    private(set) var isRunning = false
    /// Paused mid-phase (as opposed to idle at the top of one) — `applyDurations` must
    /// not reseed `remaining` over a paused session's progress (issue #70 review).
    private(set) var isPaused = false
    /// Seconds left in the current phase.
    private(set) var remaining: TimeInterval

    /// Called when a FOCUS phase completes, with its length in minutes. The view wires
    /// this up to persist a `PomodoroSession` and log usage.
    var onFocusCompleted: ((Int) -> Void)?

    /// Fires whenever the wall-clock schedule changes: a phase starts or auto-advances
    /// (the phase now running + its absolute end), or the countdown stops (`nil` on
    /// pause/reset). `AppModel` wires this to the phase-end notification + Live Activity
    /// so background alerting can't drift from the in-app timer.
    var onScheduleChanged: ((PomodoroPhase, Date?) -> Void)?

    /// Absolute end of the running phase (`nil` while idle/paused). Read-only outside so
    /// the chip/Live Activity can render OS-ticked countdowns off the same wall clock.
    private(set) var endDate: Date?
    private var ticker: Timer?

    init() {
        remaining = 25 * 60
    }

    /// Total seconds in the current phase — used for the progress ring.
    var phaseDuration: TimeInterval {
        TimeInterval((phase == .focus ? focusMinutes : breakMinutes) * 60)
    }

    /// Fraction of the current phase remaining, clamped 0...1.
    var progress: Double {
        guard phaseDuration > 0 else { return 0 }
        return min(max(remaining / phaseDuration, 0), 1)
    }

    var timeText: String {
        let total = Int(remaining.rounded(.up))
        let m = max(total, 0) / 60
        let s = max(total, 0) % 60
        return String(format: "%02d:%02d", m, s)
    }

    func start() {
        guard !isRunning else { return }
        // If we're at the top of a fresh/reset phase, seed remaining from config.
        if remaining <= 0 { remaining = phaseDuration }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        isPaused = false
        scheduleTicker()
        onScheduleChanged?(phase, endDate)
    }

    func pause() {
        guard isRunning else { return }
        sync()
        isRunning = false
        isPaused = true
        invalidateTicker()
        endDate = nil
        onScheduleChanged?(phase, nil)
    }

    /// Stop and return to the top of the FOCUS phase.
    func reset() {
        isRunning = false
        isPaused = false
        invalidateTicker()
        endDate = nil
        phase = .focus
        remaining = phaseDuration
        onScheduleChanged?(phase, nil)
    }

    /// Re-attach to a phase that an orphaned Live Activity says is still counting down
    /// (relaunch after the app was terminated mid-session): rebuild the countdown off the
    /// absolute end. Fires no schedule callback — the orphaned notification for this
    /// phase is already pending, and the caller re-attached the activity itself.
    func restore(phase: PomodoroPhase, endDate: Date, now: Date = Date()) {
        guard !isRunning, endDate.timeIntervalSince(now) > 0 else { return }
        self.phase = phase
        self.endDate = endDate
        remaining = endDate.timeIntervalSince(now)
        isRunning = true
        isPaused = false
        scheduleTicker()
    }

    /// Recompute `remaining` from the wall clock; advance through **every** phase
    /// boundary that elapsed while ticks were suspended — each next phase is anchored at
    /// the *previous phase's end*, not at catch-up time, so reopening the app after being
    /// locked through focus + break lands mid-whatever-phase the wall clock says
    /// (#70 review). Internal (not private) so the catch-up math is unit-testable with an
    /// injected `now`.
    func sync(now: Date = Date()) {
        guard let currentEnd = endDate else { return }
        remaining = currentEnd.timeIntervalSince(now)
        guard remaining <= 0 else { return }

        var end = currentEnd
        var lastFinished = phase
        while end.timeIntervalSince(now) <= 0, phaseDuration > 0 {
            lastFinished = phase
            if phase == .focus { onFocusCompleted?(focusMinutes) }
            // Auto-switch focus -> break -> focus; the new phase's length anchors its end.
            phase = (phase == .focus) ? .breakTime : .focus
            end = end.addingTimeInterval(phaseDuration)
        }
        endDate = end
        remaining = end.timeIntervalSince(now)
        // One tactile cue per catch-up (success for finishing focus, warning for break-over).
        playCompletionHaptic(success: lastFinished == .focus)
        onScheduleChanged?(phase, endDate)
    }

    private func scheduleTicker() {
        invalidateTicker()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        // Common mode keeps ticking during scroll/interaction.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func invalidateTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Apply persisted lengths from settings. When the timer is **idle** this also
    /// re-seeds `remaining` so the new focus length shows immediately at the top of a
    /// phase — but never over a *paused* session's progress (the timer is app-owned now,
    /// and the root view re-applies durations on every appearance).
    func applyDurations(focusMinutes: Int, breakMinutes: Int) {
        self.focusMinutes = focusMinutes
        self.breakMinutes = breakMinutes
        if !isRunning && !isPaused { remaining = phaseDuration }
    }

    private func playCompletionHaptic(success: Bool) {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(success ? .success : .warning)
        #endif
    }
}
