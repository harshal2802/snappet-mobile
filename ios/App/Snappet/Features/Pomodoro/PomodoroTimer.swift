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

    /// Called when a phase starts (or auto-advances to the next phase), with the current
    /// phase and the absolute wall-clock end date. Wired by the app layer to schedule a
    /// local notification and start/update the Live Activity.
    var onPhaseStarted: ((PomodoroPhase, Date) -> Void)?

    /// Called when the timer pauses, with the phase and a "frozen" end date representing
    /// `remaining` seconds from now (so the caller can freeze the Live Activity countdown
    /// at the right value). Wired to cancel the pending notification and mark the Live
    /// Activity as paused.
    var onPaused: ((PomodoroPhase, Date) -> Void)?

    /// Called when the timer resets to the top of a focus phase. Wired to cancel the pending
    /// notification and end the Live Activity.
    var onReset: (() -> Void)?

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
        scheduleTicker()
        onPhaseStarted?(phase, endDate!)
    }

    func pause() {
        guard isRunning else { return }
        sync()
        isRunning = false
        invalidateTicker()
        // Capture `remaining` before clearing state — build a virtual end date at the
        // current remaining interval so the caller can freeze the Live Activity countdown.
        let frozenEndDate = Date().addingTimeInterval(remaining)
        let frozenPhase = phase
        endDate = nil
        onPaused?(frozenPhase, frozenEndDate)
    }

    /// Stop and return to the top of the FOCUS phase.
    func reset() {
        isRunning = false
        invalidateTicker()
        endDate = nil
        phase = .focus
        remaining = phaseDuration
        onReset?()
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
            onPhaseStarted?(phase, endDate!)
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
