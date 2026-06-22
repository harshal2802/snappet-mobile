import Foundation

// MARK: - Clips feed — pure post composition (prompt 82)
//
// Turns a session's tagged media into Instagram-style "posts" for the new **Clips** tab: one post per
// exercise (gym) or climb (Kilter), its clips a capture-ordered carousel. Pure + testable in
// `SnappetTests` — no SwiftData, no SwiftUI, no Photos. Reuses the Recap feed's `FeedMedia` grouping
// (one source of truth for clip→post bucketing) so the two surfaces can never disagree on what groups.
//
// The session is the single source of truth: the SwiftUI surface (`ClipsFeedView`) snapshots the
// `@Model`s into the plain inputs below at the store edge, and the feed only reads.

/// Which module a post's session belongs to — drives routing + the subtitle.
enum ClipFeedKind: String, Sendable, Equatable { case kilter, gym }

/// A plain-value snapshot of one session for the Clips feed.
struct ClipFeedSessionMeta: Sendable, Equatable {
    var id: UUID
    var kind: ClipFeedKind
    /// Routine name (gym) or the Kilter session title; the caller supplies a sensible fallback.
    var title: String
    var startedAt: Date
    /// Kilter board angle for the subtitle (nil for gym).
    var angle: Int?
}

/// Climb name / grade / angle for a `climbUUID` — snapshotted from `KilterLogEntry` (no catalog round-trip).
struct ClipFeedClimbMeta: Sendable, Equatable {
    var name: String
    var gradeLabel: String
    var angle: Int
}

/// One clip in a post: the media + a derived attempt/set label shown as the overlay chip.
struct ClipFeedItem: Identifiable, Sendable, Equatable {
    var media: MediaInput
    /// "Attempt 3" (climb) · "Set 3" (gym) · "Clip 2" (untagged, multi) · nil (single untagged clip).
    var attemptLabel: String?
    var id: UUID { media.id }
}

/// One Clips-feed post = all of one exercise's / one climb's clips in a session.
struct ClipFeedPost: Identifiable, Sendable, Equatable {
    enum Discipline: String, Sendable, Equatable { case climbing, strength, general }

    /// Stable across reloads: `groupKey@sessionID` (same climb in two sessions ⇒ two posts).
    var id: String
    var sessionID: UUID
    var kind: ClipFeedKind
    /// `SuiteRouter.open(module:)` id for "Go to session" — "kilter" | "workout-log".
    var moduleID: String
    var discipline: Discipline
    /// Header line 1 (the "yellow circle"): the climb / exercise name.
    var title: String
    /// Header line 2: the session + context, e.g. "Tuesday Session · 40°".
    var subtitle: String
    /// The per-poster overlay's second line, e.g. "6c · 40°" (climb); "" when none (gym).
    var overlayDetail: String
    var climbUUID: String?
    var exerciseID: UUID?
    /// Capture time of the first clip — the feed's reverse-chronological sort key.
    var captureAt: Date
    var clips: [ClipFeedItem]

    var clipCount: Int { clips.count }
}

enum ClipFeedComposer {

    /// One session's media, snapshotted at the store edge.
    struct SessionBundle: Sendable {
        var meta: ClipFeedSessionMeta
        /// This session's media (videos + photos), already bridged from `SessionMedia`.
        var clips: [MediaInput]
    }

    /// Compose every session's media into posts, newest capture first.
    ///
    /// - `climbMeta`: `climbUUID` → name/grade/angle (from the session's `KilterLogEntry`s).
    /// - `exerciseName`: `SessionExercise.id` → display name (resolved from the bundled catalog by the
    ///   caller, off the pure path).
    static func posts(sessions: [SessionBundle],
                      climbMeta: [String: ClipFeedClimbMeta],
                      exerciseName: (UUID) -> String) -> [ClipFeedPost] {
        var out: [ClipFeedPost] = []
        for bundle in sessions where !bundle.clips.isEmpty {
            let meta = bundle.meta
            // Resolve a group key → label for FeedMedia.groups (the post's header title).
            let nameFor: (String) -> String = { key in
                if key == "general" { return meta.kind == .kilter ? "Session clips" : (meta.title.isEmpty ? "Session clips" : meta.title) }
                if let climb = climbMeta[key] { return climb.name }
                if let id = UUID(uuidString: key) { return exerciseName(id) }
                return "Clips"
            }
            let groups = FeedMedia.groups(bundle.clips, by: .byExercise, nameFor: nameFor)
            for group in groups where !group.items.isEmpty {
                let ordered = FeedMedia.ordered(group.items)
                guard let first = ordered.first else { continue }
                let key = FeedMedia.groupKey(first)
                let climb = climbMeta[key]
                let discipline: ClipFeedPost.Discipline =
                    first.climbUUID != nil ? .climbing
                    : first.exerciseId != nil ? .strength
                    : .general
                let items: [ClipFeedItem] = ordered.enumerated().map { i, m in
                    let label: String?
                    // Label must match the clip's BUCKET (groupKey = exerciseId ?? climbUUID ?? "general").
                    // Gate the "Set N" branch on `exerciseId != nil` so an untagged clip carrying a stray
                    // `setIndex` (the two are independent optionals on SessionMedia) stays a "Clip N" in its
                    // "general" post instead of a misleading "Set N".
                    if m.climbUUID != nil { label = "Attempt \(i + 1)" }
                    else if m.exerciseId != nil, let s = m.setIndex { label = "Set \(s + 1)" }
                    else { label = ordered.count > 1 ? "Clip \(i + 1)" : nil }
                    return ClipFeedItem(media: m, attemptLabel: label)
                }
                out.append(ClipFeedPost(
                    id: "\(key)@\(meta.id.uuidString)",
                    sessionID: meta.id,
                    kind: meta.kind,
                    moduleID: meta.kind == .kilter ? "kilter" : "workout-log",
                    discipline: discipline,
                    title: group.title,
                    subtitle: subtitle(meta: meta, climb: climb),
                    overlayDetail: climb.map { "\($0.gradeLabel) · \($0.angle)°" } ?? "",
                    climbUUID: first.climbUUID,
                    exerciseID: first.exerciseId,
                    captureAt: meta.startedAt.addingTimeInterval(max(0, first.offsetSec)),
                    clips: items))
            }
        }
        return out.sorted { $0.captureAt == $1.captureAt ? $0.id < $1.id : $0.captureAt > $1.captureAt }
    }

    /// Header line 2: session title + a board-angle suffix for climbing.
    private static func subtitle(meta: ClipFeedSessionMeta, climb: ClipFeedClimbMeta?) -> String {
        switch meta.kind {
        case .kilter:
            let base = meta.title.isEmpty ? "Kilter session" : meta.title
            if let a = meta.angle ?? climb?.angle { return "\(base) · \(a)°" }
            return base
        case .gym:
            return meta.title.isEmpty ? "Workout" : meta.title
        }
    }
}
