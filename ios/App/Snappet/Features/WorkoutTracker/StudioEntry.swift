import Foundation
import SwiftData

/// The logic behind the **module-level Video Studio entry** (#74). Before this, the multi-clip
/// studio was reachable only via one button four levels deep inside a session's detail — no module
/// surface even mentioned a video editor existed. Now the Gym Tracker dashboard offers "Open in
/// Studio" rows for recent media-bearing sessions and History rows carry a studio shortcut; both
/// derive from these helpers.
///
/// The selection/seeding functions are **pure** (model values in → values out, no SwiftData
/// container, no platform I/O) so they unit-test in `SnappetTests` without a simulator; only
/// `findOrCreateProject` touches a `ModelContext` — the same find-or-create the session detail's
/// "Edit in Video Studio" button used inline, extracted here so every entry opens the *same*
/// project for a session.
enum StudioEntry {
    /// One media-bearing session the dashboard's Video Studio card offers.
    struct Candidate: Identifiable, Equatable, Sendable {
        let sessionID: UUID
        /// The session's routine name (what History rows show, so the candidate reads the same).
        let title: String
        let startedAt: Date
        /// Tagged **video** count — photos don't count: the studio's main track seeds from videos.
        let videoCount: Int
        var id: UUID { sessionID }
    }

    /// Sessions that can open in the studio: completed sessions with ≥ 1 tagged video, newest
    /// first, capped at `limit` (the dashboard is a summary, not a second History).
    static func candidates(history: [WorkoutSession], media: [SessionMedia],
                           limit: Int = 3) -> [Candidate] {
        let counts = videoCounts(media: media)
        return history
            .filter { counts[$0.id] != nil }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { Candidate(sessionID: $0.id, title: $0.routineName,
                             startedAt: $0.startedAt, videoCount: counts[$0.id] ?? 0) }
    }

    /// Video count per session id over the module's media rows. Posted highlight reels don't
    /// count (highlights P5): a reel is a rendered OUTPUT, not editable footage — counting one
    /// here would light up a Studio entry whose seeded timeline (below) is empty.
    static func videoCounts(media: [SessionMedia]) -> [UUID: Int] {
        media.filter { $0.kind == .video && !$0.isReel }
            .reduce(into: [:]) { $0[$1.sessionID, default: 0] += 1 }
    }

    /// Session ids with at least one tagged video — drives the History rows' studio badge +
    /// swipe shortcut.
    static func videoSessionIDs(media: [SessionMedia]) -> Set<UUID> {
        Set(videoCounts(media: media).keys)
    }

    /// The studio's main track seeded from a session's videos in capture order — the single
    /// definition every studio entry shares (extracted from `SessionDetailView.openStudio`).
    /// `media` may be the whole store or already session-scoped; non-video rows are ignored,
    /// and so are posted reels (highlights P5) — editing a rendered reel is odd, and its burned
    /// scorebug would double-render under the Studio's live overlay.
    static func seedClips(for sessionID: UUID, media: [SessionMedia]) -> [TimelineClip] {
        footage(for: sessionID, media: media)
            .sorted { $0.offsetSec < $1.offsetSec }
            .enumerated()
            .map { i, m in
                TimelineClip(sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                             isPhoto: false, order: i, trimEnd: m.durationSec)
            }
    }

    /// Find the session's existing `StudioProject` or create one seeded from its video clips —
    /// the thin SwiftData edge under every "open the studio" affordance.
    @MainActor
    static func findOrCreateProject(for session: WorkoutSession, media: [SessionMedia],
                                    context: ModelContext) -> StudioProject {
        findOrCreateProject(forSessionID: session.id, title: session.routineName, media: media, context: context)
    }

    /// `sessionID`-keyed find-or-create (prompt 82, the Clips feed) — usable for a Kilter session too,
    /// not just a `WorkoutSession`. The studio's main track seeds from the session's videos in capture order.
    @MainActor
    static func findOrCreateProject(forSessionID sid: UUID, title: String, media: [SessionMedia],
                                    context: ModelContext) -> StudioProject {
        if let existing = try? context.fetch(
            FetchDescriptor<StudioProject>(predicate: #Predicate { $0.sessionID == sid })).first {
            return existing
        }
        let project = StudioProject(sessionID: sid, title: title, clips: seedClips(for: sid, media: media))
        context.insert(project)
        try? context.save()
        return project
    }

    // MARK: - Late-clip reconcile (prompt 296)

    /// The outcome of `reconciled`: the timeline with the added clips, and the deletions still remembered.
    struct Reconciled: Equatable {
        var clips: [TimelineClip]
        var removedMediaIDs: [UUID]?
    }

    /// A session's editable footage: its videos, minus posted reels (a reel is rendered OUTPUT —
    /// highlights P5). `sessionID == nil` takes `media` as already session-scoped (the Kilter side).
    static func footage(for sessionID: UUID?, media: [SessionMedia]) -> [SessionMedia] {
        media.filter { (sessionID == nil || $0.sessionID == sessionID) && $0.kind == .video && !$0.isReel }
    }

    /// **Pure** decision behind "open the Studio on an existing project": which session videos join
    /// the timeline. Returns `nil` when nothing changes.
    ///
    /// 1. A video that is on the timeline is left alone.
    /// 2. A video that was never on the timeline (filmed or imported after the project was made) is
    ///    appended, in capture order.
    /// 3. A video the user deleted from the timeline (`removedMediaIDs`) is NOT appended — it stays
    ///    deleted.
    /// 4. Exception — the Studio never opens on an empty timeline: when rules 1–3 leave no clip in
    ///    `scope` (`nil` = the whole project), the deleted videos in that scope come back and are
    ///    forgotten from `removedMediaIDs`. So "Edit this clip" on a deleted clip brings that clip
    ///    back (as a fresh, unedited clip), and a project whose every clip was deleted starts over.
    ///    A scope that still shows at least one clip brings nothing back.
    ///
    /// An id listed in `removedMediaIDs` whose media is on the timeline is ignored and dropped (the
    /// timeline wins), so a stale record can never hide or remove a clip.
    static func reconciled(clips: [TimelineClip], removedMediaIDs: [UUID]?,
                           footage: [SessionMedia], scope: Set<UUID>?) -> Reconciled? {
        let present = Set(clips.compactMap(\.sessionMediaID))
        var removed = (removedMediaIDs ?? []).filter { !present.contains($0) }
        let absent = footage.filter { !present.contains($0.id) }
        var add = absent.filter { !removed.contains($0.id) }

        func inScope(_ id: UUID?) -> Bool {
            guard let scope else { return true }
            return id.map(scope.contains) ?? false
        }
        let showsAClip = clips.contains { inScope($0.sessionMediaID) } || add.contains { inScope($0.id) }
        if !showsAClip {
            let back = absent.filter { removed.contains($0.id) && inScope($0.id) }
            add += back
            let backIDs = Set(back.map(\.id))
            removed.removeAll { backIDs.contains($0) }
        }

        let remembered: [UUID]? = removed.isEmpty ? nil : removed
        guard !add.isEmpty || remembered != removedMediaIDs else { return nil }
        var out = clips
        var order = (clips.map(\.order).max() ?? -1) + 1
        for m in add.sorted(by: { $0.offsetSec < $1.offsetSec }) {
            out.append(TimelineClip(sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                                    isPhoto: false, order: order, trimEnd: m.durationSec))
            order += 1
        }
        return Reconciled(clips: out, removedMediaIDs: remembered)
    }

    /// Apply `reconciled` to a stored project and save — the thin SwiftData edge shared by the gym
    /// and Kilter entries.
    @MainActor
    static func reconcile(_ project: StudioProject, footage: [SessionMedia], scope: Set<UUID>?,
                          context: ModelContext) {
        guard let r = reconciled(clips: project.clips, removedMediaIDs: project.removedMediaIDs,
                                 footage: footage, scope: scope) else { return }
        project.clips = r.clips
        project.removedMediaIDs = r.removedMediaIDs
        try? context.save()
    }

    /// Find-or-create the session's project **then** append any video clips discovered after it was
    /// created, so opening the studio *scoped to one clip* (tap a clip → `visibleClipMediaIDs:[id]`)
    /// can't land on a clip the project doesn't know about and show an empty timeline. A clip the
    /// user deleted from the timeline is not appended again (prompt 296 — the rule is `reconciled`).
    /// `scope` is the set of media ids the Studio is about to show (`nil` = the whole project); pass
    /// the same value as `visibleClipMediaIDs`. The Kilter side shares the rule
    /// (`KilterStudioProjects.resolve`).
    @MainActor
    static func resolveProject(for session: WorkoutSession, media: [SessionMedia],
                               scope: Set<UUID>? = nil, context: ModelContext) -> StudioProject {
        resolveProject(forSessionID: session.id, title: session.routineName, media: media,
                       scope: scope, context: context)
    }

    /// `sessionID`-keyed `resolveProject` (prompt 82): the same find-or-create + late-clip reconcile for
    /// any session id (gym or Kilter), so the Clips feed's "Edit this clip" / "Edit all" can open the
    /// shared session project scoped to a clip without landing on an empty timeline.
    @MainActor
    static func resolveProject(forSessionID sid: UUID, title: String, media: [SessionMedia],
                               scope: Set<UUID>? = nil, context: ModelContext) -> StudioProject {
        let project = findOrCreateProject(forSessionID: sid, title: title, media: media, context: context)
        reconcile(project, footage: footage(for: sid, media: media), scope: scope, context: context)
        return project
    }
}
