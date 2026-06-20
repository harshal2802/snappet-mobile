import Foundation

/// The single source of truth for the climb-uuid join/dedup key: trimmed + lowercased, so a created
/// climb's casing or stray whitespace can never split the same climb across rows. Every uuid-keyed Kilter
/// join (`KilterOnTheBoard`, `KilterCreatedGallery`) normalizes through HERE, so the key can't drift
/// between features (F6 — these two used to carry byte-for-byte duplicate normalizers).
enum KilterClimbID {
    static func normalize(_ uuid: String) -> String {
        uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Pure, device-free logic behind **On the Board** (Kilter Improvement P5) — the history of every climb
/// the user *lit on the board*, including the ones pulled up and worked but never formally logged as an
/// ascent. Foundation only (NO SwiftUI / SwiftData / UIKit), so the dedup, the day/session grouping +
/// roll-ups, the status join, and the recent-rail ordering all run in `SnappetTests` without a simulator.
/// Views build `[KilterLitEventValue]` + `[KilterClimbLog]` from their `@Query` rows and read the result.
///
/// **Kilter-board data only.** Deterministic for a given input + clock.
enum KilterOnTheBoard {

    // MARK: - Input value type (a plain mirror of the @Model)

    /// One lit-on-the-board event, reduced to what On the Board needs (a value mirror of `KilterLitEvent`),
    /// so the pure logic never touches the SwiftData @Model. Views build these with `from(_:)`; tests
    /// synthesize them directly. `id` is a stable composite of the dedup key + the light time, so a row's
    /// SwiftUI identity survives a re-query without needing a UUID column on the @Model.
    struct LitEvent: Sendable, Equatable, Identifiable {
        var climbUUID: String
        var climbName: String
        var gradeLabel: String
        var angle: Int
        var layoutId: Int
        var sizeId: Int
        var litAt: Date
        var wasConnected: Bool
        var sessionId: UUID?

        /// Stable composite identity: normalized climb + session + light instant. Unique within the
        /// deduped set (one row per climb-per-session), and identical across re-queries of the same data.
        var id: String {
            "\(KilterOnTheBoard.normalizedUUID(climbUUID))|\(sessionId?.uuidString ?? "none")|\(litAt.timeIntervalSinceReferenceDate)"
        }
    }

    // MARK: - Joined status

    /// The status a lit climb resolves to once joined with the ascent log. The label the row's chip shows.
    enum Status: String, Sendable, Equatable {
        /// Lit but never logged (or only ever marked a project — still "in progress on the wall").
        case lit
        /// Tried (one or more `.attempt` logs) but not sent.
        case attempt
        /// Sent or flashed.
        case sent

        var label: String {
            switch self {
            case .lit: return "Lit"
            case .attempt: return "Attempt"
            case .sent: return "Sent"
            }
        }
    }

    // MARK: - Display model

    /// One row in the timeline: a deduped lit event with its joined status. Carries the climb's display
    /// facts (snapshotted on the event) so the view renders a thumbnail + grade/angle/time with no catalog
    /// re-fetch.
    struct Row: Sendable, Equatable, Identifiable {
        var id: String { event.id }
        var event: LitEvent
        var status: Status
    }

    /// A day/session group: a headline (day + the dominant angle or board), a roll-up summary
    /// ("9 lit · 3 sent"), and its rows newest-first. `id` is the group key.
    struct Group: Sendable, Equatable, Identifiable {
        var id: String
        var headline: String
        var summary: String
        var rows: [Row]
    }

    /// A selectable timeline filter (status / angle / board). The chip's raw vocabulary.
    enum Facet: String, CaseIterable, Sendable {
        case status, angle, board
        var label: String {
            switch self {
            case .status: return "Status"
            case .angle: return "Angle"
            case .board: return "Board"
            }
        }
    }

    /// The whole grouped, filtered timeline the view renders, plus the hero count and the chip rail.
    struct DisplayModel: Sendable, Equatable {
        var groups: [Group]
        /// Distinct climbs (by normalized uuid) worked over the deduped set — the hero "N climbs worked".
        var climbsWorked: Int
        /// Distinct selectable values per facet, in render order (the chip rail's content). Built from the
        /// FULL deduped set so a chip never vanishes just because the current filter hid its rows.
        var facetValues: [Facet: [String]]
    }

    // MARK: - Dedup

    /// Collapse the raw lit events to ONE per `(normalized climbUUID, sessionId)` — the same key capture
    /// upserts on, applied again here so a backup-restored or hand-duplicated set still reads cleanly. The
    /// surviving row is the one with the newest `litAt` (ties broken by `id` for determinism). A `nil`
    /// session is its own bucket per climb (an out-of-session light isn't merged across visits).
    static func deduped(_ events: [LitEvent]) -> [LitEvent] {
        struct Key: Hashable { var climb: String; var session: UUID? }
        var best: [Key: LitEvent] = [:]
        for e in events {
            let key = Key(climb: normalizedUUID(e.climbUUID), session: e.sessionId)
            if let existing = best[key] {
                if e.litAt > existing.litAt || (e.litAt == existing.litAt && tieBreakPrefers(e, over: existing)) {
                    best[key] = e
                }
            } else {
                best[key] = e
            }
        }
        return Array(best.values)
    }

    /// Deterministic tie-break for two rows in the SAME climb+session bucket that share an identical
    /// `litAt` (F7): the value-derived `id` collides in that case — same normalized climb, same session,
    /// same instant — so falling back to it just preserved input/dictionary order. Prefer the row that
    /// `wasConnected` (a real on-the-wall light beats an intent-only tap), then the higher angle, then the
    /// raw climbUUID, then `sizeId` — a total, input-order-independent order so the surviving row (and the
    /// `recent`/`group` sort below) is stable across re-queries and round-trips.
    static func tieBreakPrefers(_ a: LitEvent, over b: LitEvent) -> Bool {
        if a.wasConnected != b.wasConnected { return a.wasConnected }   // connected wins
        if a.angle != b.angle { return a.angle > b.angle }              // steeper wins
        if a.climbUUID != b.climbUUID { return a.climbUUID < b.climbUUID }
        return a.sizeId < b.sizeId
    }

    // MARK: - Status join

    /// Resolve a lit climb's status from the ascent log: a send/flash anywhere on that climb → `.sent`;
    /// else any `.attempt` → `.attempt`; else `.lit` (lit-only, or only ever a project). Joined by the
    /// **normalized** climb uuid so a created climb's uuid casing/whitespace can't split the join.
    static func status(forClimb uuid: String, logs: [KilterClimbLog]) -> Status {
        let key = normalizedUUID(uuid)
        let matching = logs.filter { normalizedUUID($0.climbUUID) == key }
        if matching.contains(where: \.isSend) { return .sent }
        if matching.contains(where: { $0.status == .attempt }) { return .attempt }
        return .lit
    }

    // MARK: - Build

    /// Build the grouped display model from the lit events + the ascent log, a filter selection, and a
    /// clock. `layoutName` resolves a `layoutId` to a human board name for the group headline + the Board
    /// facet chips (the view passes the catalog lookup; tests pass a stub).
    static func build(events: [LitEvent],
                      logs: [KilterClimbLog],
                      selections: [Facet: String] = [:],
                      now: Date = .now,
                      calendar: Calendar = .current,
                      layoutName: (Int) -> String? = { _ in nil }) -> DisplayModel {

        let deduped = deduped(events)
        let allRows = deduped.map { Row(event: $0, status: status(forClimb: $0.climbUUID, logs: logs)) }

        // Facet values from the FULL deduped set (pre-filter) so toggling a chip can't make others vanish.
        let facetValues = facetValues(rows: allRows, layoutName: layoutName)

        let filtered = allRows.filter { matches($0, selections: selections, layoutName: layoutName) }
        let groups = group(filtered, now: now, calendar: calendar, layoutName: layoutName)

        // Hero count is over the FULL deduped set (the climber's whole body of work), not the filtered view.
        let climbsWorked = Set(deduped.map { normalizedUUID($0.climbUUID) }).count

        return DisplayModel(groups: groups, climbsWorked: climbsWorked, facetValues: facetValues)
    }

    /// Whether a row passes every active facet (AND-combined).
    static func matches(_ row: Row, selections: [Facet: String], layoutName: (Int) -> String?) -> Bool {
        for (facet, value) in selections {
            switch facet {
            case .status: if statusToken(row.status) != value { return false }
            case .angle:  if angleToken(row.event.angle) != value { return false }
            case .board:  if boardToken(row.event, layoutName: layoutName) != value { return false }
            }
        }
        return true
    }

    /// Distinct selectable values per facet, each in a stable render order. Over the FULL deduped set so
    /// the chip rail is constant regardless of the current filter.
    static func facetValues(rows: [Row], layoutName: (Int) -> String?) -> [Facet: [String]] {
        var out: [Facet: [String]] = [:]

        // Status: canonical Lit → Attempt → Sent order, only those present.
        let presentStatuses = Set(rows.map(\.status))
        out[.status] = [Status.lit, .attempt, .sent].filter(presentStatuses.contains).map(statusToken)

        // Angle: ascending.
        out[.angle] = Set(rows.map(\.event.angle)).sorted().map(angleToken)

        // Board: distinct layout tokens, by first appearance among newest-first rows.
        var seen = Set<String>()
        out[.board] = rows.sorted { $0.event.litAt > $1.event.litAt }
            .compactMap { r -> String? in
                let token = boardToken(r.event, layoutName: layoutName)
                return seen.insert(token).inserted ? token : nil
            }

        return out.filter { !$0.value.isEmpty }
    }

    // MARK: - Grouping + roll-ups

    /// Bucket the (already deduped + filtered) rows by day **and session** — a day can hold more than one
    /// session, and each session gets its own group so the wireframe's "Today · 40°" / "Yesterday ·
    /// BetaBoulders Gym" headers read right. Newest group first; rows within a group newest-first.
    ///
    /// The group key is `day | sessionId` (a `nil`-session bucket per day collects out-of-session lights).
    /// The headline pairs the relative-day label with the group's dominant board name (when one layout
    /// dominates) else its dominant angle. The summary is the "N lit · M sent" roll-up.
    static func group(_ rows: [Row], now: Date, calendar: Calendar,
                      layoutName: (Int) -> String?) -> [Group] {
        guard !rows.isEmpty else { return [] }

        struct Key: Hashable { var day: Date; var session: UUID? }
        let keyed = Dictionary(grouping: rows) { r in
            Key(day: calendar.startOfDay(for: r.event.litAt), session: r.event.sessionId)
        }

        // Sort groups by each group's newest light, newest first; ties broken by the string key.
        return keyed.map { key, groupRows -> (Date, String, Group) in
            let sortedRows = groupRows.sorted { rowOrdersBefore($0, $1) }
            let newest = sortedRows.first!.event.litAt
            let id = "\(key.day.timeIntervalSinceReferenceDate)|\(key.session?.uuidString ?? "none")"
            let g = Group(id: id,
                          headline: headline(for: sortedRows, day: key.day, now: now,
                                             calendar: calendar, layoutName: layoutName),
                          summary: summary(for: sortedRows),
                          rows: sortedRows)
            return (newest, id, g)
        }
        .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
        .map(\.2)
    }

    /// "Today · 40°" / "Yesterday · BetaBoulders Gym" / "Jun 12 · 45°". Pairs the relative-day label with
    /// the group's dominant board name when one layout dominates (and resolves to a name), else its
    /// dominant angle.
    static func headline(for rows: [Row], day: Date, now: Date, calendar: Calendar,
                         layoutName: (Int) -> String?) -> String {
        let dayLabel = relativeDayLabel(day, now: now, calendar: calendar)
        // Dominant board name (most-frequent layout that resolves to a real name).
        let boardCounts = rows.reduce(into: [Int: Int]()) { $0[$1.event.layoutId, default: 0] += 1 }
        if let topLayout = boardCounts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key,
           let name = layoutName(topLayout), !name.isEmpty {
            return "\(dayLabel) · \(name)"
        }
        // Else dominant angle.
        let angleCounts = rows.reduce(into: [Int: Int]()) { $0[$1.event.angle, default: 0] += 1 }
        if let topAngle = angleCounts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key {
            return "\(dayLabel) · \(topAngle)°"
        }
        return dayLabel
    }

    /// "9 lit · 3 sent" — the lit count is the group's total rows; sent is how many resolved to `.sent`.
    /// (A row's status is the climb's overall status, so "lit" here means "climbs worked", matching the
    /// wireframe's "N lit · M sent" header.)
    static func summary(for rows: [Row]) -> String {
        let sent = rows.filter { $0.status == .sent }.count
        return "\(rows.count) lit · \(sent) sent"
    }

    // MARK: - Recent rail

    /// The most-recent lit climbs for the Kilter-root "Recently on the board" rail — deduped (one per
    /// climb-per-session), newest light first, capped at `limit`. Ties on `litAt` broken by `id` so the
    /// rail order is deterministic.
    static func recent(_ events: [LitEvent], logs: [KilterClimbLog] = [], limit: Int = 8) -> [Row] {
        deduped(events)
            .sorted { litEventOrdersBefore($0, $1) }
            .prefix(max(0, limit))
            .map { Row(event: $0, status: status(forClimb: $0.climbUUID, logs: logs)) }
    }

    /// Newest-light-first ordering for two **distinct** deduped rows, with a deterministic tie-break (F7):
    /// newer `litAt` first; on an identical instant, the `tieBreakPrefers` row first, then the value `id`
    /// as the final stable fallback — a total order regardless of input/dictionary order.
    static func litEventOrdersBefore(_ a: LitEvent, _ b: LitEvent) -> Bool {
        if a.litAt != b.litAt { return a.litAt > b.litAt }
        if tieBreakPrefers(a, over: b) { return true }
        if tieBreakPrefers(b, over: a) { return false }
        return a.id < b.id
    }

    /// The `Row` form of `litEventOrdersBefore` (groups sort `Row`s).
    static func rowOrdersBefore(_ a: Row, _ b: Row) -> Bool { litEventOrdersBefore(a.event, b.event) }

    // MARK: - Token + label helpers

    static func statusToken(_ status: Status) -> String { status.label }
    static func angleToken(_ angle: Int) -> String { "\(angle)°" }
    static func boardToken(_ event: LitEvent, layoutName: (Int) -> String?) -> String {
        layoutName(event.layoutId) ?? "Layout \(event.layoutId)"
    }

    /// Lowercased, whitespace-trimmed climb uuid — the join/dedup key, so a created climb's casing or
    /// stray whitespace can't split the same climb across rows. Delegates to the shared `KilterClimbID`
    /// so this feature's key can't drift from `KilterCreatedGallery`'s (F6).
    static func normalizedUUID(_ uuid: String) -> String { KilterClimbID.normalize(uuid) }

    /// "Today" / "Yesterday" / "Jun 12" relative to `now`.
    static func relativeDayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.month().day())
    }
}

extension KilterOnTheBoard.LitEvent {
    /// Map a SwiftData `KilterLitEvent` to the value-mirror used by `KilterOnTheBoard` (so the pure model
    /// never touches the @Model). Identity is the value's own composite `id` (climb + session + litAt) —
    /// no UUID column on the @Model is needed.
    static func from(_ m: KilterLitEvent) -> KilterOnTheBoard.LitEvent {
        KilterOnTheBoard.LitEvent(
            climbUUID: m.climbUUID, climbName: m.climbName, gradeLabel: m.gradeLabel,
            angle: m.angle, layoutId: m.layoutId, sizeId: m.sizeId, litAt: m.litAt,
            wasConnected: m.wasConnected, sessionId: m.sessionId)
    }
}
