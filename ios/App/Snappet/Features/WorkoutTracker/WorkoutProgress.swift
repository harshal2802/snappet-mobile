import Foundation

/// Weight-unit conversion + workout analytics, ported from the web app's `progress.ts`.
/// Weights are normalised to kilograms internally; PRs rank sets by `weight × reps`.
enum WorkoutMath {
    static let lbPerKg = 0.453592

    static func toKg(_ weight: Double, _ unit: WeightUnit?) -> Double {
        unit == .lb ? weight * lbPerKg : weight
    }
    static func kgToUnit(_ kg: Double, _ unit: WeightUnit) -> Double {
        unit == .lb ? kg / lbPerKg : kg
    }

    /// Rounded weight in the user's unit, grouped with thousands separators (e.g. "1,250").
    static func formatWeight(kg: Double, unit: WeightUnit) -> String {
        let value = (kgToUnit(kg, unit)).rounded()
        return value.formatted(.number.grouping(.automatic))
    }
    static func formatVolume(kg: Double, unit: WeightUnit) -> String {
        "\(formatWeight(kg: kg, unit: unit)) \(unit.display)"
    }

    /// The best set for an exercise across history, ranked by `weightKg × reps`. Bodyweight
    /// sets (no weight logged) score as `1 × reps` so they still rank, but report `bestKg == 0`.
    struct TopSet { var bestKg: Double; var bestReps: Int; var date: Date }

    static func topSet(history: [WorkoutSession], exerciseId: String) -> TopSet? {
        var bestScore = 0.0
        var result: TopSet?
        for session in history {
            guard let ex = session.exercises.first(where: { $0.exerciseId == exerciseId }) else { continue }
            for set in ex.sets {
                guard set.completedAt != nil else { continue }
                let reps = set.actualReps ?? 0
                guard reps > 0 else { continue }
                let weightKg = set.actualWeight.map { toKg($0, set.weightUnit) } ?? 1
                let score = weightKg * Double(reps)
                if score > bestScore {
                    bestScore = score
                    result = TopSet(bestKg: set.actualWeight != nil ? weightKg : 0,
                                    bestReps: reps, date: session.startedAt)
                }
            }
        }
        return result
    }

    /// Total completed volume (Σ weightKg × reps) for an exercise, in kg. Only sets with both
    /// a weight and reps logged contribute.
    static func totalVolumeKg(history: [WorkoutSession], exerciseId: String) -> Double {
        var total = 0.0
        for session in history {
            guard let ex = session.exercises.first(where: { $0.exerciseId == exerciseId }) else { continue }
            for set in ex.sets where set.completedAt != nil {
                if let reps = set.actualReps, let weight = set.actualWeight {
                    total += toKg(weight, set.weightUnit) * Double(reps)
                }
            }
        }
        return total.rounded()
    }

    /// Number of sessions in which the exercise had at least one completed set.
    static func sessionCount(history: [WorkoutSession], exerciseId: String) -> Int {
        history.filter { session in
            session.exercises.contains { $0.exerciseId == exerciseId && $0.sets.contains { $0.completedAt != nil } }
        }.count
    }

    /// Total completed volume across a single session, in kg.
    static func sessionVolumeKg(_ session: WorkoutSession) -> Double {
        var total = 0.0
        for ex in session.exercises {
            for set in ex.sets where set.completedAt != nil {
                if let reps = set.actualReps, let weight = set.actualWeight {
                    total += toKg(weight, set.weightUnit) * Double(reps)
                }
            }
        }
        return total.rounded()
    }
}

/// Resolves an `exerciseId` (bundled or custom) to a displayable `Exercise`. Custom exercises
/// come from the SwiftData store; the bundled ones from `ExerciseCatalog`.
@MainActor
struct ExerciseResolver {
    private let customByID: [String: Exercise]
    init(custom: [CustomExercise]) {
        customByID = Dictionary(custom.map { ($0.id, $0.asExercise) }, uniquingKeysWith: { a, _ in a })
    }

    /// The merged browse list: bundled catalog + custom exercises, sorted by name.
    var allMerged: [Exercise] {
        (ExerciseCatalog.all + customByID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func exercise(id: String) -> Exercise? {
        customByID[id] ?? ExerciseCatalog.byID[id]
    }

    /// Human name for an id, falling back to a de-slugged id if the exercise is missing
    /// (e.g. a starter references an exercise not in the trimmed catalog).
    func name(for id: String, override: String? = nil) -> String {
        if let override, !override.isEmpty { return override }
        if let ex = exercise(id: id) { return ex.name }
        return id.replacingOccurrences(of: "_", with: " ")
    }
}
