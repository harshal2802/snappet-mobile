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

    init(id: UUID = UUID(), sessionID: UUID, localIdentifier: String,
         kind: Kind, offsetSec: Double, durationSec: Double? = nil,
         addedManually: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.sessionID = sessionID
        self.localIdentifier = localIdentifier
        self.kindRaw = kind.rawValue
        self.offsetSec = max(0, offsetSec)
        self.durationSec = durationSec
        self.addedManually = addedManually
        self.createdAt = createdAt
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .photo }
}
