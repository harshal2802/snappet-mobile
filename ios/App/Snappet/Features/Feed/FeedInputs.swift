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
        return byMedia(projects: projects,
                       mediaIDByLocalID: Dictionary(media.map { ($0.localIdentifier, $0.id) },
                                                    uniquingKeysWith: { a, _ in a }),
                       sessionIDs: Set(media.map(\.sessionID)))
    }

    /// The same from plain values: only the projects of `sessionIDs` are opened.
    @MainActor
    static func byMedia(projects: [StudioProject], mediaIDByLocalID: [String: UUID],
                        sessionIDs: Set<UUID>) -> [UUID: ClipStudioEdit] {
        var edits: [UUID: ClipStudioEdit] = [:]
        for p in projects where sessionIDs.contains(p.sessionID) {
            edits.merge(byMedia(clips: p.clips, mediaIDByLocalID: mediaIDByLocalID)) { a, _ in a }
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

    /// When the Studio last saved anything: how many projects there are and the newest change.
    /// Two small fetches (a count, and one row), no project opened. A screen that loaded its
    /// clips once compares this when it comes back on screen and reloads only if it moved.
    struct Stamp: Equatable, Sendable {
        var count: Int
        var newest: Date?
    }

    @MainActor
    static func stamp(context: ModelContext) -> Stamp {
        var newest = FetchDescriptor<StudioProject>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        newest.fetchLimit = 1
        return Stamp(count: (try? context.fetchCount(FetchDescriptor<StudioProject>())) ?? 0,
                     newest: (try? context.fetch(newest))?.first?.updatedAt)
    }
}

extension MediaInput {
    /// Every media row as the Clips feed shows it, by session: each with its Studio edit
    /// (prompt 309). The feed's snapshot is built from this and nothing else, so a test of this
    /// function is a test of what the feed is handed.
    @MainActor
    static func bySession(_ media: [SessionMedia], projects: [StudioProject]) -> [UUID: [MediaInput]] {
        let edits = ClipStudioEdit.byMedia(projects: projects, media: media)
        var out: [UUID: [MediaInput]] = [:]
        for m in media { out[m.sessionID, default: []].append(MediaInput.from(m, edit: edits[m.id])) }
        return out
    }
}

/// One session's clip edits at a time, kept until that session's project changes (prompt 309).
/// Recap asks per CARD ON SCREEN, so a Studio save re-reads one project's clips (the one that
/// changed) the next time its card is drawn, and nothing else: the cards and the media index are
/// not recomposed for it, and a project whose card was never scrolled to is never opened.
@MainActor
final class ClipStudioEditCache {
    private struct Entry {
        var updatedAt: Date
        var mediaCount: Int
        var edits: [UUID: ClipStudioEdit]
    }
    private var entries: [UUID: Entry] = [:]
    private var projectsKey: ClipStudioEdit.Stamp?
    private var projectBySession: [UUID: StudioProject] = [:]
    /// How many times a project's clips were opened (the tests read this).
    private(set) var opened = 0

    /// `projects` newest first (the feed's `@Query` order). `media` = that session's rows.
    func edits(forSession sid: UUID, projects: [StudioProject], media: [SessionMedia]) -> [UUID: ClipStudioEdit] {
        let key = ClipStudioEdit.Stamp(count: projects.count, newest: projects.first?.updatedAt)
        if key != projectsKey {
            projectsKey = key
            projectBySession = Dictionary(projects.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        }
        guard let project = projectBySession[sid], !media.isEmpty else { return [:] }
        if let hit = entries[sid], hit.updatedAt == project.updatedAt, hit.mediaCount == media.count {
            return hit.edits
        }
        opened += 1
        let edits = ClipStudioEdit.byMedia(projects: [project], media: media)
        entries[sid] = Entry(updatedAt: project.updatedAt, mediaCount: media.count, edits: edits)
        return edits
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
