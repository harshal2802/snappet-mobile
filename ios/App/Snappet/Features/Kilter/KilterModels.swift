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
    /// Frame bounds (board units) — the climb's hold bounding box. Used to test whether the climb fits a
    /// board size (`edge_*` ⊆ the size's box, see `KilterBoardSize.box`).
    let edgeLeft, edgeRight, edgeBottom, edgeTop: Int
    /// Raw `pNrM…` hold encoding (decoded into `KilterHold`s by the catalog).
    let frames: String
    /// The setter's free-text note (carries the "No matching" convention; see `isNoMatch`).
    let description: String
    /// Whether the setter forbids **matching hands** on a hold for this climb — the Kilter "No matching"
    /// rule (`climbs.is_nomatch`; matching is allowed by default). Surfaced as a tag on the climb screen.
    let isNoMatch: Bool
    var id: String { uuid }
}

/// Detect the Kilter **"No matching"** setter note in a climb's free-text description — the fallback for
/// catalogs that predate the dedicated `climbs.is_nomatch` column (the reader prefers the column when it
/// exists). Setters write "no matching" / "no match" to forbid matching hands on a hold; the default
/// (no such note) is matching-allowed. Pure → unit-tested; mirrored in the Android `KilterCatalog`.
func kilterDescriptionForbidsMatching(_ description: String) -> Bool {
    // Match the setter note at a WORD BOUNDARY so it can't fire inside ordinary words ("piano matched",
    // "casino match", "no matches found"). Accepts "no matching" / "no match" / "no-match" / "nomatch";
    // rejects a trailing-letter form like "no matches" and any in-word substring.
    let d = description.lowercased()
    return d.range(of: #"(^|[^a-z])no[ -]?match(ing)?([^a-z]|$)"#, options: .regularExpression) != nil
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
    /// Hex RGB (no `#`), e.g. `00DD00` (start), from `placement_roles.screen_color` — for the on-screen
    /// render.
    let colorHex: String
    /// Hex RGB the **physical board** should light, from `placement_roles.led_color` (can differ from
    /// `colorHex`, e.g. start is `00FF00` on the LED vs `00DD00` on screen). Used for BLE illumination.
    let ledColorHex: String
    let role: String
    /// LED index on the physical board (for BLE illumination); nil if no LED maps to this hole.
    let ledPosition: Int?
    var id: Int { placementId }
}

/// The geometric marker a lit hold is drawn with, keyed by its role. A redundant (shape-as-well-as-color)
/// channel so the route reads for color-blind climbers, who can't separate the start/finish/foot hues —
/// the four roles map to four shapes that stay distinct in grayscale (the canonical
/// circle/triangle/square/diamond plotting set). Pure (no SwiftUI), so the mapping is unit-tested; the
/// board views (`KilterBoardView` / Android `KilterBoard`) build the actual path from this.
enum KilterHoldShape: String, CaseIterable, Sendable {
    case circle, triangle, square, diamond

    /// start → triangle, finish → square, foot → diamond; hand/"middle" and any unknown role → circle
    /// (the most common, neutral marker). Matches `KilterCatalog.roleName` and the Android mirror.
    static func forRole(_ role: String) -> KilterHoldShape {
        switch role {
        case "start": return .triangle
        case "finish": return .square
        case "foot": return .diamond
        default: return .circle   // "middle"/hand + unknown
        }
    }
}

/// A selectable board layout (e.g. Kilter Original, Homewall).
struct KilterLayout: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// A board size's bounding box in hole-coordinate units (`product_sizes.edge_*`). A climb fits the size
/// when its own `edge_*` box is contained within this one — the rule the Board Explorer's size filter
/// uses (`c.edge_left >= left AND c.edge_right <= right AND c.edge_bottom >= bottom AND c.edge_top <= top`).
struct KilterSizeBox: Hashable, Sendable {
    let left, right, bottom, top: Int
    /// `[left, right, bottom, top]` — the bind order for the download filter's fit condition.
    var params: [Int] { [left, right, bottom, top] }
}

/// A physical board size for a layout (a `product_size`), e.g. "8 x 12 — Home". The user picks theirs
/// so the LED mapping matches their board — each size addresses its LEDs differently, so the wrong
/// size lights the wrong holds.
struct KilterBoardSize: Identifiable, Hashable, Sendable {
    let id: Int        // product_size_id
    let name: String   // e.g. "8 x 12"
    let detail: String // e.g. "Home" / "Mainline LED Kit" (may be empty)
    /// The size's fit box from `product_sizes.edge_*` (hole units); `nil` when the catalog predates the
    /// edge columns. Drives the "only climbs that fit this size" download filter.
    let box: KilterSizeBox?
    /// Picker label: "8 x 12 — Home" (or just the name when there's no detail).
    var label: String { detail.isEmpty ? name : "\(name) — \(detail)" }
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

/// A tappable hole on the **authoring** board: a placement the user can assign a role to, normalized to
/// the same view space (x,y in 0…1, y from the top) as `KilterHold` so the editor's targets line up with
/// the faint grid and any lit holds. Deduped to one placement per hole for a layout/size.
struct KilterPlaceableHold: Identifiable, Hashable, Sendable {
    let placementId: Int
    let holeId: Int
    let x: Double
    let y: Double
    var id: Int { placementId }
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

/// Pure decision behind the first-send-of-a-grade celebration (issue #80): celebrate a
/// send when no earlier entry at that grade label was already a send. Kept off the view
/// so the truth table runs in `SnappetTests`; the caller supplies the prior-send count
/// (a one-off `fetchCount`).
enum KilterMilestones {
    static func isFirstSend(status: KilterAscentStatus, priorSendCountAtGrade: Int) -> Bool {
        status.isSend && priorSendCountAtGrade == 0
    }
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
    /// summary's source label + the BLE-only calorie gate; `nil` when no HR was captured.
    var metricsSourceRaw: String?
    /// HR-based calorie estimate (Keytel) for **BLE** sessions with a complete `UserHRProfile` —
    /// fills the band's hardcoded `energy = 0`; `nil` for watch sessions or an incomplete profile
    /// (Phase 2). Additive Optional → lightweight migration, like the other live-metrics fields.
    var kcalEstimate: Double?

    // MARK: - P4 history metadata (additive → SwiftData lightweight migration; existing sessions
    // decode with nil and fall back to the date-derived title / no notes / unknown layout).
    /// A user-given name for the session (e.g. "Comp prep", "Easy flash day"), editable from the
    /// session detail. `nil` → History/detail fall back to the date label. Additive Optional.
    var title: String?
    /// A free-form note about the whole session (how it felt, conditions, goals), editable from the
    /// session detail. `nil` for existing rows / sessions with no note. Additive Optional.
    var notes: String?
    /// The board layout this session ran on (`KilterLayout.id`), so History can facet by board/layout.
    /// `nil` for sessions captured before this field existed (and ad-hoc ones where it wasn't recorded).
    var layoutId: Int?

    init(id: UUID = UUID(), startedAt: Date = .now, endedAt: Date? = nil, angle: Int, source: String,
         hrSeries: [HRPoint] = [], maxHR: Double? = nil, restHR: Double? = nil,
         metricsSourceRaw: String? = nil, kcalEstimate: Double? = nil,
         title: String? = nil, notes: String? = nil, layoutId: Int? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.angle = angle
        self.source = source
        self.hrSeries = hrSeries
        self.maxHR = maxHR
        self.restHR = restHR
        self.metricsSourceRaw = metricsSourceRaw
        self.kcalEstimate = kcalEstimate
        self.title = title
        self.notes = notes
        self.layoutId = layoutId
    }

    /// Session length: `endedAt − startedAt`, or elapsed-so-far while still active.
    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
    var isActive: Bool { endedAt == nil }
}

/// A **persisted planned session**: a `KilterRecommender` plan snapshotted on Start, with per-pick
/// completion that survives any recommender re-run. Decoupling the plan from the live recommender is
/// what fixes the "completed send/project pick vanishes" defect and gives the run a re-enterable home.
/// `sessionId` pins it to its `KilterSession` once started (and freezes it); done-state is read from
/// each `KilterPlanItem.status`, never re-derived. Items are an embedded Codable array (the same shape
/// as `KilterSession.hrSeries`), so there's one new `@Model` and a trivial lightweight migration. The
/// integrator appends `KilterPlan.self` to `SnappetSchema.models`; pure logic lives in
/// `KilterPlanLogic.swift` (`KilterPlanProgress`), unit-tested without a device.
@Model
final class KilterPlan {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var angle: Int
    var layoutId: Int
    /// The detected working-grade float difficulty the plan was built around; `nil` on a cold start.
    var workingDifficulty: Double?
    var workingGradeLabel: String?
    /// Optional user/auto title (e.g. the strategy name) for History; `nil` falls back to a date label.
    var title: String?
    /// `KilterSession.id` once the plan is **Started** — pins the plan to its run and marks it frozen
    /// (the recommender no longer rebuilds it). `nil` while still in **Plan ready**.
    var sessionId: UUID?
    /// Set by **Finish plan**; `nil` while in progress (or left `nil` when a session is abandoned).
    var completedAt: Date?

    // MARK: - Options snapshot (the strategy the plan was generated with; mirrors KilterRecommender.Options)
    var optionsTargetCount: Int
    var optionsSendThreshold: Int
    var optionsPreferUnsent: Bool
    /// The grade offset applied to the anchor when this plan was generated (the config sheet's
    /// "Target grade" stepper). Snapshotted so History/diagnostics faithfully describe how the plan was
    /// built even when the climber hand-tuned the offset away from the strategy's seed. Additive with a
    /// default → lightweight migration.
    var optionsGradeOffset: Int = 0
    /// The named selection strategy chosen (e.g. "volume", "project"), when one was; `nil` = defaults.
    var strategyRaw: String?

    /// Ordered picks with per-item status — the durable replacement for the recommender's volatile
    /// `[Pick]`. Embedded Codable value array → lightweight migration, like `KilterSession.hrSeries`.
    var items: [KilterPlanItem]

    init(id: UUID = UUID(), createdAt: Date = .now, angle: Int, layoutId: Int,
         workingDifficulty: Double? = nil, workingGradeLabel: String? = nil, title: String? = nil,
         sessionId: UUID? = nil, completedAt: Date? = nil,
         optionsTargetCount: Int = 6, optionsSendThreshold: Int = 2, optionsPreferUnsent: Bool = true,
         optionsGradeOffset: Int = 0, strategyRaw: String? = nil, items: [KilterPlanItem] = []) {
        self.id = id
        self.createdAt = createdAt
        self.angle = angle
        self.layoutId = layoutId
        self.workingDifficulty = workingDifficulty
        self.workingGradeLabel = workingGradeLabel
        self.title = title
        self.sessionId = sessionId
        self.completedAt = completedAt
        self.optionsTargetCount = optionsTargetCount
        self.optionsSendThreshold = optionsSendThreshold
        self.optionsPreferUnsent = optionsPreferUnsent
        self.optionsGradeOffset = optionsGradeOffset
        self.strategyRaw = strategyRaw
        self.items = items
    }

    /// `true` once Started (pinned to a session) — the recommender must not rebuild it.
    var isStarted: Bool { sessionId != nil }
    var isCompleted: Bool { completedAt != nil }
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
