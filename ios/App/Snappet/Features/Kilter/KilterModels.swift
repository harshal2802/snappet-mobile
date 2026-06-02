import Foundation
import SwiftData

// MARK: - Catalog value types (read-only, from the bundled kilter.sqlite3)

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

    init(climbUUID: String, climbName: String, angle: Int, difficulty: Double, gradeLabel: String,
         status: KilterAscentStatus, attempts: Int = 1, date: Date = .now, sessionId: UUID? = nil) {
        self.climbUUID = climbUUID
        self.climbName = climbName
        self.angle = angle
        self.difficulty = difficulty
        self.gradeLabel = gradeLabel
        self.statusRaw = status.rawValue
        self.attempts = attempts
        self.date = date
        self.sessionId = sessionId
    }

    var status: KilterAscentStatus { KilterAscentStatus(rawValue: statusRaw) ?? .attempt }
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

    init(id: UUID = UUID(), startedAt: Date = .now, endedAt: Date? = nil, angle: Int, source: String) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.angle = angle
        self.source = source
    }
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
