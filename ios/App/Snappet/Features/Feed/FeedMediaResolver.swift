import Foundation
import SwiftData
import HighlightEngine

// MARK: - Recap Feed — @Model → snapshot resolver (shared by FeedView + CardDetailView)
//
// Both the feed list (the a1 card carousel) and the card detail snapshot the SAME @Models into the
// plain values the viewer/exporter consume: a session's HR series, its maxHR, a clip-name resolver,
// and the Animate `ClipExportCoordinator.Context`. This is the single source for that extraction so
// the two surfaces can't drift — the R4 clip-collapse bug lived in exactly this snapshot logic, so a
// second copy would double the risk.
//
// The resolver reads from a precomputed `FeedMediaIndex` (O(1) dict lookups) instead of re-scanning
// the @Query arrays per card. @MainActor because it reads SwiftData @Models; it copies them into plain
// values here so nothing SwiftData ever crosses into the engine/exporter.

/// Per-refresh O(1) lookup index over the feed's @Query'd @Models, built ONCE per `feedSignature()`
/// change (alongside the composed cards, in FeedMemo) so the media path stops re-scanning `allMedia` /
/// `kilterSessions` / `workoutSessions` / `kilterLogs` per visible card. Holds @Model references; it's
/// consumed only on the MainActor edge and snapshots to plain values inside `FeedMediaResolver` — no
/// @Model crosses into the engine/viewer/exporter (same rule as the @Query arrays themselves).
struct FeedMediaIndex {
    var mediaBySession: [UUID: [SessionMedia]] = [:]
    var kilterByID: [UUID: KilterSession] = [:]
    var workoutByID: [UUID: WorkoutSession] = [:]
    var logsBySession: [UUID: [KilterLogEntry]] = [:]

    init() {}

    init(kilterSessions: [KilterSession], workoutSessions: [WorkoutSession],
         kilterLogs: [KilterLogEntry], allMedia: [SessionMedia]) {
        var media: [UUID: [SessionMedia]] = [:]
        for m in allMedia { media[m.sessionID, default: []].append(m) }
        var logs: [UUID: [KilterLogEntry]] = [:]
        // sessionId is optional; a nil-session log never matched `log.sessionId == sid`, so skip it.
        for l in kilterLogs { if let sid = l.sessionId { logs[sid, default: []].append(l) } }
        self.mediaBySession = media
        self.logsBySession = logs
        self.kilterByID = Dictionary(kilterSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.workoutByID = Dictionary(workoutSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

@MainActor
struct FeedMediaResolver {
    let index: FeedMediaIndex

    init(index: FeedMediaIndex) { self.index = index }

    func hrSeries(for sid: UUID) -> [HRPoint] {
        index.kilterByID[sid]?.hrSeries ?? index.workoutByID[sid]?.hrSeries ?? []
    }

    func maxHR(for sid: UUID) -> Double {
        (index.kilterByID[sid]?.maxHR ?? index.workoutByID[sid]?.maxHR) ?? HeartRateZone.defaultMaxHR
    }

    /// Group key ("general" / climbUUID / exerciseId) → display label. Includes BOTH kilter climb names
    /// and workout exercise names; a kilter-only session simply matches no workout, so its result is the
    /// same as the climb-only path the feed list used.
    func nameResolver(for sid: UUID) -> (String) -> String {
        var map: [String: String] = ["general": "General"]
        for log in index.logsBySession[sid] ?? [] { map[log.climbUUID] = log.climbName }
        if let w = index.workoutByID[sid] {
            for ex in w.exercises { map[ex.id.uuidString] = ex.displayName ?? ex.exerciseId }
        }
        return { key in map[key] ?? "Clip" }
    }

    /// The Animate `Context` for a session that has video clips; `nil` ⇒ the viewer shows a plain Share
    /// (no dead Animate). Handles both a kilter session (duration/restHR from it, `clipName` falling back
    /// to the card's hardest-send grade) and a workout session (duration from it).
    func clipContext(for sid: UUID, card: FeedCard) -> ClipExportCoordinator.Context? {
        let media = index.mediaBySession[sid] ?? []
        guard media.contains(where: { $0.kind == .video }) else { return nil }
        let clips = media.map {
            SessionHighlightInput.Clip(localIdentifier: $0.localIdentifier, isVideo: $0.kind == .video,
                                       offsetSec: $0.offsetSec, durationSec: $0.durationSec)
        }
        let duration: Double
        var restHR: Double? = nil
        var clipName: String? = nil
        if let k = index.kilterByID[sid] {
            duration = (k.endedAt ?? .now).timeIntervalSince(k.startedAt)
            restHR = k.restHR
            // The session's hardest send is the natural clip caption (falls back to nil).
            if case .climbSession(let p) = card.payload { clipName = p.hardestSendGrade }
        } else if let w = index.workoutByID[sid] {
            duration = w.duration
        } else {
            return nil
        }
        return ClipExportCoordinator.Context(
            hrSeries: hrSeries(for: sid), clips: clips, duration: duration,
            maxHR: maxHR(for: sid), restHR: restHR, clipName: clipName)
    }
}
