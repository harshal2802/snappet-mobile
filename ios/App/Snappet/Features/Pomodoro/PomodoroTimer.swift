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
/// stores an absolute `phaseEndDate` and derives `remaining` from wall-clock time on every
/// tick. The 1s `Timer` only drives UI refreshes; the math stays exact even if a tick
/// is late. Pause captures the remaining interval; resume rebuilds `phaseEndDate` from it.
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

    /// Called whenever a new phase's countdown starts — on `start()` (including resume after
    /// pause) and on each auto-advance in `completePhase()`. Services wire this to schedule a
    /// `UNNotification` at `phaseEndDate` and to start/update the Live Activity.
    var onPhaseStarted: ((PomodoroPhase, Date) -> Void)?

    /// The wall-clock deadline for the current phase. `nil` when paused or idle.
    /// Exposed so services and the re-entry banner can schedule/render without polling.
    private(set) var phaseEndDate: Date?

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
        let end = Date().addingTimeInterval(remaining)
        phaseEndDate = end
        isRunning = true
        scheduleTicker()
        onPhaseStarted?(phase, end)
    }

    func pause() {
        guard isRunning else { return }
        sync()
        isRunning = false
        invalidateTicker()
        phaseEndDate = nil
    }

    /// Stop and return to the top of the FOCUS phase.
    func reset() {
        isRunning = false
        invalidateTicker()
        phaseEndDate = nil
        phase = .focus
        remaining = phaseDuration
    }

    /// Recompute `remaining` from the wall clock; advance phases on completion.
    private func sync() {
        guard let phaseEndDate else { return }
        remaining = phaseEndDate.timeIntervalSinceNow
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
            let end = Date().addingTimeInterval(remaining)
            phaseEndDate = end
            onPhaseStarted?(phase, end)
        } else {
            phaseEndDate = nil
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
