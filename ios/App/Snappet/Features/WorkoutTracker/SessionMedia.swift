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
    /// `true` when added via the PHPicker rather than auto-discovered.
    var addedManually: Bool
    var createdAt: Date

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

    init(id: UUID = UUID(), sessionID: UUID, localIdentifier: String,
         kind: Kind, offsetSec: Double, durationSec: Double? = nil,
         addedManually: Bool = false,
         assignedExerciseID: UUID? = nil, assignedSetIndex: Int? = nil,
         source: MediaAssignmentSource = .auto, createdAt: Date = .now) {
        self.id = id
        self.sessionID = sessionID
        self.localIdentifier = localIdentifier
        self.kindRaw = kind.rawValue
        self.offsetSec = max(0, offsetSec)
        self.durationSec = durationSec
        self.addedManually = addedManually
        self.assignedExerciseID = assignedExerciseID
        self.assignedSetIndex = assignedSetIndex
        self.assignmentSourceRaw = source.rawValue
        self.createdAt = createdAt
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .photo }

    /// Typed view over `assignmentSourceRaw` (defaults to `.auto` for any unknown raw).
    var assignmentSource: MediaAssignmentSource {
        get { MediaAssignmentSource(rawValue: assignmentSourceRaw) ?? .auto }
        set { assignmentSourceRaw = newValue.rawValue }
    }

    /// `true` when the clip is not tied to a specific set (the General bucket): either explicitly
    /// pinned `general`, or simply has no `assignedExerciseID`.
    var isGeneral: Bool { assignmentSource == .general || assignedExerciseID == nil }
}

/// Provenance of a `SessionMedia`'s set assignment. `auto` rows are (re)placed by
/// `SessionMediaAssignment`; `manual` (user moved it to a set) and `general` (user pinned it to
/// the General bucket) are **sticky** — the auto-assigner never overrides them.
enum MediaAssignmentSource: String, Codable, Sendable, CaseIterable {
    case auto, manual, general
}
