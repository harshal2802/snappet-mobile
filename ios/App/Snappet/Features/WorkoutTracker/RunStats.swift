import Foundation

/// Pure, device-free per-run rollups for a running entity card (Workout-Type Parity) — total distance,
/// total moving time, and average pace across the run's legs. No SwiftUI / SwiftData, so it's unit-tested
/// in `SnappetTests` with no simulator. (Distance is captured manually in v1; live watch/GPS distance is
/// tracked in issue #177.)
enum RunStats {

    /// Total distance (Σ `distanceMeters`) across the run's completed legs.
    static func totalDistanceMeters(_ ex: SessionExercise) -> Double {
        ex.sets.filter { $0.completedAt != nil }.reduce(0) { $0 + ($1.distanceMeters ?? 0) }
    }

    /// Total moving time (Σ `durationSec`) across the run's completed legs.
    static func totalDurationSec(_ ex: SessionExercise) -> Double {
        ex.sets.filter { $0.completedAt != nil }.reduce(0) { $0 + ($1.durationSec ?? 0) }
    }

    /// Average pace (seconds per kilometre) over the whole run = total time ÷ total distance. `nil` when
    /// there's no distance or no time to derive a pace from.
    static func avgPaceSecPerKm(_ ex: SessionExercise) -> Double? {
        let meters = totalDistanceMeters(ex), seconds = totalDurationSec(ex)
        guard meters > 0, seconds > 0 else { return nil }
        return seconds / (meters / 1000)
    }
}
