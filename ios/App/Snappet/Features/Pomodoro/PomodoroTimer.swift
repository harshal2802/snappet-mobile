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
    /// Seconds left in the current phase.
    private(set) var remaining: TimeInterval

    /// Called when a FOCUS phase completes, with its length in minutes. The view wires
    /// this up to persist a `PomodoroSession` and log usage.
    var onFocusCompleted: ((Int) -> Void)?

    /// Called when a phase starts or auto-transitions, with the new phase and its wall-clock
    /// end date. `AppModel` wires this to `PomodoroNotifications` and `PomodoroLiveActivityController`
    /// so notifications and the Live Activity survive backgrounding without device callbacks.
    var onPhaseDidStart: ((PomodoroPhase, Date) -> Void)?

    /// Called when the timer is paused or reset. `AppModel` wires this to cancel the pending
    /// notification and end the Live Activity.
    var onTimerDidStop: (() -> Void)?

    private var endDate: Date?
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
        scheduleTicker()
        onPhaseDidStart?(phase, endDate!)
    }

    func pause() {
        guard isRunning else { return }
        sync()
        isRunning = false
        invalidateTicker()
        endDate = nil
        onTimerDidStop?()
    }

    /// Stop and return to the top of the FOCUS phase.
    func reset() {
        let wasRunning = isRunning
        isRunning = false
        invalidateTicker()
        endDate = nil
        phase = .focus
        remaining = phaseDuration
        // Only fire the stop callback when there was an active session to cancel; an idle
        // reset (timer was never started) produces no-op service calls.
        if wasRunning { onTimerDidStop?() }
    }

    /// Recompute `remaining` from the wall clock; advance phases on completion.
    private func sync() {
        guard let endDate else { return }
        remaining = endDate.timeIntervalSinceNow
        if remaining <= 0 { completePhase() }
    }

    private func completePhase() {
        let finished = phase
        if finished == .focus {
            onFocusCompleted?(focusMinutes)
        }
        // Tactile cue that a phase ended (success for finishing focus, warning for break-over).
        playCompletionHaptic(success: finished == .focus)
        // Auto-switch focus -> break -> focus and keep running.
        phase = (finished == .focus) ? .breakTime : .focus
        remaining = phaseDuration
        if isRunning {
            endDate = Date().addingTimeInterval(remaining)
            // Notify services about the new phase so the notification + Live Activity update.
            onPhaseDidStart?(phase, endDate!)
        } else {
            endDate = nil
        }
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

    /// Apply persisted lengths from settings. When the timer is idle this also re-seeds
    /// `remaining` so the new focus length shows immediately at the top of a phase.
    func applyDurations(focusMinutes: Int, breakMinutes: Int) {
        self.focusMinutes = focusMinutes
        self.breakMinutes = breakMinutes
        if !isRunning { remaining = phaseDuration }
    }

    private func playCompletionHaptic(success: Bool) {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(success ? .success : .warning)
        #endif
    }
}
