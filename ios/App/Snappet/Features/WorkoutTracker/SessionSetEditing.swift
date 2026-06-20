import Foundation

/// PURE build/apply for the session detail's set-edit mode. Originally reps/weight-only (issue #73);
/// **workout-redesign follow-up: all-axis** — a completed set of ANY discipline becomes editable, so a
/// fat-fingered climb grade, a wrong hold time, or a bad run distance is correctable after the fact (not
/// just a mistyped weight). Save parses the drafts back with the player's exact rules (`SetMeasure`) and
/// rewrites the exercises array; the view stays thin and this round-trip is unit-tested without a
/// simulator. No SwiftData, no UI.
///
/// **The strength (reps/weight) path is unchanged** from the original — same seed, same apply, same unit
/// conversion — so legacy lifting edits keep their exact behavior (regression-pinned). The new axes are:
/// **timed** (duration), **running** (distance + duration), **climbing** (grade + status + attempts).
/// (The combined timed-strength duration edit is intentionally out of scope — strength stays reps/weight.)
enum SessionSetEditing {

    /// Addresses one editable set: the owning exercise's id + the set's index (the same pairing
    /// `SessionMedia` assignment uses, so edits can never desync media from its set).
    struct Key: Hashable, Sendable {
        let exerciseID: UUID
        let setIndex: Int
    }

    /// The text being edited for one set — a superset of every axis; only the fields relevant to the
    /// owning exercise's discipline/kind are seeded + rendered + applied (the others stay empty/untouched).
    struct Draft: Equatable, Sendable {
        var reps: String = ""
        var weight: String = ""
        var duration: String = ""        // timed hold / run leg time — "M:SS"
        var distance: String = ""        // run distance, in the display DistanceUnit
        var grade: String = ""           // climb grade label
        var statusRaw: String? = nil     // KilterAscentStatus.rawValue
        var attempts: String = ""        // climb attempt count
    }

    /// The display distance unit derived from the weight-unit preference (lb→mi), matching the detail view.
    static func distanceUnit(for unit: WeightUnit) -> DistanceUnit { unit == .lb ? .mi : .km }

    /// Editable drafts: one per **completed** set across ALL disciplines (a set completed before its
    /// exercise was skipped still counts in stats, so it stays visible + fixable). Each draft is seeded
    /// only in the axes its exercise's discipline/kind uses; the weight is seeded **in the preferred
    /// display `unit`** (WYSIWYG with the read-only tile).
    static func drafts(for exercises: [SessionExercise], unit: WeightUnit) -> [Key: Draft] {
        let du = distanceUnit(for: unit)
        var result: [Key: Draft] = [:]
        for ex in exercises {
            for (i, set) in ex.sets.enumerated() where set.completedAt != nil {
                result[Key(exerciseID: ex.id, setIndex: i)] =
                    draft(for: set, discipline: ex.discipline, kind: ex.kind, unit: unit, distanceUnit: du)
            }
        }
        return result
    }

    /// Seed a single set's draft per its discipline/kind.
    static func draft(for set: SetLog, discipline: WorkoutDiscipline, kind: SetKind,
                      unit: WeightUnit, distanceUnit: DistanceUnit) -> Draft {
        var d = Draft()
        if discipline == .run {
            d.distance = SetMeasure.distanceFieldText(set.distanceMeters ?? 0, unit: distanceUnit)
            if let s = set.durationSec, s > 0 { d.duration = SetMeasure.formatDuration(s) }
            return d
        }
        switch kind {
        case .repsWeight:
            d.reps = set.actualReps.map(String.init) ?? ""
            d.weight = set.actualWeight.map {
                SetMeasure.formatWeight(displayWeight($0, storedUnit: set.weightUnit, in: unit))
            } ?? ""
        case .duration:
            if let s = set.durationSec, s > 0 { d.duration = SetMeasure.formatDuration(s) }
        case .climbAttempt:
            d.grade = set.climbGradeLabel ?? ""
            d.statusRaw = set.climbStatusRaw
            d.attempts = set.climbAttempts.map(String.init) ?? ""
        }
        return d
    }

    /// Parse every **edited** draft back into its set and return the rewritten array. Untouched drafts are
    /// skipped wholesale (compared against a re-derived seed) so re-parsing converted display text never
    /// drifts a set the user never touched. Completion stamps, kinds, disciplines, set count (and therefore
    /// per-set media indices) all stay, so PRs / volume / progress / pyramids recompute from the corrected
    /// values only.
    static func apply(drafts: [Key: Draft], to exercises: [SessionExercise],
                      unit: WeightUnit) -> [SessionExercise] {
        guard !drafts.isEmpty else { return exercises }
        let du = distanceUnit(for: unit)
        let seeded = self.drafts(for: exercises, unit: unit)
        var result = exercises
        for (e, ex) in result.enumerated() {
            let discipline = ex.discipline, kind = ex.kind
            for i in ex.sets.indices {
                let key = Key(exerciseID: ex.id, setIndex: i)
                guard let draft = drafts[key], draft != seeded[key] else { continue }
                apply(draft, to: &result[e].sets[i], discipline: discipline, kind: kind, unit: unit, distanceUnit: du)
            }
        }
        return result
    }

    /// Apply one edited draft to one set, per discipline/kind. Each branch writes ONLY its own axes, so a
    /// climb edit never touches reps/weight and vice-versa (mirrors the seed).
    static func apply(_ d: Draft, to set: inout SetLog, discipline: WorkoutDiscipline, kind: SetKind,
                      unit: WeightUnit, distanceUnit: DistanceUnit) {
        if discipline == .run {
            set.distanceMeters = SetMeasure.parseDistance(d.distance, unit: distanceUnit)
            set.durationSec = SetMeasure.parseDuration(d.duration)
            return
        }
        switch kind {
        case .repsWeight:
            // Unchanged from the original reps/weight editor (regression-pinned): parse reps, and store the
            // parsed weight together with `weightUnit = unit` (what the field displayed), else clear it.
            set.actualReps = SetMeasure.parseReps(d.reps)
            if let weight = SetMeasure.parseWeight(d.weight) {
                set.actualWeight = weight
                set.weightUnit = unit
            } else {
                set.actualWeight = nil
            }
        case .duration:
            set.durationSec = SetMeasure.parseDuration(d.duration)
        case .climbAttempt:
            let g = d.grade.trimmingCharacters(in: .whitespaces)
            set.climbGradeLabel = g.isEmpty ? nil : g
            set.climbStatusRaw = d.statusRaw
            set.climbAttempts = SetMeasure.parseReps(d.attempts)
        }
    }

    /// A stored weight re-expressed in the display unit. Same-unit values pass through raw; a
    /// cross-unit value converts via kg rounded to one decimal (the `LastSetLookup` hint's rule),
    /// so float noise never seeds an edit field.
    private static func displayWeight(_ value: Double, storedUnit: WeightUnit?,
                                      in unit: WeightUnit) -> Double {
        guard (storedUnit ?? .kg) != unit else { return value }
        let converted = WorkoutMath.kgToUnit(WorkoutMath.toKg(value, storedUnit), unit)
        return (converted * 10).rounded() / 10
    }
}
