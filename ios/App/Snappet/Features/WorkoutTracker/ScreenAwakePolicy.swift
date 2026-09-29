import Foundation

/// How long the workout keeps the phone's screen on (prompt 135). The user reported the screen
/// auto-locking mid-workout: the player — the one surface every routine and quick session runs in —
/// never held the idle timer, so a rest count-down or the gap between sets slept the phone.
enum KeepScreenAwakeMode: String, CaseIterable, Identifiable, Sendable {
    /// Screen stays on the whole time the workout player is open (not minimized). The default:
    /// a workout is a glance-at-the-phone-between-sets activity.
    case wholeWorkout
    /// Only while a clock is running — a timed set / attempt, an interval run, a rest count-down,
    /// the Log-set stopwatch. Between sets the system auto-lock applies.
    case timersOnly
    /// Never override the system auto-lock.
    case off

    static let storageKey = "workout.keepScreenAwake"
    static let defaultMode: KeepScreenAwakeMode = .wholeWorkout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wholeWorkout: "Whole workout"
        case .timersOnly: "Only timers"
        case .off: "Off"
        }
    }

    var footer: String {
        switch self {
        case .wholeWorkout:
            "The screen stays on while the workout player is open. Minimize the workout to let the phone lock."
        case .timersOnly:
            "The screen stays on only while a timer runs — a timed set, an interval run, or a rest count-down."
        case .off:
            "The phone follows its normal Auto-Lock. The rest alert and Lock Screen timer still reach you."
        }
    }

    /// Resolve a stored raw value, falling back to the default for nil / unknown values.
    static func resolve(_ raw: String?) -> KeepScreenAwakeMode {
        raw.flatMap(KeepScreenAwakeMode.init(rawValue:)) ?? defaultMode
    }
}

/// Why a surface wants the screen on. Kept coarse on purpose — the mode only distinguishes
/// "the workout is open" from "a clock is running".
enum ScreenAwakeReason: Hashable, Sendable {
    /// The workout player is presented (full screen, not minimized).
    case workout
    /// A clock the user is watching is running.
    case timer
}

/// Pure decision: should the idle timer be disabled, given the mode and the reasons currently held?
/// Holds are reference-counted by the controller, so ANY surface still holding keeps the screen on —
/// the fix for covers that used to write `isIdleTimerDisabled = false` on disappear regardless of
/// what was still on screen underneath.
enum ScreenAwakePolicy {
    static func shouldKeepAwake<S: Sequence>(mode: KeepScreenAwakeMode, holding reasons: S) -> Bool
    where S.Element == ScreenAwakeReason {
        switch mode {
        case .off: false
        case .timersOnly: reasons.contains(.timer)
        case .wholeWorkout: reasons.contains { _ in true }
        }
    }
}
