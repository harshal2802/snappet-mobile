import Foundation

/// PURE cross-session set prefill (issue #73): given completed-session history, find what the user
/// actually lifted the last time they did an exercise and produce both the set-1 input prefill and a
/// one-line "Last time: 3×8 @ 60 kg" hint for the live player. No SwiftData queries, no UI — runs in
/// `SnappetTests` with no simulator (the repo's pure-logic-at-a-thin-edge rule).
enum LastSetLookup {

    /// The prefill + hint for one exercise. `reps`/`weight`/`unit` mirror the live player's inputs
    /// (the prefill is the last completed set of the deciding session — what the user finished on);
    /// `hint` is the one-liner shown under the target, summarizing **all** of that session's
    /// completed sets for the exercise.
    struct LastTime: Equatable, Sendable {
        var reps: Int?
        var weight: Double?
        var unit: WeightUnit?
        var hint: String
    }

    /// The most recent **completed** session containing `exerciseId` with at least one usable
    /// completed reps/weight set decides the result. A set is usable when it was completed and
    /// carries reps or a weight ("done"-only taps say nothing worth prefilling). Duration/climb
    /// exercises are ignored — the guided player only logs reps & weight. Matches `WorkoutMath`'s
    /// duplicate handling: every occurrence of the exercise in a session counts (freeform re-adds).
    static func lastTime(exerciseId: String, history: [WorkoutSession]) -> LastTime? {
        let ordered = history
            .filter { $0.completedAt != nil }
            .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
        for session in ordered {
            let sets = session.exercises
                .filter { $0.exerciseId == exerciseId && $0.kind == .repsWeight }
                .flatMap(\.sets)
                .filter { $0.completedAt != nil && ($0.actualReps != nil || $0.actualWeight != nil) }
            guard let last = sets.last else { continue }
            return LastTime(reps: last.actualReps, weight: last.actualWeight,
                            unit: last.weightUnit, hint: hint(for: sets))
        }
        return nil
    }

    // MARK: - Hint formatting

    /// "Last time: 3×8 @ 60 kg" (uniform), "Last time: 8/8/6 @ 60 kg" (mixed reps),
    /// "Last time: 3×8 @ 55–60 kg" (mixed weights), "Last time: 2×12" (bodyweight).
    private static func hint(for sets: [SetLog]) -> String {
        switch (repsSummary(sets), weightSummary(sets)) {
        case let (reps?, weight?): return "Last time: \(reps) @ \(weight)"
        case let (reps?, nil): return "Last time: \(reps)"
        case let (nil, weight?): return "Last time: \(weight)"
        // Unreachable: callers filter to sets carrying reps or a weight.
        default: return "Last time: done"
        }
    }

    private static func repsSummary(_ sets: [SetLog]) -> String? {
        let reps = sets.compactMap(\.actualReps)
        guard let first = reps.first else { return nil }
        if reps.allSatisfy({ $0 == first }) { return "\(reps.count)×\(first)" }
        return reps.map(String.init).joined(separator: "/")
    }

    private static func weightSummary(_ sets: [SetLog]) -> String? {
        let weights = sets.compactMap { set in
            set.actualWeight.map { (value: $0, unit: set.weightUnit) }
        }
        guard let last = weights.last else { return nil }
        let displayUnit = last.unit ?? .kg
        // Same-unit weights (the common case) pass through untouched; a mixed-unit session converts
        // via kg, rounded to one decimal so float noise never prints ("59.999…").
        let values = weights.map { w -> Double in
            if (w.unit ?? .kg) == displayUnit { return w.value }
            let converted = WorkoutMath.kgToUnit(WorkoutMath.toKg(w.value, w.unit), displayUnit)
            return (converted * 10).rounded() / 10
        }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let loText = SetMeasure.formatWeight(lo)
        let hiText = SetMeasure.formatWeight(hi)
        let range = loText == hiText ? loText : "\(loText)–\(hiText)"
        return "\(range) \(displayUnit.display)"
    }
}
