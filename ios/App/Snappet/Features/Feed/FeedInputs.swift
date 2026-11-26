import Foundation
import SwiftData

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
                        weightUnit: set.weightUnit?.rawValue,
                        durationSec: set.durationSec, distanceMeters: set.distanceMeters,
                        completedAt: set.completedAt)
    }
}

extension WorkoutExerciseInput {
    @MainActor static func from(_ ex: SessionExercise) -> WorkoutExerciseInput {
        // A catalog pick stores no display name — resolve it here so Recap never shows the raw id (prompt 231 bug:
        // "BARBELL_BENCH_PRESS_-_MEDIUM_GRIP" on the Lift PR card).
        let name: String?
        if let given = ex.displayName { name = given } else { name = ExerciseCatalog.byID[ex.exerciseId]?.name }
        return WorkoutExerciseInput(exerciseId: ex.exerciseId, disciplineRaw: ex.disciplineRaw,
                             displayName: name,
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
    static func from(_ m: SessionMedia, edit: ClipStudioEdit? = nil) -> MediaInput {
        // A baked clip carries its edit IN the pixels — never live-reflect on top of it (that would
        // double-apply trims and double-draw the HR tile), regardless of what the project stores.
        MediaInput(id: m.id, kind: m.kindRaw, offsetSec: m.offsetSec, durationSec: m.durationSec,
                   exerciseId: m.assignedExerciseID, setIndex: m.assignedSetIndex,
                   climbUUID: m.assignedClimbUUID, localIdentifier: m.localIdentifier,
                   aspect: m.aspectRatio, edit: (m.isBaked || m.isReel) ? nil : edit,
                   isBaked: m.isBaked, reelTitle: m.reelTitle, timeMap: m.bakeTimeMap)
    }
}

extension ClipStudioEdit {
    /// Every clip's Studio edit, keyed by `SessionMedia.id`, for a whole LIST of media rows at
    /// once (prompt 309). Every surface that shows a clip or a number next to one stamps the
    /// edit on its `MediaInput` from this, so the kept range, the HR window and the "Clip only"
    /// scope set in the Studio are the same in the Clips feed, Recap, the activity pages, the
    /// Kilter library and the festival set screen. One pass over the projects per list, never
    /// per cell: `StudioProject.clips` is the largest blob on the project, so only the projects
    /// of sessions that have media in `media` are opened. First project wins per media id (a
    /// session has one today).
    @MainActor
    static func byMedia(projects: [StudioProject], media: [SessionMedia]) -> [UUID: ClipStudioEdit] {
        guard !projects.isEmpty, !media.isEmpty else { return [:] }
        let mediaIDByLocal = Dictionary(media.map { ($0.localIdentifier, $0.id) },
                                        uniquingKeysWith: { a, _ in a })
        let mediaSessionIDs = Set(media.map(\.sessionID))
        var edits: [UUID: ClipStudioEdit] = [:]
        for p in projects where mediaSessionIDs.contains(p.sessionID) {
            edits.merge(byMedia(clips: p.clips, mediaIDByLocalID: mediaIDByLocal)) { a, _ in a }
        }
        return edits
    }

    /// The same, for a surface that holds no `@Query` of the projects: one fetch.
    @MainActor
    static func byMedia(context: ModelContext, media: [SessionMedia]) -> [UUID: ClipStudioEdit] {
        guard !media.isEmpty else { return [:] }
        let projects = (try? context.fetch(FetchDescriptor<StudioProject>())) ?? []
        return byMedia(projects: projects, media: media)
    }
}

/// Bridges @Model arrays → composed FeedCards. Shared by FeedView (F1) + WallView (F7) so the
/// derive-on-read pipeline lives in one place.
enum FeedQuery {
    @MainActor static func cards(kilterSessions: [KilterSession], kilterLogs: [KilterLogEntry],
                      workoutSessions: [WorkoutSession], litEvents: [KilterLitEvent],
                      sessionMedia: [SessionMedia] = [],
                      window: FeedWindow = .allTime, now: Date) -> [FeedCard] {
        let logs = kilterLogs.map(KilterClimbLog.from)
        let summaries = kilterSessions.map(KilterSessionSummary.from)
        let allTime = KilterAllTimeStats.make(logs: logs, sessions: summaries, now: now)
        // Per-session video-clip count → the a1 carousel + cheap "N clips" affordance + Animate offer.
        var mediaCount: [UUID: Int] = [:]
        for m in sessionMedia where m.kind == .video {
            mediaCount[m.sessionID, default: 0] += 1
        }
        return FeedComposer.compose(
            window: window,
            kilterSessions: kilterSessions.map(KilterSessionInput.from),
            kilterLogs: logs,
            workoutSessions: workoutSessions.map { WorkoutSessionInput.from($0) },
            kilterLitEvents: litEvents.map(LitEventInput.from),
            mediaCountBySession: mediaCount,
            allTimeStats: allTime, now: now)
    }
}

extension WorkoutSessionInput {
    @MainActor static func from(_ w: WorkoutSession) -> WorkoutSessionInput {
        WorkoutSessionInput(id: w.id, routineName: w.routineName, startedAt: w.startedAt,
                            completedAt: w.completedAt, exercises: w.exercises.map { WorkoutExerciseInput.from($0) })
    }
}
