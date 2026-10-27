import Foundation

/// **Pure** "use this activity again" (Library redesign L2, prompt 184): the Activity page's **Log it now** and **Add
/// to routine**. Both start from your most recent instance of the activity, so a climb comes back with its name,
/// grade, gym, wall and colour, a hold with its protocol, a lift with its last sets × reps @ weight — the way you
/// left it. A catalog move you've never done starts blank. Festival sets can't be "logged now" (they belong to a
/// festival night), and neither can a whole-discipline overview.
enum ActivityLauncher {

    /// Whether the page offers Log it now / Add to routine for this activity.
    static func canLaunch(_ key: ActivityKey) -> Bool {
        key.disciplineScope == nil && key.exerciseId != ActivityIdentity.festivalExerciseId
            && !LibraryCatalog.isKilter(key)   // a board climb is logged on the board (prompt 188)
    }

    /// The most recent session entity of the activity (and its session), if any.
    static func latest(_ key: ActivityKey, history: [WorkoutSession],
                       identity: ActivityIdentity) -> (exercise: SessionExercise, session: WorkoutSession)? {
        var best: (SessionExercise, WorkoutSession)?
        for s in history where !s.isActive {
            for ex in s.exercises where identity.matches(key, ex) && ex.sets.contains(where: { $0.completedAt != nil }) {
                if best == nil || s.startedAt > best!.1.startedAt { best = (ex, s) }
            }
        }
        return best.map { (exercise: $0.0, session: $0.1) }
    }

    /// A fresh session entity to log: the latest instance's identity + setup (no sets, new id), or — for a catalog
    /// move you've never logged — a blank strength entity. `nil` when the activity can't be launched.
    static func sessionExercise(for key: ActivityKey, history: [WorkoutSession], identity: ActivityIdentity,
                                catalogExerciseId: String? = nil, template: LibraryTemplate? = nil) -> SessionExercise? {
        guard canLaunch(key) else { return nil }
        // Never logged but created in the Library (prompt 186) → start from its template.
        if latest(key, history: history, identity: identity) == nil, var t = template?.exercise {
            t.id = UUID(); t.sets = []
            return t
        }
        if let last = latest(key, history: history, identity: identity)?.exercise {
            var ex = last
            ex.id = UUID()
            ex.sets = []
            ex.skipped = false
            // A match starts fresh: same sport, format and event, a new opponent and no result (prompt 203).
            if ex.isRacketMatch {
                ex.opponent = nil; ex.racketRound = nil; ex.racketEndRaw = nil
            }
            // Plan the same number of efforts as last time (not for climbs — attempts aren't planned).
            if ex.discipline != .climb {
                let done = last.sets.filter { $0.completedAt != nil }.count
                ex.plannedSets = done > 0 ? done : last.plannedSets
            }
            return ex
        }
        guard let id = catalogExerciseId ?? (key.nameKey.isEmpty ? key.exerciseId : nil) else { return nil }
        return SessionExercise(exerciseId: id, targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [],
                               kindRaw: SetKind.repsWeight.rawValue)
    }

    /// A routine block for the activity, prescribing what you did last time (sets, reps, top weight · the climb ·
    /// the hold · the distance), or a light default for a never-logged catalog move.
    static func routineBlock(for key: ActivityKey, history: [WorkoutSession], identity: ActivityIdentity,
                             defaultUnit: WeightUnit, catalogExerciseId: String? = nil,
                             template: LibraryTemplate? = nil) -> RoutineExercise? {
        guard canLaunch(key) else { return nil }
        guard let last = latest(key, history: history, identity: identity)?.exercise ?? template?.exercise else {
            guard let id = catalogExerciseId ?? (key.nameKey.isEmpty ? key.exerciseId : nil) else { return nil }
            return RoutineExercise(exerciseId: id, sets: 3, reps: "10", restSeconds: 90, weightUnit: defaultUnit)
        }
        let done = last.sets.filter { $0.completedAt != nil }
        let name = last.displayName
        switch last.discipline {
        case .strength:
            let reps = done.compactMap(\.actualReps).max().map(String.init) ?? (last.targetReps.isEmpty ? "10" : last.targetReps)
            let top = done.filter { ($0.actualWeight ?? 0) > 0 }
                .max { WorkoutMath.toKg($0.actualWeight!, $0.weightUnit) < WorkoutMath.toKg($1.actualWeight!, $1.weightUnit) }
            return RoutineExercise(exerciseId: last.exerciseId, sets: max(1, done.count), reps: reps,
                                   restSeconds: last.targetRestSeconds > 0 ? last.targetRestSeconds : 90,
                                   weight: top?.actualWeight, weightUnit: top?.weightUnit ?? defaultUnit,
                                   displayName: name)
        case .climb:
            return RoutineExercise(exerciseId: last.exerciseId, sets: 3, reps: "", restSeconds: 180,
                                   displayName: name, discipline: .climb,
                                   climbTypeRaw: last.climbTypeRaw, climbGradeLabel: last.climbGradeLabel,
                                   climbGradeScaleRaw: last.climbGradeScaleRaw)
        case .timed:
            let hold = done.compactMap(\.durationSec).max()
            return RoutineExercise(exerciseId: last.exerciseId, sets: max(1, done.count), reps: "", restSeconds: 90,
                                   displayName: name, discipline: .timed,
                                   targetDurationSec: last.timedSpec?.mode.isStructured == true ? nil : hold,
                                   timedSpecData: last.timedSpecData, timedCategory: last.timedCategory)
        case .run:
            let meters = done.compactMap(\.distanceMeters).reduce(0, +)
            return RoutineExercise(exerciseId: last.exerciseId, sets: 1, reps: "", restSeconds: 0,
                                   displayName: name, discipline: .run,
                                   targetDistanceMeters: meters > 0 ? meters : template?.targetDistanceMeters)
        case .racket:
            return nil   // routines stay racket-free in v1 (prompt 203)
        case .dance, .other:
            return RoutineExercise(exerciseId: last.exerciseId, sets: 1, reps: "", restSeconds: 0,
                                   displayName: name, discipline: last.discipline,
                                   targetDurationSec: done.compactMap(\.durationSec).max())
        }
    }
}
