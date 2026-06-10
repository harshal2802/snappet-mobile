import Foundation

/// PURE build/apply for the summary's set-edit mode (issue #73): completed reps/weight sets become
/// editable text drafts, and Save parses them back with the live player's exact input rules
/// (`SetMeasure.parseReps`/`parseWeight`) and rewrites the exercises array. The view stays thin and
/// this round-trip is unit-tested without a simulator. No SwiftData, no UI.
enum SessionSetEditing {

    /// Addresses one editable set: the owning exercise's id + the set's index (the same pairing
    /// `SessionMedia` assignment uses, so edits can never desync media from its set).
    struct Key: Hashable, Sendable {
        let exerciseID: UUID
        let setIndex: Int
    }

    /// The text being edited for one set — mirrors the player's `repsText`/`weightText` fields.
    struct Draft: Equatable, Sendable {
        var reps: String
        var weight: String
    }

    /// Editable drafts: one per **completed** `.repsWeight` set — including sets completed before
    /// their exercise was skipped (`WorkoutMath` counts those in volume/PRs, so they must stay
    /// visible and fixable). Duration/climb sets and never-logged sets aren't editable here (the
    /// issue's reps/weight scope). The weight is seeded **in the preferred display `unit`** — the
    /// value the read-only tile shows — so editing is WYSIWYG rather than exposing a raw stored
    /// value in a different unit.
    static func drafts(for exercises: [SessionExercise], unit: WeightUnit) -> [Key: Draft] {
        var result: [Key: Draft] = [:]
        for ex in exercises where ex.kind == .repsWeight {
            for (i, set) in ex.sets.enumerated() where set.completedAt != nil {
                result[Key(exerciseID: ex.id, setIndex: i)] = Draft(
                    reps: set.actualReps.map(String.init) ?? "",
                    weight: set.actualWeight.map {
                        SetMeasure.formatWeight(displayWeight($0, storedUnit: set.weightUnit, in: unit))
                    } ?? "")
            }
        }
        return result
    }

    /// Parse every **edited** draft back into its set and return the rewritten array. A parsed
    /// weight is stored together with `weightUnit = unit` — the unit the field displayed, so what
    /// the user confirmed seeing is exactly what's saved. Untouched drafts are skipped wholesale
    /// (compared against a re-derived seed): re-parsing the converted display text ("132.3" for a
    /// stored 60 kg) would otherwise drift every set the user never touched. Completion stamps,
    /// kinds, set count (and therefore per-set media indices) all stay, so PRs/volume/progress
    /// recompute from the corrected values only.
    static func apply(drafts: [Key: Draft], to exercises: [SessionExercise],
                      unit: WeightUnit) -> [SessionExercise] {
        guard !drafts.isEmpty else { return exercises }
        let seeded = self.drafts(for: exercises, unit: unit)
        var result = exercises
        for (e, ex) in result.enumerated() {
            for i in ex.sets.indices {
                let key = Key(exerciseID: ex.id, setIndex: i)
                guard let draft = drafts[key], draft != seeded[key] else { continue }
                result[e].sets[i].actualReps = SetMeasure.parseReps(draft.reps)
                if let weight = SetMeasure.parseWeight(draft.weight) {
                    result[e].sets[i].actualWeight = weight
                    result[e].sets[i].weightUnit = unit
                } else {
                    result[e].sets[i].actualWeight = nil
                }
            }
        }
        return result
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
