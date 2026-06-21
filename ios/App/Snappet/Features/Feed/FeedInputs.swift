import Foundation

// MARK: - @Model -> plain-value bridges for FeedComposer (F0)
//
// These convert SwiftData @Model objects into the pure inputs `FeedComposer.compose`
// consumes. They live separately from the pure engine so FeedComposer.swift stays
// @Model-free (and Kotlin-portable). Callers (F1 FeedView) bridge at the store edge.

extension KilterSessionInput {
    static func from(_ s: KilterSession) -> KilterSessionInput {
        KilterSessionInput(id: s.id, startedAt: s.startedAt, endedAt: s.endedAt,
                           angle: s.angle, title: s.title, layoutId: s.layoutId,
                           hrSeries: s.hrSeries, maxHR: s.maxHR, restHR: s.restHR)
    }
}

extension WorkoutSetInput {
    static func from(_ set: SetLog) -> WorkoutSetInput {
        WorkoutSetInput(actualReps: set.actualReps, actualWeight: set.actualWeight,
                        durationSec: set.durationSec, distanceMeters: set.distanceMeters,
                        completedAt: set.completedAt)
    }
}

extension WorkoutExerciseInput {
    static func from(_ ex: SessionExercise) -> WorkoutExerciseInput {
        WorkoutExerciseInput(exerciseId: ex.exerciseId, disciplineRaw: ex.disciplineRaw, displayName: ex.displayName,
                             skipped: ex.skipped, sets: ex.sets.map(WorkoutSetInput.from))
    }
}

extension LitEventInput {
    static func from(_ e: KilterLitEvent) -> LitEventInput {
        LitEventInput(climbUUID: e.climbUUID, gradeLabel: e.gradeLabel,
                      sessionId: e.sessionId?.uuidString, litAt: e.litAt)
    }
}

extension MediaInput {
    static func from(_ m: SessionMedia) -> MediaInput {
        MediaInput(id: m.id, kind: m.kindRaw, offsetSec: m.offsetSec, durationSec: m.durationSec,
                   exerciseId: m.assignedExerciseID, setIndex: m.assignedSetIndex,
                   climbUUID: m.assignedClimbUUID, localIdentifier: m.localIdentifier)
    }
}

/// Bridges @Model arrays → composed FeedCards. Shared by FeedView (F1) + WallView (F7) so the
/// derive-on-read pipeline lives in one place.
enum FeedQuery {
    static func cards(kilterSessions: [KilterSession], kilterLogs: [KilterLogEntry],
                      workoutSessions: [WorkoutSession], litEvents: [KilterLitEvent],
                      window: FeedWindow = .allTime, now: Date) -> [FeedCard] {
        let logs = kilterLogs.map(KilterClimbLog.from)
        let summaries = kilterSessions.map(KilterSessionSummary.from)
        let allTime = KilterAllTimeStats.make(logs: logs, sessions: summaries, now: now)
        return FeedComposer.compose(
            window: window,
            kilterSessions: kilterSessions.map(KilterSessionInput.from),
            kilterLogs: logs,
            workoutSessions: workoutSessions.map(WorkoutSessionInput.from),
            kilterLitEvents: litEvents.map(LitEventInput.from),
            allTimeStats: allTime, now: now)
    }
}

extension WorkoutSessionInput {
    static func from(_ w: WorkoutSession) -> WorkoutSessionInput {
        WorkoutSessionInput(id: w.id, routineName: w.routineName, startedAt: w.startedAt,
                            completedAt: w.completedAt, exercises: w.exercises.map(WorkoutExerciseInput.from))
    }
}
