import Foundation

/// Pure, device-free per-exercise rollups for a strength entity card (Workout-Type Parity) — the
/// strength analogue of a climb's `resolvedClimbStatus`. Drives the collapsed card's rolled-up chips
/// (top set · e1RM). No SwiftUI / SwiftData, so it's unit-tested in `SnappetTests` with no simulator.
/// Session-level strength aggregation (volume / PRs across exercises) lands with the stats bridges in a
/// later phase; this is the single-exercise rollup the card needs now.
enum StrengthStats {

    /// The exercise's "top" completed set = the one with the greatest weighted load (weight × reps);
    /// bodyweight sets (no weight) rank by reps so a card always has a top set to show. `nil` when no
    /// set is completed. Ties keep the earliest set (deterministic).
    static func topSet(_ ex: SessionExercise) -> SetLog? {
        ex.sets.filter { $0.completedAt != nil }.max { loadScore($0) < loadScore($1) }
    }

    /// Epley estimated 1-rep max from the exercise's best *weighted* completed set: `w × (1 + reps/30)`,
    /// in that set's own unit. `nil` when there's no weighted set (a bodyweight exercise has no e1RM).
    static func estimatedOneRepMax(_ ex: SessionExercise) -> (value: Double, unit: WeightUnit)? {
        let weighted = ex.sets.filter { $0.completedAt != nil && ($0.actualWeight ?? 0) > 0 && ($0.actualReps ?? 0) > 0 }
        guard let best = weighted.max(by: { epley($0) < epley($1) }) else { return nil }
        let value = epley(best)
        guard value > 0 else { return nil }
        return (value, best.weightUnit ?? .kg)
    }

    /// Ranking score for "top set": weighted load (weight × reps) when loaded, else rep count.
    private static func loadScore(_ s: SetLog) -> Double {
        let w = s.actualWeight ?? 0, r = Double(s.actualReps ?? 0)
        return w > 0 ? w * r : r
    }

    /// Epley 1RM estimate for one set (0 when not a weighted, repped set).
    private static func epley(_ s: SetLog) -> Double {
        let w = s.actualWeight ?? 0, r = Double(s.actualReps ?? 0)
        guard w > 0, r > 0 else { return 0 }
        return w * (1 + r / 30)
    }
}
