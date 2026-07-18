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
    /// Session end — gym `WorkoutSession.completedAt` / Kilter `KilterSession.endedAt`. `nil` for a still
    /// -running session → the feed sort falls back to `startedAt`. The feed orders posts by session start
    /// then end (NOT the clip capture offset), so all of a session's posts cluster together (prompt: feed
    /// sorted by session start/end). Defaulted so existing call sites compile unchanged.
    var endedAt: Date? = nil
    /// Kilter board angle for the subtitle (nil for gym).
    var angle: Int?
    /// `true` when this session is an **Apple Watch workout the app never controlled** (imported via
    /// `WatchWorkoutImportService`) — drives the ⌚ source pill on the poster. Defaulted so existing
    /// call sites compile unchanged. (watch-workouts-clips P3)
    var isFromAppleWatch: Bool = false
}

/// Climb name / grade / angle for a `climbUUID` — snapshotted from `KilterLogEntry` (no catalog round-trip).
struct ClipFeedClimbMeta: Sendable, Equatable {
    var name: String
    var gradeLabel: String
    var angle: Int
}

/// Festival flavor for a media id (festival prompt 03) — snapshotted from `FestivalClipTag` +
/// `FestivalLineup` rows (denormalized fields only; no pack inflation on the compose path).
/// A TAGGED clip carries `setKey`/`artist`/`stage` and becomes part of an artist·stage post; a
/// posted REEL from a festival session carries only `festivalName`/`dayLabel` (it keeps its own
/// reel title) so it re-flavors as festival without joining a set carousel.
struct ClipFeedFestivalMeta: Sendable, Equatable {
    /// The set's content id (`FestivalSet.id.uuidString`) — the post's group key. `nil` for reels.
    var setKey: String?
    var artist: String?
    var stage: String?
    var festivalName: String
    /// Rollover-aware poster weekday, e.g. "Saturday".
    var dayLabel: String
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
    enum Discipline: String, Sendable, Equatable { case climbing, strength, festival, general }

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
    /// Capture time of the first clip — shown in the post's "N clips · <when>" meta line. This is NO LONGER
    /// the feed sort key (it's the session's start/end below); kept only for the relative-time display.
    var captureAt: Date
    /// The owning session's start / end — the feed's sort keys (R5: "sorted by session start and end time").
    /// `sessionEndedAt` is `nil` for a still-running session (the sort falls back to `sessionStartedAt`).
    var sessionStartedAt: Date
    var sessionEndedAt: Date?
    /// `true` when the owning session was imported from an Apple Watch workout — the poster shows a ⌚
    /// source pill (watch-workouts-clips P3).
    var isFromAppleWatch: Bool
    /// `true` when this post IS a posted highlight reel (highlights P2) — one reel clip, its own
    /// post, a ✦ REEL header badge, and no live HR overlay (the scorebug is in the pixels).
    var isReel: Bool = false
    var clips: [ClipFeedItem]
    /// Clamped per-post tile aspect (width / height) for adaptive sizing (prompt 92) — the first resolved
    /// clip aspect, clamped IG-style to [0.8 (4:5) … 1.91]; `ClipFeedComposer.defaultAspect` until known.
    var aspect: Double

    var clipCount: Int { clips.count }
}

enum ClipFeedComposer {

    // MARK: Adaptive tile aspect (prompt 92)
    //
    // Tile the carousel to the clip's REAL aspect so a portrait video fills the frame full-height with NO
    // black bars and no crop (the look the user preferred). The clamp only guards absurd extremes: a tile
    // can be as tall as ~2:1 (covers 9:16 phone video = 0.5625) and as wide as 1.91:1 (covers 16:9 = 1.78).
    // A `TabView` carousel shares ONE height across a post's pages, so a post collapses to a single clamped
    // aspect (the first clip with a known aspect); the height animates as the real aspect resolves. Pure —
    // unit-tested in `ClipFeedComposerTests`.

    static let minAspect = 0.5     // ~2:1 tall portrait — covers 9:16 phone video (0.5625) un-clamped
    static let maxAspect = 1.91    // 1.91:1 landscape — covers 16:9 (1.78) un-clamped
    /// 9:16 — the common phone-portrait aspect, shown until a clip's real aspect is backfilled. Defaulting to
    /// the COMMON case means most clips' tiles don't resize (and thus don't animate-reflow) during scroll.
    static let defaultAspect = 9.0 / 16.0

    /// The one clamped aspect a post's carousel uses: the first clip with a resolved aspect, clamped to
    /// `[minAspect, maxAspect]`; `defaultAspect` when none is known yet.
    static func postAspect(_ clips: [MediaInput]) -> Double {
        let raw = clips.compactMap(\.aspect).first ?? defaultAspect
        return min(maxAspect, max(minAspect, raw))
    }

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
    /// - `festivalMeta`: media id → festival flavor (from `FestivalClipTag` rows, festival prompt 03).
    ///   Tagged clips leave the gym grouping and become per-set artist·stage posts; a festival
    ///   session's posted reel keeps its reel post but reads as festival.
    static func posts(sessions: [SessionBundle],
                      climbMeta: [String: ClipFeedClimbMeta],
                      exerciseName: (UUID) -> String,
                      festivalMeta: [UUID: ClipFeedFestivalMeta] = [:]) -> [ClipFeedPost] {
        // R2/R4: collapse duplicate physical assets so one video shows ONCE across the whole feed, before
        // any grouping — covers a within-session dup (one asset on two sets) AND a cross-session dup (the
        // ±90s discovery-window overlap tagging one asset into two sessions).
        let sessions = dedupedByAsset(sessions)
        var out: [ClipFeedPost] = []
        for bundle in sessions where !bundle.clips.isEmpty {
            let meta = bundle.meta
            // Posted highlight reels (highlights P2) get their OWN post each — never grouped into a
            // set/climb carousel: a reel is a finished cut of the session, not another attempt clip.
            let reels = bundle.clips.filter(\.isReel)
            for reel in reels {
                // A reel posted from a festival session reads as FESTIVAL (accent, chip, subtitle)
                // while staying a reel post — its title (e.g. "Fred again.. · Pyramid Stage") is
                // what search matches (festival prompt 03).
                let fest = festivalMeta[reel.id]
                out.append(ClipFeedPost(
                    id: "reel-\(reel.id.uuidString)@\(meta.id.uuidString)",
                    sessionID: meta.id,
                    kind: meta.kind,
                    moduleID: meta.kind == .kilter ? "kilter" : "workout-log",
                    discipline: fest != nil ? .festival
                        : meta.kind == .kilter ? .climbing : .strength,
                    title: reel.reelTitle ?? "Highlights",
                    subtitle: fest.map { "\($0.festivalName) · \($0.dayLabel)" }
                        ?? subtitle(meta: meta, climb: nil),
                    overlayDetail: "",
                    climbUUID: nil,
                    exerciseID: nil,
                    captureAt: meta.startedAt.addingTimeInterval(max(0, reel.offsetSec)),
                    sessionStartedAt: meta.startedAt,
                    sessionEndedAt: meta.endedAt,
                    isFromAppleWatch: meta.isFromAppleWatch,
                    isReel: true,
                    clips: [ClipFeedItem(media: reel, attemptLabel: nil)],
                    aspect: postAspect([reel])))
            }
            // Festival-tagged clips (festival prompt 03) leave the exercise grouping and become
            // per-SET artist·stage posts — the payoff surface of the whole tagging arc. Grouped by
            // the set's content id so one set = one post per session, whatever entity each clip
            // was recorded against.
            let taggedBySet = Dictionary(
                grouping: bundle.clips.filter { !$0.isReel && festivalMeta[$0.id]?.setKey != nil },
                by: { festivalMeta[$0.id]!.setKey! })
            for (setKey, members) in taggedBySet.sorted(by: { $0.key < $1.key }) {
                let ordered = FeedMedia.ordered(members)
                guard let first = ordered.first, let fest = festivalMeta[first.id],
                      let artist = fest.artist, let stage = fest.stage else { continue }
                let items = ordered.enumerated().map { i, m in
                    ClipFeedItem(media: m, attemptLabel: ordered.count > 1 ? "Clip \(i + 1)" : nil)
                }
                out.append(ClipFeedPost(
                    id: "fest-\(setKey)@\(meta.id.uuidString)",
                    sessionID: meta.id,
                    kind: meta.kind,
                    moduleID: "workout-log",   // "Go to session" opens the dance session
                    discipline: .festival,
                    title: "\(artist) · \(stage)",
                    subtitle: "\(fest.festivalName) · \(fest.dayLabel)",
                    overlayDetail: "",
                    climbUUID: nil,
                    exerciseID: nil,
                    captureAt: meta.startedAt.addingTimeInterval(max(0, first.offsetSec)),
                    sessionStartedAt: meta.startedAt,
                    sessionEndedAt: meta.endedAt,
                    isFromAppleWatch: meta.isFromAppleWatch,
                    clips: items,
                    aspect: postAspect(ordered)))
            }
            let bundle = SessionBundle(meta: meta, clips: bundle.clips.filter {
                !$0.isReel && festivalMeta[$0.id]?.setKey == nil
            })
            guard !bundle.clips.isEmpty else { continue }
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
                    sessionStartedAt: meta.startedAt,
                    sessionEndedAt: meta.endedAt,
                    isFromAppleWatch: meta.isFromAppleWatch,
                    clips: items,
                    aspect: postAspect(ordered)))
            }
        }
        return out.sorted(by: postOrder)
    }

    /// Feed order (R5): newest SESSION first — sort by session **start**, then session **end**, so a post's
    /// position is its session's place in time (NOT the clip capture offset). All of a session's posts share
    /// the same start+end, so they cluster; capture-time then id break ties within a session, keeping the
    /// order stable + deterministic.
    static func postOrder(_ a: ClipFeedPost, _ b: ClipFeedPost) -> Bool {
        if a.sessionStartedAt != b.sessionStartedAt { return a.sessionStartedAt > b.sessionStartedAt }
        let aEnd = a.sessionEndedAt ?? a.sessionStartedAt, bEnd = b.sessionEndedAt ?? b.sessionStartedAt
        if aEnd != bEnd { return aEnd > bEnd }
        if a.captureAt != b.captureAt { return a.captureAt > b.captureAt }
        return a.id < b.id
    }

    // MARK: Duplicate-asset collapse (R2/R4)

    /// Remove duplicate physical assets so one video appears once across the WHOLE feed. A `localIdentifier`
    /// is the PHAsset identity, so two `MediaInput`s sharing it are the same video — whether on two sets of
    /// one session or discovered into two adjacent sessions (the ±90s pad overlap). Deterministic survivor:
    /// an **assigned** clip (tied to an exercise/climb) beats a General one (show the video under its set,
    /// not the generic session bucket); then the **more-recent** session (later `startedAt`); then the
    /// smaller media id (stable). Pure → unit-tested in `ClipFeedComposerTests`.
    static func dedupedByAsset(_ sessions: [SessionBundle]) -> [SessionBundle] {
        var winner: [String: (sessionIndex: Int, clip: MediaInput)] = [:]
        for (s, bundle) in sessions.enumerated() {
            for clip in bundle.clips {
                let key = clip.localIdentifier
                if let cur = winner[key] {
                    if challengerWins(s, clip, over: cur, sessions: sessions) { winner[key] = (s, clip) }
                } else {
                    winner[key] = (s, clip)
                }
            }
        }
        return sessions.enumerated().map { s, bundle in
            SessionBundle(meta: bundle.meta, clips: bundle.clips.filter {
                guard let w = winner[$0.localIdentifier] else { return false }
                return w.sessionIndex == s && w.clip.id == $0.id
            })
        }
    }

    /// Does the challenger clip beat the incumbent for the same `localIdentifier`? (Survivor rule above.)
    private static func challengerWins(_ s: Int, _ clip: MediaInput,
                                       over incumbent: (sessionIndex: Int, clip: MediaInput),
                                       sessions: [SessionBundle]) -> Bool {
        let cAssigned = isAssigned(clip), iAssigned = isAssigned(incumbent.clip)
        if cAssigned != iAssigned { return cAssigned }                          // assigned beats general
        let cStart = sessions[s].meta.startedAt, iStart = sessions[incumbent.sessionIndex].meta.startedAt
        if cStart != iStart { return cStart > iStart }                          // more-recent session wins
        return clip.id.uuidString < incumbent.clip.id.uuidString                // stable
    }

    /// A clip is "assigned" when it's tied to a specific exercise/set or climb (vs the General bucket).
    private static func isAssigned(_ m: MediaInput) -> Bool { m.exerciseId != nil || m.climbUUID != nil }

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
