import Foundation

/// The **pure, device-free actuals→prescription converter** (workout-redesign E5) — the *inverse* of
/// `RoutineSessionBuilder`. Where the builder maps a routine's prescription forward to a freshly-started
/// session (prescription → session exercises), this maps a *finished* session's **logged actuals** back to
/// a routine's prescription (`WorkoutSession` → `[RoutineExercise]`), so a Quick Session can be saved as a
/// repeatable routine that round-trips through `makeSession`.
///
/// **Lossy by nature** (README §9/§10 Q3): a session is a record of what happened (1 set here, 6 attempts
/// there, an open-ended hold), while a routine is a *plan*; collapsing one to the other discards detail and
/// makes judgement calls (which weight is "the" prescribed weight? how many sets?). So the result is
/// **user-reviewable**: it pre-fills `RoutineEditorView` for the user to trim warm-ups, rename, and adjust
/// targets before anything is inserted — this converter never writes to the store.
///
/// **Discipline parity (the whole point of depending on E4).** Each `SessionExercise` keeps its discipline
/// on the way out, so a climb/timed/run entity becomes a *typed* `RoutineExercise` (a climb block prescribing
/// type+grade, a timed block carrying its `TimedExerciseSpec`, a run block with a distance target) — not a
/// degraded strength reps×weight slot. The mapping is the deliberate inverse of `RoutineSessionBuilder`'s
/// per-discipline `switch`, so a freeform → routine → freeform round-trip preserves discipline.
///
/// Pure (Foundation only — no SwiftUI/SwiftData/HealthKit), composing the already-pure `SetMeasure` /
/// `WorkoutMath`, so every per-discipline rule is unit-tested without a device (`SessionToRoutineTests`),
/// per the repo's pure-logic-at-a-thin-edge rule. The SwiftData/UI edge (the "Save as routine" action +
/// the pre-filled `RoutineEditorView`) just wraps the result.
enum SessionToRoutine {

    // MARK: - The conversion

    /// Convert a finished session's exercises to a reviewable routine prescription.
    ///
    /// One `RoutineExercise` is emitted per `SessionExercise` that has at least one **completed** set —
    /// an exercise with nothing logged (e.g. a warm-up the user skipped, or an entity added but never
    /// trained) is dropped, since prescribing zero sets is meaningless. The per-discipline rule:
    ///
    /// - **strength** → completed-set count × a representative reps string × the top (heaviest×reps) weight,
    ///   in that set's unit. `disciplineRaw` stays `nil` (the additive-nil strength default).
    /// - **climb** → the climb itself becomes the slot: its type + grade + scale; `sets` = the number of
    ///   logged attempts (≥ 1). Lossy: a single-attempt project still prescribes a 1-attempt block (the
    ///   user can bump it in the editor — README §10 Q3).
    /// - **timed** → the timed structure (`TimedExerciseSpec` + category) carried through verbatim; `sets`
    ///   = the spec's set count for a structured protocol, else the completed-set count; a representative
    ///   hold seconds seeds `targetDurationSec` for a simple hold (a structured spec carries its own).
    /// - **run** → a distance target = the total completed distance; `sets` = 1.
    /// - **dance / other** → a `targetDurationSec` = a representative active duration; `sets` = the
    ///   completed-set count.
    ///
    /// `defaultUnit` seeds a strength block's unit when no completed set carried one.
    static func routineExercises(from session: WorkoutSession, defaultUnit: WeightUnit) -> [RoutineExercise] {
        session.exercises.compactMap { routineExercise(from: $0, defaultUnit: defaultUnit) }
    }

    /// Map one finished `SessionExercise` → an (optional) `RoutineExercise`, type-aware. Returns `nil` when
    /// the exercise has no completed set (nothing to prescribe).
    static func routineExercise(from se: SessionExercise, defaultUnit: WeightUnit) -> RoutineExercise? {
        let completed = se.sets.filter { $0.completedAt != nil }
        guard !completed.isEmpty else { return nil }

        switch se.discipline {
        case .strength: return strengthBlock(se, completed: completed, defaultUnit: defaultUnit)
        case .climb:    return climbBlock(se, completed: completed)
        case .timed:    return timedBlock(se, completed: completed)
        case .run:      return runBlock(se, completed: completed)
        case .dance, .other: return openEffortBlock(se, completed: completed)
        }
    }

    /// A suggested routine name from the session — its routine name when it's not the generic freeform
    /// placeholder, else a dominant-discipline label ("Climbing session" / "Strength session" / …). Trimmed
    /// + de-empty'd; the user renames it in the editor.
    static func suggestedName(for session: WorkoutSession) -> String {
        let trimmed = session.routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !Self.genericSessionNames.contains(trimmed.lowercased()) {
            return trimmed
        }
        switch FreeformSummary.dominant(for: session) {
        case .lifting:  return "Strength session"
        case .climbing: return "Climbing session"
        case .running:  return "Running session"
        case .timed:    return "Timed session"
        case .dance:    return "Dance session"
        case .other:    return "Workout session"
        case .none:     return "New routine"
        }
    }

    /// Whether the session has anything worth saving as a routine (≥ 1 completed set). Gates the
    /// "Save as routine" affordance so it never offers to save an empty plan.
    static func canConvert(_ session: WorkoutSession) -> Bool {
        session.completedSetCount > 0
    }

    // MARK: - Per-discipline rules

    /// Strength: a representative reps × the top weight, repeated for the completed-set count. The reps
    /// string is the **mode** of the completed sets' reps (the most-repeated value — the "working" reps),
    /// resolving ties to the higher reps; the weight is the heaviest set's weight (ranked by weight×reps,
    /// reusing the PR definition), in that set's unit. Strength keeps `disciplineRaw` nil so a strength-only
    /// routine is byte-identical to one hand-built in the editor (the additive-nil invariant).
    private static func strengthBlock(_ se: SessionExercise, completed: [SetLog],
                                       defaultUnit: WeightUnit) -> RoutineExercise {
        let reps = representativeReps(completed)
        let top = topWeightedSet(completed)
        return RoutineExercise(
            exerciseId: se.exerciseId,
            sets: completed.count,
            reps: reps,
            restSeconds: defaultRest(for: .strength),
            weight: top?.weight,
            weightUnit: top?.unit ?? defaultUnit,
            displayName: se.displayName,
            discipline: .strength)
    }

    /// Climb: the climb is the slot. Carries the climb's prescribed type/grade/scale; `sets` = the attempt
    /// count (the inverse of `RoutineSessionBuilder` stamping each fresh attempt with the prescribed grade).
    private static func climbBlock(_ se: SessionExercise, completed: [SetLog]) -> RoutineExercise {
        // Prefer the climb-level grade (the source of truth); fall back to the best attempt's stamped grade.
        let grade = se.climbGradeLabel ?? completed.compactMap { $0.climbGradeLabel }.first
        return RoutineExercise(
            exerciseId: se.exerciseId,
            sets: max(1, completed.count),
            reps: "",
            restSeconds: defaultRest(for: .climb),
            displayName: se.displayName,
            discipline: .climb,
            climbTypeRaw: se.climbTypeRaw ?? se.climbType.rawValue,
            climbGradeLabel: grade,
            climbGradeScaleRaw: se.climbGradeScaleRaw ?? se.climbGradeScale.rawValue)
    }

    /// Timed: carry the structure through verbatim. A structured protocol (repeaters/tabata/emom) already
    /// encodes its sets in the spec, so `sets` = the spec's set count; a simple hold / open count-up uses
    /// the completed-set count and seeds a representative hold target (the median completed duration).
    private static func timedBlock(_ se: SessionExercise, completed: [SetLog]) -> RoutineExercise {
        let spec = se.timedSpec
        let structured = spec?.mode.isStructured ?? false
        let sets = structured ? max(1, spec?.sets ?? completed.count) : max(1, completed.count)
        // A representative hold for a simple hold = the median completed duration; structured specs carry
        // their own work seconds, so we don't double-prescribe a target on top of the spec.
        let target: Double? = structured ? nil : medianDuration(completed)
        return RoutineExercise(
            exerciseId: se.exerciseId,
            sets: sets,
            reps: "",
            restSeconds: defaultRest(for: .timed),
            displayName: se.displayName,
            discipline: .timed,
            targetDurationSec: target,
            timedSpecData: se.timedSpecData,
            timedCategory: se.timedCategory)
    }

    /// Run: a single block targeting the total completed distance (pace is derived, never prescribed).
    private static func runBlock(_ se: SessionExercise, completed: [SetLog]) -> RoutineExercise {
        let meters = completed.compactMap { $0.distanceMeters }.reduce(0, +)
        return RoutineExercise(
            exerciseId: se.exerciseId,
            sets: 1,
            reps: "",
            restSeconds: defaultRest(for: .run),
            displayName: se.displayName,
            discipline: .run,
            targetDistanceMeters: meters > 0 ? meters : nil)
    }

    /// Dance / other: a duration-based block prescribing a representative active duration per set.
    private static func openEffortBlock(_ se: SessionExercise, completed: [SetLog]) -> RoutineExercise {
        RoutineExercise(
            exerciseId: se.exerciseId,
            sets: max(1, completed.count),
            reps: "",
            restSeconds: defaultRest(for: se.discipline),
            displayName: se.displayName,
            discipline: se.discipline,
            targetDurationSec: medianDuration(completed))
    }

    // MARK: - Representative-value helpers (pure)

    /// The representative reps string for a strength block: the **mode** of the completed sets' reps (the
    /// most-frequent value — the working-set reps a session usually centres on), resolving ties to the
    /// higher reps. `nil`-reps sets are ignored; an all-bodyweight-no-reps block falls back to "" (the
    /// editor's "8-12, max"-style free text, which the user fills in).
    static func representativeReps(_ completed: [SetLog]) -> String {
        let reps = completed.compactMap { $0.actualReps }.filter { $0 > 0 }
        guard !reps.isEmpty else { return "" }
        var counts: [Int: Int] = [:]
        for r in reps { counts[r, default: 0] += 1 }
        // Most frequent; tie → the higher reps (a deterministic, defensible choice).
        let best = counts.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key }
        return best.map { String($0.key) } ?? ""
    }

    /// The heaviest completed set, ranked by `weightKg × reps` (the same PR ranking `WorkoutMath` uses), so
    /// the prescription's starting weight is the session's hardest working set. Returns the weight in its
    /// own logged unit (not converted) so the editor shows what the user actually lifted. `nil` for an
    /// all-bodyweight block.
    static func topWeightedSet(_ completed: [SetLog]) -> (weight: Double, unit: WeightUnit)? {
        var bestScore = 0.0
        var result: (weight: Double, unit: WeightUnit)?
        for set in completed {
            guard let weight = set.actualWeight, let reps = set.actualReps, reps > 0 else { continue }
            let score = WorkoutMath.toKg(weight, set.weightUnit) * Double(reps)
            if score > bestScore {
                bestScore = score
                result = (weight, set.weightUnit ?? .kg)
            }
        }
        return result
    }

    /// The median completed-set duration (seconds), `nil` when no set carried a duration. Median (not mean)
    /// so one outlier hold doesn't skew the prescribed target; the lower-middle on an even count.
    static func medianDuration(_ completed: [SetLog]) -> Double? {
        let durations = completed.compactMap { $0.durationSec }.filter { $0 > 0 }.sorted()
        guard !durations.isEmpty else { return nil }
        return durations[(durations.count - 1) / 2]
    }

    // MARK: - Defaults

    /// A sensible default rest for a freshly-converted block (the session doesn't record prescribed rest).
    /// The user adjusts it in the editor; these mirror the editor / builder defaults per discipline.
    private static func defaultRest(for discipline: WorkoutDiscipline) -> Int {
        switch discipline {
        case .strength:            return 90
        case .climb:               return 180
        case .timed, .dance, .other: return 45
        case .run:                 return 0
        }
    }

    /// Lowercased generic session names that should NOT be reused as a routine name (so we suggest a
    /// discipline label instead). Mirrors the freeform player's default title ("Quick session").
    private static let genericSessionNames: Set<String> = ["quick session", "freeform session", "workout"]

    // MARK: - Draft

    /// Build a full reviewable draft from a finished session: a suggested name + the converted blocks (the
    /// `sport` is inferred from the dominant discipline so an all-climb session pre-tags `.climbing`). The
    /// editor seeds itself from this, then INSERTS a brand-new routine on Save.
    static func draft(from session: WorkoutSession, defaultUnit: WeightUnit) -> RoutineDraft {
        RoutineDraft(
            name: suggestedName(for: session),
            sport: suggestedSport(for: session),
            level: nil,
            detail: nil,
            exercises: routineExercises(from: session, defaultUnit: defaultUnit))
    }

    /// A back-compat `SportTag` hint from the session's dominant discipline (climbing → `.climbing`,
    /// everything else → `.general`); `nil` when nothing is logged. Lossy (only 3 SportTags vs 6
    /// disciplines, README §10 Q2) — the per-block discipline is the real identity axis.
    static func suggestedSport(for session: WorkoutSession) -> SportTag? {
        switch FreeformSummary.dominant(for: session) {
        case .climbing: return .climbing
        case .none:     return nil
        default:        return .general
        }
    }
}

/// A pure, reviewable routine draft (workout-redesign E5) — the converter's output, before any store write.
/// Mirrors the fields `RoutineEditorView` stages locally so the editor can seed itself from a finished
/// session's converted prescription for the user to trim/rename/adjust. Foundation-only (no SwiftData/SwiftUI).
/// `Identifiable` so it drives the editor's `.sheet(item:)` presentation.
struct RoutineDraft: Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var sport: SportTag?
    var level: RoutineLevel?
    var detail: String?
    var exercises: [RoutineExercise]
}
