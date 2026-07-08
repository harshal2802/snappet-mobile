import Foundation

// Pure decision state for the watch side of the live-workout relay (`WorkoutWatchManager`).
// Lives in `Shared/` so it also compiles into the phone target and the contracts are pinned
// in `SnappetTests` — the watch app has no unit-test target of its own (bug-hunt Wave 2, #272).

/// Gate for the start/stop seam. `start()` opens an async window (the HealthKit authorization
/// await + a MainActor hop) before any `HKWorkoutSession` exists; this gate both blocks
/// duplicate starts inside that window and remembers a stop that arrives inside it, so the stop
/// cancels the start instead of being dropped. Pre-fix, a phone-queued `start`+`stop` landing
/// back-to-back (watch unreachable → `transferUserInfo` replay on wake) left the watch running
/// an HR-collecting workout nobody would ever end.
struct WatchWorkoutStartGate: Equatable, Sendable {
    /// Set the instant a start is requested — before the async authorization await — so a
    /// second start arriving mid-window can't spawn a 2nd `HKWorkoutSession`.
    private(set) var isStarting = false
    /// A stop arrived while `isStarting`: the start must abandon itself when the window closes.
    private(set) var pendingEnd = false

    /// A start request arrived. `true` → the caller owns the (now open) start window;
    /// `false` → drop the request (already running, or a window is already open).
    mutating func beginStart(isRunning: Bool) -> Bool {
        guard !isRunning, !isStarting else { return false }
        isStarting = true
        pendingEnd = false
        return true
    }

    enum Completion: Equatable, Sendable {
        /// No stop arrived inside the window — create and start the session.
        case proceed
        /// A stop was absorbed mid-window — do NOT create the session; reset state instead.
        case abandon
    }

    /// The async start window closed (the caller is about to create the session). Consumes the
    /// window and any absorbed stop, so the gate is clean for a later start either way.
    mutating func completeStart() -> Completion {
        let abandoned = pendingEnd
        isStarting = false
        pendingEnd = false
        return abandoned ? .abandon : .proceed
    }

    /// A stop arrived but there is no live session/builder to end yet. `true` → absorbed into
    /// an open start window (the start will abandon); `false` → a stray stop with nothing to
    /// cancel (ignored, as before).
    @discardableResult
    mutating func absorbEndDuringStart() -> Bool {
        guard isStarting else { return false }
        pendingEnd = true
        return true
    }

    /// Full reset (session ended, failed, or abandoned).
    mutating func reset() {
        isStarting = false
        pendingEnd = false
    }
}

/// Sample-weighted running HR average for the watch metrics page. Fold it ONLY when the live
/// builder actually collected a new HR statistic: `didCollectDataOf` also fires for kcal-only
/// batches, and re-folding the unchanged latest reading there made the average event-weighted —
/// skewed toward whatever HR happened to coincide with frequent energy updates.
struct WatchHRAverage: Equatable, Sendable {
    private(set) var sum: Double = 0
    private(set) var count: Int = 0

    /// The current average, `0` before the first real sample (the UI's "no data yet").
    var average: Double { count > 0 ? sum / Double(count) : 0 }

    /// Fold one just-collected reading; non-positive readings don't count.
    mutating func fold(_ bpm: Double) {
        guard bpm > 0 else { return }
        sum += bpm
        count += 1
    }

    mutating func reset() {
        sum = 0
        count = 0
    }
}
