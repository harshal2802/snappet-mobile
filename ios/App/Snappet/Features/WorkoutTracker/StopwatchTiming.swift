import Foundation

/// Pure, device-free timing math for the workout stopwatch — the brain behind `StopwatchView`, so the
/// tricky parts (elapsed-with-pause, count-down clamp, reached-zero) are unit-tested without a view or a
/// device (the repo's pure-logic-at-a-thin-edge rule). No SwiftUI, no SwiftData. Shared by timed sets
/// (`SetKind.duration`) and per-climb attempts — built and tested once. (workout-with-timer PR 1, prompt 59)
enum StopwatchTiming {

    /// Count up forever, or count down from a fixed target.
    enum Mode: Equatable, Sendable {
        case countUp
        case countDown(targetSec: TimeInterval)
    }

    /// A snapshot of the stopwatch at one `now`, computed purely from the wall-clock anchor — never from
    /// an accumulated tick count, so it can't drift and survives backgrounding.
    struct Reading: Equatable, Sendable {
        /// Seconds run so far (always ≥ 0).
        var elapsed: TimeInterval
        /// Seconds left for a `.countDown` (clamped ≥ 0); `nil` for `.countUp`.
        var remaining: TimeInterval?
        /// `true` once a `.countDown` has reached its target; always `false` for `.countUp`.
        var reachedZero: Bool
    }

    /// The single source of truth for what the timer shows. `startedAt == nil` means "not currently
    /// running" — only `accumulated` counts (the frozen value while paused or stopped).
    ///
    /// `elapsed = accumulated + (now − startedAt)`, floored at 0 so a clock that jumps backwards can
    /// never show a negative time. The display is always derived this way; the view never sums ticks.
    static func reading(startedAt: Date?, accumulated: TimeInterval, now: Date, mode: Mode) -> Reading {
        let running = startedAt.map { now.timeIntervalSince($0) } ?? 0
        let elapsed = max(0, accumulated + running)
        switch mode {
        case .countUp:
            return Reading(elapsed: elapsed, remaining: nil, reachedZero: false)
        case .countDown(let target):
            return Reading(elapsed: elapsed,
                           remaining: max(0, target - elapsed),
                           reachedZero: elapsed >= target)
        }
    }

    /// Freeze a running stopwatch: fold the time since `startedAt` into `accumulated` so that resuming
    /// with a fresh `startedAt` neither loses nor double-counts time (the pause idiom the rest timer
    /// uses, generalized). Returns the new banked total.
    static func freeze(startedAt: Date, accumulated: TimeInterval, now: Date) -> TimeInterval {
        max(0, accumulated + now.timeIntervalSince(startedAt))
    }
}
