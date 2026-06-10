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

    /// Editable drafts: one per **completed** `.repsWeight` set of a played (non-skipped) exercise.
    /// Duration/climb sets and never-logged sets aren't editable here (the issue's reps/weight scope).
    static func drafts(for exercises: [SessionExercise]) -> [Key: Draft] {
        var result: [Key: Draft] = [:]
        for ex in exercises where ex.kind == .repsWeight && !ex.skipped {
            for (i, set) in ex.sets.enumerated() where set.completedAt != nil {
                result[Key(exerciseID: ex.id, setIndex: i)] = Draft(
                    reps: set.actualReps.map(String.init) ?? "",
                    weight: set.actualWeight.map(SetMeasure.formatWeight) ?? "")
            }
        }
        return result
    }

    /// Parse every draft back into its set and return the rewritten array. Only `actualReps` /
    /// `actualWeight` change — completion stamps, units, kinds, set count (and therefore per-set
    /// media indices) all stay, so PRs/volume/progress recompute from the corrected values only.
    static func apply(drafts: [Key: Draft], to exercises: [SessionExercise]) -> [SessionExercise] {
        guard !drafts.isEmpty else { return exercises }
        var result = exercises
        for (e, ex) in result.enumerated() {
            for i in ex.sets.indices {
                guard let draft = drafts[Key(exerciseID: ex.id, setIndex: i)] else { continue }
                result[e].sets[i].actualReps = SetMeasure.parseReps(draft.reps)
                result[e].sets[i].actualWeight = SetMeasure.parseWeight(draft.weight)
            }
        }
        return result
    }
}
