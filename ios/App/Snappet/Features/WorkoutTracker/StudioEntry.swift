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
        media.filter { $0.sessionID == sessionID && $0.kind == .video && !$0.isReel }
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

    /// Find-or-create the session's project **then** append any video clips discovered after it was
    /// created, so opening the studio *scoped to one clip* (tap a clip → `visibleClipMediaIDs:[id]`)
    /// can't land on a clip the project doesn't know about and show an empty timeline. Mirrors the
    /// Kilter side's inline reconcile (`KilterSessionDetailView.resolveStudioProject`).
    @MainActor
    static func resolveProject(for session: WorkoutSession, media: [SessionMedia],
                               context: ModelContext) -> StudioProject {
        resolveProject(forSessionID: session.id, title: session.routineName, media: media, context: context)
    }

    /// `sessionID`-keyed `resolveProject` (prompt 82): the same find-or-create + late-clip reconcile for
    /// any session id (gym or Kilter), so the Clips feed's "Edit this clip" / "Edit all" can open the
    /// shared session project scoped to a clip without landing on an empty timeline.
    @MainActor
    static func resolveProject(forSessionID sid: UUID, title: String, media: [SessionMedia],
                               context: ModelContext) -> StudioProject {
        let project = findOrCreateProject(forSessionID: sid, title: title, media: media, context: context)
        let present = Set(project.clips.compactMap(\.sessionMediaID))
        // Same reel exclusion as `seedClips` — a reel posted after the project was created must
        // not be "reconciled" into the timeline as if it were late-discovered footage.
        let missing = media.filter { $0.sessionID == sid && $0.kind == .video && !$0.isReel
                                     && !present.contains($0.id) }
            .sorted { $0.offsetSec < $1.offsetSec }
        guard !missing.isEmpty else { return project }
        var order = (project.clips.map(\.order).max() ?? -1) + 1
        for m in missing {
            project.clips.append(TimelineClip(sessionMediaID: m.id, localIdentifier: m.localIdentifier,
                                              isPhoto: false, order: order, trimEnd: m.durationSec))
            order += 1
        }
        try? context.save()
        return project
    }
}
