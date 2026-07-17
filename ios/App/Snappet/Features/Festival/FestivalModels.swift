import Foundation
import SwiftData

// Festival persistence (festival prompt 02). Three flat tables, plain-UUID/string FKs like the
// rest of the suite (no SwiftData relationships), CloudKit-compatible by construction (inline
// defaults, no unique constraints — the Wardrobe precedent). Rows ride the suite-level
// `SnappetBackup` (added in the same change; the coverage tripwire test enforces it).

/// One installed festival lineup — the durable form of a downloaded/imported `.fpack`. The row
/// stores the ORIGINAL pack bytes (the wire form is the source of truth; prompt 05's share re-emits
/// it) plus denormalized display fields so list rows render without inflating anything. Keyed by the
/// pack-author `packID` slug: re-installing the same festival replaces the row, and stars/attendance
/// survive because set ids are content-derived (UUIDv5), not row-derived.
@Model
final class FestivalLineup {
    var id: UUID = UUID()
    /// `FestivalPack.id` — the pack-author slug (e.g. `"glastonbury-2026"`), the FK stars and
    /// attendance rows hang off.
    var packID: String = ""
    var name: String = ""
    var location: String = ""
    /// Poster dates (`yyyy-MM-dd`, inclusive) — denormalized for the lineup list row.
    var startDate: String = ""
    var endDate: String = ""
    var utcOffsetSeconds: Int = 0
    var stageCount: Int = 0
    var setCount: Int = 0
    /// Where the pack came from ("Snappet Lineups" / "Imported file") — the Kilter `source` label.
    var sourceLabel: String = ""
    var installedAt: Date = Date()
    /// The verbatim `.fpack` bytes (magic + version + raw-DEFLATE JSON). A lineup is tens of KB, so
    /// the blob lives inline; decode on demand via `pack()`.
    var fpackData: Data = Data()

    init(id: UUID = UUID(), packID: String, name: String, location: String,
         startDate: String, endDate: String, utcOffsetSeconds: Int,
         stageCount: Int, setCount: Int, sourceLabel: String,
         installedAt: Date = .now, fpackData: Data) {
        self.id = id
        self.packID = packID
        self.name = name
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.utcOffsetSeconds = utcOffsetSeconds
        self.stageCount = stageCount
        self.setCount = setCount
        self.sourceLabel = sourceLabel
        self.installedAt = installedAt
        self.fpackData = fpackData
    }

    /// Inflate the stored pack (stamped content ids included — `decode` is the single entry point).
    /// `nil` only if the stored blob is damaged; the installer validated it before persisting.
    func pack() -> FestivalPack? {
        try? FestivalPack.decode(fpack: fpackData)
    }
}

/// One starred set (wireframe frame 4's ★ → "my plan"). A row per star — not an array on the
/// lineup — so prompt 04's reminder scheduling and the share QR read plain rows, and toggling a
/// star never rewrites the (large) lineup row. `setID` is the UUIDv5 content id, so stars survive
/// a pack re-install byte-for-byte.
@Model
final class FestivalStar {
    var id: UUID = UUID()
    var packID: String = ""
    var setID: UUID = UUID()
    var createdAt: Date = Date()

    init(id: UUID = UUID(), packID: String, setID: UUID, createdAt: Date = .now) {
        self.id = id
        self.packID = packID
        self.setID = setID
        self.createdAt = createdAt
    }
}

/// One "I'm here" stretch: the user said they were at `setID` from `startedAt` until `endedAt`
/// (nil while still on the floor). This is exactly the matcher's `FestivalSessionHint` evidence
/// (prompt 03 maps rows straight into hints), plus the FK to the dance `WorkoutSession` the stretch
/// rode — the session spine owns HR/media; this row only records *which set* the user claimed.
@Model
final class FestivalAttendance {
    var id: UUID = UUID()
    var packID: String = ""
    var setID: UUID = UUID()
    /// Denormalized so history reads without inflating the pack.
    var artist: String = ""
    var stage: String = ""
    /// The `WorkoutSession.id` this stretch was annotated onto.
    var sessionID: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date? = nil

    init(id: UUID = UUID(), packID: String, setID: UUID, artist: String, stage: String,
         sessionID: UUID, startedAt: Date = .now, endedAt: Date? = nil) {
        self.id = id
        self.packID = packID
        self.setID = setID
        self.artist = artist
        self.stage = stage
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    var isOpen: Bool { endedAt == nil }

    /// The matcher-shaped hint this stretch is (prompt 03 consumes these). An open stretch is
    /// clamped to `now`.
    func hint(now: Date = .now) -> FestivalSessionHint {
        FestivalSessionHint(setID: setID,
                            interval: DateInterval(start: startedAt,
                                                   end: max(startedAt, endedAt ?? now)))
    }
}
