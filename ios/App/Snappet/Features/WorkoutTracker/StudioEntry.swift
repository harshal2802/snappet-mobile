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

    /// Video count per session id over the module's media rows.
    static func videoCounts(media: [SessionMedia]) -> [UUID: Int] {
        media.filter { $0.kind == .video }
            .reduce(into: [:]) { $0[$1.sessionID, default: 0] += 1 }
    }

    /// Session ids with at least one tagged video — drives the History rows' studio badge +
    /// swipe shortcut.
    static func videoSessionIDs(media: [SessionMedia]) -> Set<UUID> {
        Set(videoCounts(media: media).keys)
    }

    /// The studio's main track seeded from a session's videos in capture order — the single
    /// definition every studio entry shares (extracted from `SessionDetailView.openStudio`).
    /// `media` may be the whole store or already session-scoped; non-video rows are ignored.
    static func seedClips(for sessionID: UUID, media: [SessionMedia]) -> [TimelineClip] {
        media.filter { $0.sessionID == sessionID && $0.kind == .video }
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
        let sid = session.id
        if let existing = try? context.fetch(
            FetchDescriptor<StudioProject>(predicate: #Predicate { $0.sessionID == sid })).first {
            return existing
        }
        let project = StudioProject(sessionID: sid, title: session.routineName,
                                    clips: seedClips(for: sid, media: media))
        context.insert(project)
        try? context.save()
        return project
    }
}
