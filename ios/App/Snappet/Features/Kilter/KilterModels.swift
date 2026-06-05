import Foundation
import SwiftData

// MARK: - Catalog value types (read-only, from the user-installed kilter.sqlite3 catalog)

/// A climb as shown in the catalog list, already resolved for one angle.
struct KilterListItem: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    let setter: String
    /// Per-angle community difficulty (float; map to a grade label with `KilterCatalog.gradeLabel`).
    let difficulty: Double
    let gradeLabel: String
    /// 1–3 quality average.
    let quality: Double
    let ascents: Int
    var id: String { uuid }
}

/// A full climb record (drives the detail screen + board render).
struct KilterClimb: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    let setter: String
    let layoutId: Int
    /// Frame bounds (board units) used to normalize hold coordinates into the view.
    let edgeLeft, edgeRight, edgeBottom, edgeTop: Int
    /// Raw `pNrM…` hold encoding (decoded into `KilterHold`s by the catalog).
    let frames: String
    var id: String { uuid }
}

/// Per-angle stats for a climb.
struct KilterClimbStat: Identifiable, Hashable, Sendable {
    let angle: Int
    let difficulty: Double
    let benchmarkDifficulty: Double?
    let ascents: Int
    let quality: Double
    let faUsername: String
    var id: Int { angle }
}

/// One lit hold, already normalized to view space (x,y in 0…1, y measured from the top).
struct KilterHold: Identifiable, Hashable, Sendable {
    let placementId: Int
    let x: Double
    let y: Double
    /// Hex RGB (no `#`), e.g. `00DD00` (start), from `placement_roles.screen_color`.
    let colorHex: String
    let role: String
    /// LED index on the physical board (for BLE illumination); nil if no LED maps to this hole.
    let ledPosition: Int?
    var id: Int { placementId }
}

/// A selectable board layout (e.g. Kilter Original, Homewall).
struct KilterLayout: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// One hole position on the board, normalized to view space (x,y in 0…1, y from the top). The full
/// set draws the faint board grid under a climb's lit holds, giving the render real wall context.
struct KilterGridHole: Hashable, Sendable {
    let x: Double
    let y: Double
}

/// The drawable geometry of a board layout: its aspect ratio (width/height of the hole extent) and
/// the full normalized hole grid. Lit holds (`KilterHold`) are normalized to the *same* extent so
/// they line up exactly with the grid.
struct KilterBoardGeometry: Sendable {
    let aspect: Double
    let grid: [KilterGridHole]
    static let empty = KilterBoardGeometry(aspect: 1, grid: [])
}

/// The full set of catalog browse criteria (search + filters + sort). Drives `KilterCatalog.list`.
struct KilterFilter: Equatable, Sendable {
    var layoutId: Int
    var angle: Int
    var minDifficulty: Double
    var maxDifficulty: Double
    var search: String = ""
    var sort: KilterSort = .popular
    var benchmarksOnly: Bool = false
    var minAscents: Int = 0
    var minQuality: Double = 0

    /// Count of the optional (beyond layout/angle/grade) filters that are active — for a badge.
    var activeExtras: Int {
        (benchmarksOnly ? 1 : 0) + (minAscents > 0 ? 1 : 0) + (minQuality > 0 ? 1 : 0)
            + (sort != .popular ? 1 : 0)
    }
}

/// How grades render (the catalog ships combined "6a/V3" labels). A user preference.
enum KilterGradeFormat: String, CaseIterable, Sendable {
    case both, v, font
    var label: String {
        switch self {
        case .both: return "Font / V"
        case .v: return "V-scale"
        case .font: return "Font"
        }
    }
}

/// Reformat a combined `"6a/V3"` grade label per the user's preference (font part / V part / both).
func kilterDisplayGrade(_ label: String, _ format: KilterGradeFormat) -> String {
    let parts = label.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else { return label }
    switch format {
    case .both: return label
    case .font: return String(parts[0])
    case .v: return String(parts[1])
    }
}

/// How a climb's catalog list is ordered.
enum KilterSort: String, CaseIterable, Sendable {
    case popular, hardest, easiest, quality
    var label: String {
        switch self {
        case .popular: return "Most climbed"
        case .hardest: return "Hardest"
        case .easiest: return "Easiest"
        case .quality: return "Highest quality"
        }
    }
    /// The `ORDER BY` clause (over the joined `climb_stats cs`).
    var orderBy: String {
        switch self {
        case .popular: return "cs.ascensionist_count DESC"
        case .hardest: return "cs.display_difficulty DESC, cs.ascensionist_count DESC"
        case .easiest: return "cs.display_difficulty ASC, cs.ascensionist_count DESC"
        case .quality: return "cs.quality_average DESC, cs.ascensionist_count DESC"
        }
    }
}

// MARK: - User-data models (persisted in the shared SnappetCore store)

/// How a logged attempt resolved. Stored by `rawValue` on `KilterLogEntry`.
enum KilterAscentStatus: String, CaseIterable, Codable, Sendable {
    case flash, sent, project, attempt
    var label: String {
        switch self {
        case .flash: return "Flash"
        case .sent: return "Sent"
        case .project: return "Project"
        case .attempt: return "Attempt"
        }
    }
    /// Counts toward "sends" in the history pyramid.
    var isSend: Bool { self == .sent || self == .flash }
}

/// One logged attempt on a climb at a given angle. Persisted in SnappetCore (separate from the
/// read-only catalog). Snapshots `climbName`/`gradeLabel` so History renders without re-opening
/// the catalog. Optionally tagged with the `sessionId` of the board session it was logged in.
/// The integrator appends `KilterLogEntry.self` to `SnappetSchema.models`.
@Model
final class KilterLogEntry {
    var climbUUID: String
    var climbName: String
    var angle: Int
    /// Float difficulty at the logged angle (for the grade pyramid / sorting).
    var difficulty: Double
    var gradeLabel: String
    /// `KilterAscentStatus.rawValue`.
    var statusRaw: String
    var attempts: Int
    var date: Date
    /// `KilterSession.id` when captured during a connected board session; nil for ad-hoc logs.
    var sessionId: UUID?

    // MARK: - Per-climb timing (additive → lightweight migration; existing rows decode with nil
    // timestamps and an empty attempt list, so they render as an instantaneous log like before).
    /// When the climber first started working this climb in the session (stamped on the active
    /// climb). Time-on-climb is `endedAt − startedAt`; rest-between-climbs is derived across entries.
    var startedAt: Date?
    /// When this entry was logged (a send closes the climb). Mirrors `date` for in-session entries.
    var endedAt: Date?
    /// One timestamp per Attempt tap, so attempt cadence is reconstructable. `attempts` stays the
    /// count (populated from this when present).
    var attemptTimestamps: [Date] = []
    /// A free-form personal note for this ascent (beta, conditions, how it felt), editable from the
    /// session's Climb panel. Additive + optional → lightweight migration; `nil` for existing rows.
    var note: String?

    init(climbUUID: String, climbName: String, angle: Int, difficulty: Double, gradeLabel: String,
         status: KilterAscentStatus, attempts: Int = 1, date: Date = .now, sessionId: UUID? = nil,
         startedAt: Date? = nil, endedAt: Date? = nil, attemptTimestamps: [Date] = [],
         note: String? = nil) {
        self.climbUUID = climbUUID
        self.climbName = climbName
        self.angle = angle
        self.difficulty = difficulty
        self.gradeLabel = gradeLabel
        self.statusRaw = status.rawValue
        self.attempts = attempts
        self.date = date
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.attemptTimestamps = attemptTimestamps
        self.note = note
    }

    var status: KilterAscentStatus { KilterAscentStatus(rawValue: statusRaw) ?? .attempt }

    /// Time spent working this climb, when both ends are known.
    var timeOnClimb: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

/// A board session — opened when a board connects over BLE (or started manually), it groups the
/// `KilterLogEntry`s logged while it's active so History can show sessions. The integrator appends
/// `KilterSession.self` to `SnappetSchema.models`.
@Model
final class KilterSession {
    /// Stable id referenced by `KilterLogEntry.sessionId`.
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var angle: Int
    /// `"ble"` when auto-captured from a connected board, `"manual"` otherwise.
    var source: String

    // MARK: - Live metrics (additive → SwiftData lightweight migration; existing sessions
    // decode with an empty series + nil HR bounds, and the summary's HR section hides cleanly).
    /// The live heart-rate series captured during the session (flushed from the active
    /// `MetricsSource` buffer when the session ends), `t` seconds from `startedAt` — the same
    /// engine timeline + `HRPoint` composite the WorkoutTracker uses (reused, not redefined).
    /// Empty when there was no live HR source (no watch / band, or the simulator).
    var hrSeries: [HRPoint] = []
    /// User max HR for %-of-max zone math; `nil` → `HeartRateZone.defaultMaxHR` fallback.
    var maxHR: Double?
    /// Resting HR baseline, when known; reserved for %HRR refinement.
    var restHR: Double?
    /// `MetricsSourceKind.rawValue` of the transport that drove HR ("appleWatch"/"ble"), for the
    /// summary's source label; `nil` when no HR was captured.
    var metricsSourceRaw: String?

    init(id: UUID = UUID(), startedAt: Date = .now, endedAt: Date? = nil, angle: Int, source: String,
         hrSeries: [HRPoint] = [], maxHR: Double? = nil, restHR: Double? = nil,
         metricsSourceRaw: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.angle = angle
        self.source = source
        self.hrSeries = hrSeries
        self.maxHR = maxHR
        self.restHR = restHR
        self.metricsSourceRaw = metricsSourceRaw
    }

    /// Session length: `endedAt − startedAt`, or elapsed-so-far while still active.
    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
    var isActive: Bool { endedAt == nil }
}

/// A climb the user starred. Kept as its own tiny model (rather than a flag on the catalog, which is
/// read-only) so the "Saved" filter is a fast membership check. The integrator appends
/// `KilterFavorite.self` to `SnappetSchema.models`.
@Model
final class KilterFavorite {
    @Attribute(.unique) var climbUUID: String
    var addedAt: Date
    init(climbUUID: String, addedAt: Date = .now) {
        self.climbUUID = climbUUID
        self.addedAt = addedAt
    }
}
