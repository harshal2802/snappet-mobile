import Foundation

/// The **pure** query/sort/filter + own-status-join engine behind the "Your Climbs" gallery (P2). Kept
/// Foundation-only (no SwiftUI / SwiftData / catalog) so the whole "which of my climbs show, in what
/// order, with what status" decision runs in `SnappetTests` against hand-built rows — the same discipline
/// `KilterAllTimeStats` (P0) follows. The view feeds it lightweight value snapshots of its `@Query`
/// results and renders the ordered `Item`s; it owns nothing the device provides.
///
/// Unlike the old layout-scoped **Mine** filter (`KilterRootView.createdListItems`), this is **global
/// across layouts** — a climb you set on another board still appears here. Layout is a *facet* you can
/// filter by, never an implicit gate.
enum KilterCreatedGallery {

    // MARK: - Inputs

    /// A device-free snapshot of one `KilterCreatedClimb` (the only fields the gallery reasons about).
    /// The view builds these from its `@Query` rows so the engine never touches SwiftData.
    struct CreatedRow: Equatable, Sendable {
        var uuid: String
        var name: String
        /// The author's display name (`KilterCreatedClimb.setterUsername`). Searched alongside `name`,
        /// restoring the legacy Mine filter's name-OR-setter match.
        var setterUsername: String
        var layoutId: Int
        var angle: Int
        var predictedGrade: Double?
        /// `"manual"` or `"generated"` (the `source` column).
        var source: String
        /// `false` when `kilterValidate` failed for this climb's holds — a **Draft** (see `Status.draft`).
        /// Derived by the view from the holds (no schema field), defaulting valid for ungated callers.
        var isValid: Bool
        var createdAt: Date

        init(uuid: String, name: String, setterUsername: String = "", layoutId: Int, angle: Int,
             predictedGrade: Double?, source: String, isValid: Bool = true, createdAt: Date) {
            self.uuid = uuid
            self.name = name
            self.setterUsername = setterUsername
            self.layoutId = layoutId
            self.angle = angle
            self.predictedGrade = predictedGrade
            self.source = source
            self.isValid = isValid
            self.createdAt = createdAt
        }
    }

    /// A device-free snapshot of one `KilterLogEntry` the gallery needs to compute the user's OWN status.
    /// Only the climb id + ascent status matter here — never community signals (none exist on-device).
    struct LogRow: Equatable, Sendable {
        var climbUUID: String
        var status: KilterAscentStatus
    }

    // MARK: - Facets

    /// The Draft / Saved / All status segment over the gallery. **Saved** here means a *savable* climb —
    /// a complete, valid created climb (the opposite of a Draft), NOT the catalog "favorited" Saved filter.
    enum Segment: String, CaseIterable, Sendable {
        case all, saved, drafts
        var label: String {
            switch self {
            case .all:    return "All"
            case .saved:  return "Saved"
            case .drafts: return "Drafts"
            }
        }
    }

    /// How a created climb resolved against the user's OWN logbook — the per-card status chip. Derived
    /// purely from the user's `KilterLogEntry` rows; there are no community ascents on-device, by design.
    enum OwnStatus: String, Equatable, Sendable {
        case sent, project, attempt, untried
        var label: String {
            switch self {
            case .sent:    return "Sent"
            case .project: return "Project"
            case .attempt: return "Attempt"
            case .untried: return "Untried"
            }
        }
    }

    /// Provenance — how the climb came to be (the per-card glyph + label). Mirrors the `source` column.
    enum Provenance: String, Equatable, Sendable {
        case handSet, generated
        var label: String { self == .handSet ? "Hand-set" : "Generated" }
        var glyph: String { self == .handSet ? "hand.draw" : "sparkles" }
        init(source: String) { self = (source == "generated") ? .generated : .handSet }
    }

    /// Gallery sort order (the sort chip).
    enum Sort: String, CaseIterable, Sendable {
        /// Newest first (default) — by `createdAt`.
        case recent
        /// Hardest first — by predicted/chosen grade (ungraded sinks last).
        case grade
        /// Most climbed by you — by own SEND count (sent + flash), then recency. (Attempts don't rank.)
        case mostClimbed
        var label: String {
            switch self {
            case .recent:      return "Recently set"
            case .grade:       return "Grade"
            case .mostClimbed: return "Most climbed"
            }
        }
    }

    // MARK: - Output

    /// One display row the gallery renders — the joined created climb + its own-logbook status + counts.
    struct Item: Identifiable, Equatable, Sendable {
        var uuid: String
        var name: String
        var layoutId: Int
        var angle: Int
        var predictedGrade: Double?
        var provenance: Provenance
        var isDraft: Bool
        var ownStatus: OwnStatus
        /// How many times the user has logged this climb (any status) — drives the displayed count.
        var logCount: Int
        /// How many of those logs were SENDS (sent + flash) — the rank key for "Most climbed", so a
        /// never-sent climb with many attempts can't outrank a real send.
        var sendCount: Int
        var createdAt: Date
        var id: String { uuid }
    }

    // MARK: - Engine

    /// The DISTINCT angles present in the user's created climbs, ascending. The gallery is global across
    /// layouts, so the angle facet must come from the climbs themselves — not the installed catalog
    /// (`catalog.angles()`) — or a climb authored at an off-catalog angle would be unreachable and the
    /// menu could offer empty-result angles. Pure; the view feeds it the same `CreatedRow` snapshots.
    static func angleFacets(created: [CreatedRow]) -> [Int] {
        Array(Set(created.map(\.angle))).sorted()
    }

    /// Canonical key for the climb-uuid join: trimmed + lowercased, so the own-status/count join is
    /// case- and whitespace-insensitive on BOTH sides (a log uuid and a created-climb uuid that differ
    /// only in case/padding still match). Mirrors the lowercasing other uuid paths already do.
    static func normalizeUUID(_ uuid: String) -> String {
        uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Resolve the user's OWN status for one climb from its log rows (already filtered to this uuid).
    /// Explicit + future-proof precedence: any send/flash → **Sent**; else any `.project` → **Project**;
    /// else any `.attempt` → **Attempt**; else (nothing logged) → **Untried**. Listing the cases out (vs
    /// "non-empty && not-send ⇒ project") keeps a new `KilterAscentStatus` case from silently bucketing.
    /// Pure; mirrors the detail screen's logbook reading (never community data).
    static func ownStatus(forLogs logs: [LogRow]) -> OwnStatus {
        if logs.contains(where: { $0.status.isSend }) { return .sent }
        if logs.contains(where: { $0.status == .project }) { return .project }
        if logs.contains(where: { $0.status == .attempt }) { return .attempt }
        return .untried
    }

    /// The single source of truth for "which of my climbs show, in what order, with what status."
    ///
    /// - Parameters:
    ///   - created: every created climb (global, all layouts).
    ///   - logs: the user's log entries (joined by `climbUUID` for own-status + count).
    ///   - segment: Draft / Saved / All.
    ///   - sort: the sort order (default `.recent`).
    ///   - search: free-text filter over name OR setter (case-insensitive, trimmed; empty = no filter).
    ///   - layoutId: when non-nil, restrict to that layout (the optional board/layout facet — **off** by
    ///     default, which is the global view); `nil` = all layouts.
    ///   - angle: when non-nil, restrict to climbs designed at that angle; `nil` = any angle.
    ///   - source: when non-nil, restrict to `"manual"` / `"generated"`; `nil` = any source.
    /// - Returns: the ordered display items.
    static func items(created: [CreatedRow], logs: [LogRow],
                      segment: Segment = .all, sort: Sort = .recent,
                      search: String = "", layoutId: Int? = nil, angle: Int? = nil,
                      source: String? = nil) -> [Item] {
        // Index logs by climb once (O(logs)), so the join is O(created) lookups, not O(created·logs).
        // Normalize BOTH sides of the join (trim + lowercased) so a sent climb whose log uuid differs only
        // in case/whitespace still resolves — never silently shows Untried (other uuid paths lowercase too).
        var logsByClimb: [String: [LogRow]] = [:]
        for log in logs { logsByClimb[Self.normalizeUUID(log.climbUUID), default: []].append(log) }

        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = created.filter { row in
            if let layoutId, row.layoutId != layoutId { return false }
            if let angle, row.angle != angle { return false }
            if let source, row.source != source { return false }
            switch segment {
            case .all:    break
            case .saved:  if !row.isValid { return false }
            case .drafts: if row.isValid { return false }
            }
            // Search matches name OR setter (legacy Mine filter parity), case-insensitive + trimmed.
            if !term.isEmpty,
               !row.name.lowercased().contains(term),
               !row.setterUsername.lowercased().contains(term) { return false }
            return true
        }

        let items = filtered.map { row -> Item in
            let logs = logsByClimb[Self.normalizeUUID(row.uuid)] ?? []
            return Item(uuid: row.uuid, name: row.name, layoutId: row.layoutId, angle: row.angle,
                        predictedGrade: row.predictedGrade,
                        provenance: Provenance(source: row.source),
                        isDraft: !row.isValid,
                        ownStatus: ownStatus(forLogs: logs),
                        logCount: logs.count,
                        sendCount: logs.reduce(0) { $0 + ($1.status.isSend ? 1 : 0) },
                        createdAt: row.createdAt)
        }

        return sorted(items, by: sort)
    }

    /// Stable sort for the gallery. Ties always break to **newest-first** so the order is deterministic
    /// (two ungraded climbs, or two equally-climbed ones, fall back to recency).
    static func sorted(_ items: [Item], by sort: Sort) -> [Item] {
        switch sort {
        case .recent:
            return items.sorted { $0.createdAt > $1.createdAt }
        case .grade:
            // Hardest first; ungraded (`nil`) sinks below every graded climb, then recency.
            return items.sorted { a, b in
                switch (a.predictedGrade, b.predictedGrade) {
                case let (x?, y?) where x != y: return x > y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.createdAt > b.createdAt
                }
            }
        case .mostClimbed:
            // Rank by the user's SEND count (sent + flash), not every log row — a never-sent climb with
            // many attempts must NOT outrank a sent one. Deterministic tie-break: then newest-first.
            return items.sorted { $0.sendCount != $1.sendCount ? $0.sendCount > $1.sendCount
                                                               : $0.createdAt > $1.createdAt }
        }
    }
}
