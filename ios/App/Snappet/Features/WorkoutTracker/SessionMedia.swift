import Foundation
import SwiftData

/// A photo or video tagged to a `WorkoutSession` — the data foundation for the video
/// studio (B2 enriched summary, B3 clip editor, B4 highlight generation).
///
/// Discovered by capture-time window (auto) or added by hand via the PHPicker, and stored
/// **session-scoped**: keyed to its session by `sessionID` (a `WorkoutSession.id` foreign
/// key, the suite's convention) rather than a SwiftData `@Relationship`, so the gallery
/// loads cleanly with a per-session `#Predicate` (mirrors `Routine`/`WorkoutSession` keying
/// the rest of the WorkoutTracker on `UUID`).
///
/// Holds only the PHAsset `localIdentifier` plus a session-relative `offsetSec` — the bytes
/// stay in Photos (on-device only; nothing is copied into the store).
///
/// On top of being *session*-scoped, a clip is also *set*-scoped: `assignedExerciseID` +
/// `assignedSetIndex` point at the `SessionExercise.id` / set index it belongs to (a clip is
/// referenced by `(exerciseID, setIndex)` rather than a `SetLog.id`, because `SetLog` is a
/// positional value with no stable id — see `DESIGN-full-studio.md` §1.1). `nil`
/// `assignedExerciseID` means the clip lives in the **General** bucket (not tied to any set).
/// `assignmentSource` records provenance so the auto-assigner (`SessionMediaAssignment`) only ever
/// re-places `auto` rows and never clobbers a user's `manual`/`general` choice.
@Model
final class SessionMedia {
    /// Stored as a raw string so the top-level schema stays simple (matches the WorkoutTracker
    /// pattern of persisting enums as `…Raw` strings).
    enum Kind: String, Codable, Sendable { case photo, video }

    var id: UUID
    /// FK to `WorkoutSession.id` (NOT a SwiftData relationship — see type doc).
    var sessionID: UUID
    /// The PHAsset `localIdentifier`; resolved to a thumbnail / `AVAsset` on demand.
    var localIdentifier: String
    /// `Kind.rawValue` ("photo" / "video").
    var kindRaw: String
    /// Capture time relative to `session.startedAt`, clamped ≥ 0 (seconds).
    var offsetSec: Double
    /// Video duration in seconds; `nil` for photos.
    var durationSec: Double?
    /// The clip's **oriented** display aspect ratio (width / height) for the Clips feed's adaptive tile
    /// sizing (prompt 92). Additive + optional → SwiftData lightweight migration; `nil` for any clip
    /// captured before this field existed — the feed lazy-backfills it via `ClipAspectResolver` on first
    /// view (photos bake orientation into their pixel dims; videos resolve naturalSize × preferredTransform).
    var aspectRatio: Double?
    /// `true` when added via the PHPicker rather than auto-discovered.
    var addedManually: Bool
    var createdAt: Date

    /// `true` once a Studio bake wrote the edit INTO the Photos asset ("Save to original" /
    /// "Replace original", prompt 117): the pixels carry the trims/filters/overlays/HR tile, so the
    /// feed plays the asset raw, draws NO live HR overlay (nothing double-renders), and shows a BAKED
    /// chip. Additive + optional → SwiftData lightweight migration (`nil` = false for every pre-bake
    /// row). Cleared when a Photos "Revert to Original" is detected at a Studio-open touchpoint.
    var isBakedRaw: Bool?

    /// Non-nil marks this row as a POSTED HIGHLIGHT REEL (highlights P2): the value is the feed
    /// post's title (e.g. "Push Day — Highlights"). The composer gives a reel its own ✦ REEL post
    /// (never grouped into a set/climb carousel) and — like a baked clip — plays it raw: the glass
    /// HR scorebug is already burned into the pixels. Additive + optional → SwiftData lightweight
    /// migration (`nil` = an ordinary clip for every pre-existing row).
    var reelTitle: String?

    // MARK: - Per-set assignment (additive → SwiftData lightweight migration; existing rows
    // decode as an unassigned `auto` clip and fall into General until the auto-assigner runs).
    /// FK to the `SessionExercise.id` this clip is tied to; `nil` = General (no set).
    var assignedExerciseID: UUID?
    /// Index into that exercise's `sets`; `nil` = the exercise as a whole (no specific set).
    var assignedSetIndex: Int?
    /// `MediaAssignmentSource.rawValue` — provenance of the current assignment. **Defaulted** (like
    /// `WorkoutSession.hrSeries`) so existing on-disk rows migrate cleanly to an unassigned `auto`
    /// clip — a non-optional new attribute needs a default for SwiftData's lightweight migration.
    var assignmentSourceRaw: String = MediaAssignmentSource.auto.rawValue

    /// `KilterClimb.uuid` this clip is tied to when the session is a **Kilter climbing session**
    /// (the climb analogue of `assignedExerciseID`/`assignedSetIndex`, which stay `nil` for climbing
    /// rows). Auto-assigned by matching the clip's `offsetSec` to a climb's in-session time window.
    /// Additive + optional → lightweight migration; `nil` for every existing workout clip.
    var assignedClimbUUID: String?

    init(id: UUID = UUID(), sessionID: UUID, localIdentifier: String,
         kind: Kind, offsetSec: Double, durationSec: Double? = nil, aspectRatio: Double? = nil,
         addedManually: Bool = false,
         assignedExerciseID: UUID? = nil, assignedSetIndex: Int? = nil,
         assignedClimbUUID: String? = nil,
         source: MediaAssignmentSource = .auto, createdAt: Date = .now) {
        self.id = id
        self.sessionID = sessionID
        self.localIdentifier = localIdentifier
        self.kindRaw = kind.rawValue
        self.offsetSec = max(0, offsetSec)
        self.durationSec = durationSec
        self.aspectRatio = aspectRatio
        self.addedManually = addedManually
        self.assignedExerciseID = assignedExerciseID
        self.assignedSetIndex = assignedSetIndex
        self.assignedClimbUUID = assignedClimbUUID
        self.assignmentSourceRaw = source.rawValue
        self.createdAt = createdAt
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .photo }

    /// Typed view over `isBakedRaw` (nil = false — pre-bake rows).
    var isBaked: Bool {
        get { isBakedRaw ?? false }
        set { isBakedRaw = newValue }
    }

    /// Typed view over `assignmentSourceRaw` (defaults to `.auto` for any unknown raw).
    var assignmentSource: MediaAssignmentSource {
        get { MediaAssignmentSource(rawValue: assignmentSourceRaw) ?? .auto }
        set { assignmentSourceRaw = newValue.rawValue }
    }

    /// `true` when the clip is not tied to a specific set (the General bucket): either explicitly
    /// pinned `general`, or simply has no `assignedExerciseID`.
    var isGeneral: Bool { assignmentSource == .general || assignedExerciseID == nil }

    /// A posted highlight reel (highlights P2) — `reelTitle` is the marker AND the display title.
    var isReel: Bool { reelTitle != nil }

    /// Every `localIdentifier` stored in ANY session — the GLOBAL dedup set auto-discovery checks so
    /// an asset in the ±90s pad overlap of two adjacent sessions is tagged into one, not both (R2/R4).
    /// Fetches ONLY the identifier column (`propertiesToFetch`): the live-session discovery loop calls
    /// this every 20 s on the MainActor, and materializing full rows made the tick pay for the whole
    /// media library's attributes. Still O(rows) per call — if a profile ever shows this tick, the
    /// next step is maintaining the id-set incrementally at the call site (prompt 114).
    static func allIdentifiers(in context: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<SessionMedia>()
        descriptor.propertiesToFetch = [\.localIdentifier]
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.localIdentifier))
    }
}

/// Provenance of a `SessionMedia`'s set assignment. `auto` rows are (re)placed by
/// `SessionMediaAssignment`; `manual` (user moved it to a set) and `general` (user pinned it to
/// the General bucket) are **sticky** — the auto-assigner never overrides them.
enum MediaAssignmentSource: String, Codable, Sendable, CaseIterable {
    case auto, manual, general
}
