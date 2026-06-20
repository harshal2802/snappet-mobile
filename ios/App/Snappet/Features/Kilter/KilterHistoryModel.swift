import Foundation

/// Pure, device-free logic behind the redesigned Kilter **session history** (Kilter Improvement P4):
/// bucketing sessions into month/week/all groups with roll-up headers, a scope switcher, faceted
/// filtering (board/layout · angle · grade · status · source) + text search with stale-filter recovery,
/// and the adaptive per-card fact selection (the Strava "one badge max" rule). Foundation only — NO
/// SwiftUI / SwiftData / UIKit — so the whole grouped display model is unit-tested in `SnappetTests`
/// without a simulator. Views build `[KilterHistoryItem]` from their `@Query` rows and read the result.
///
/// **Kilter-board data only** (no Quick-Session fold-in). Deterministic for a given input + clock.
enum KilterHistoryModel {

    // MARK: - Input value types (plain mirrors of the @Models)

    /// One board session, reduced to what history needs (a value mirror of `KilterSession`).
    struct SessionItem: Sendable, Equatable, Identifiable {
        var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var angle: Int
        /// `KilterSession.source` raw (`"ble"` / `"manual"` / `"auto"`).
        var source: String
        /// `KilterSession.layoutId` — `nil` for sessions captured before the field existed.
        var layoutId: Int?
        /// User title (`KilterSession.title`); `nil` falls back to the date label.
        var title: String?
        /// Whether the session captured a live HR series (drives the heart glyph). No HR payload here.
        var hasHR: Bool
        /// Still open (`endedAt == nil`) — the live pulse + always-visible recovery row.
        var isActive: Bool { endedAt == nil }
    }

    // MARK: - Scope

    /// The history scope switcher: which trailing window of sessions is shown, and how they're bucketed.
    enum Scope: String, CaseIterable, Sendable {
        case week, month, all
        var label: String {
            switch self {
            case .week: return "Week"
            case .month: return "Month"
            case .all: return "All"
            }
        }
    }

    // MARK: - Facets

    /// Which axis a filter chip narrows. Each maps to one value space; an active selection on a facet
    /// keeps only sessions matching it. (`board` doubles as layout — a session's `layoutId`.)
    enum Facet: String, CaseIterable, Sendable {
        case board, angle, grade, status, source
        var label: String {
            switch self {
            case .board: return "Board"
            case .angle: return "Angle"
            case .grade: return "Grade"
            case .status: return "Status"
            case .source: return "Source"
            }
        }
    }

    /// The full filter state: at most one selected value per facet (a raw string token), plus the search
    /// text. A `nil`/absent facet entry is "any". Selection tokens are the same raw strings the chips
    /// render, so the view never invents a parallel vocabulary.
    struct Filters: Sendable, Equatable {
        var selections: [Facet: String] = [:]
        var search: String = ""

        /// Whether any facet or the search box is narrowing — gates the "Clear filters" affordance.
        var isActive: Bool {
            !selections.isEmpty || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// Toggle a facet value: select it, or clear it if it was already the selection (chip re-tap).
        mutating func toggle(_ facet: Facet, _ value: String) {
            if selections[facet] == value { selections[facet] = nil } else { selections[facet] = value }
        }
    }

    // MARK: - Adaptive card facts

    /// One fact rendered on an adaptive session card. The view maps `kind` to an icon/tint.
    struct CardFact: Sendable, Equatable {
        enum Kind: String, Sendable {
            case sends, hardest, duration, flashRate, projects, prBadge, live, provenance
        }
        var kind: Kind
        var value: String
        var label: String
    }

    /// The fully-resolved per-card model: the default three facts (Sends · Hardest · Duration) with at
    /// most ONE notable badge swapped in, plus the provenance glyph and the live flag.
    struct CardModel: Sendable, Equatable, Identifiable {
        var id: UUID
        var title: String
        /// The 3 primary facts shown on the card face.
        var facts: [CardFact]
        /// At most one notable badge (flash-rate / PR / # projects) — the Strava rule. `nil` when nothing
        /// was notable this session.
        var badge: CardFact?
        var provenance: CardFact
        var isLive: Bool
    }

    // MARK: - Display model

    /// One leaf session in a group — the card model plus its grouping key (so the view can place it).
    struct SessionRow: Sendable, Equatable, Identifiable {
        var id: UUID { session.id }
        var session: SessionItem
        var card: CardModel
    }

    /// A roll-up group header + its sessions. `id` is the period label (`"2026-06"` / `"2026-W24"` /
    /// `"all"`); `headline` is the human header ("June 2026"); `summary` is the roll-up line
    /// ("7 sessions · 41 sent · hardest V7").
    struct Group: Sendable, Equatable, Identifiable {
        var id: String
        var headline: String
        var summary: String
        var rows: [SessionRow]
    }

    /// What recovery to offer when the active filters leave the current scope empty — pointing the user at
    /// the control that actually helps (FG):
    ///   • `.none` — nothing to recover (groups exist, or a genuinely empty history with no filters).
    ///   • `.widenScope` — the filters DO match sessions, just not in the current scope's window → suggest
    ///     widening the scope (clearing filters wouldn't surface the matches; they're in another period).
    ///   • `.clearFilters` — the filters match NOTHING anywhere → suggest clearing them.
    enum StaleFilterRecovery: String, Sendable, Equatable {
        case none, widenScope, clearFilters
    }

    /// The whole grouped, filtered history the view renders.
    struct DisplayModel: Sendable, Equatable {
        var groups: [Group]
        /// Distinct selectable values per facet, in render order (the chip rail's content). Built from
        /// the FULL session+log set so a chip never vanishes just because the current filter hid its rows.
        var facetValues: [Facet: [String]]
        /// The scope-aware recovery affordance to surface (FG) — which control will actually help.
        var staleRecovery: StaleFilterRecovery
        /// Back-compat: true when ANY recovery is offered (the current scope is empty under active
        /// filters). Prefer `staleRecovery` to choose the affordance's wording/target.
        var isStaleFilter: Bool { staleRecovery != .none }
        var totalSessions: Int
    }

    // MARK: - Build

    /// Build the grouped display model from the value-mirror sessions + their logs, a scope, the filter
    /// state, and a clock. `layoutName` resolves a `layoutId` to a human board name for the Board facet
    /// chips + provenance (the view passes the catalog lookup; tests pass a stub).
    static func build(sessions: [SessionItem],
                      logs: [KilterClimbLog],
                      scope: Scope,
                      filters: Filters,
                      now: Date,
                      calendar: Calendar = .current,
                      layoutName: (Int) -> String? = { _ in nil }) -> DisplayModel {

        let logsBySession = Dictionary(grouping: logs.compactMap { l in l.sessionId.map { ($0, l) } },
                                       by: { $0.0 }).mapValues { $0.map(\.1) }

        // Facet values come from the FULL set (pre-filter) so toggling a chip can't make others vanish.
        let facetValues = facetValues(sessions: sessions, logs: logs,
                                      calendar: calendar, layoutName: layoutName)

        // Scope window first, then facet/search filtering.
        let scoped = inScope(sessions, scope: scope, now: now, calendar: calendar)
        let filtered = scoped.filter {
            matches($0, logs: logsBySession[$0.id] ?? [], filters: filters,
                    calendar: calendar, layoutName: layoutName)
        }

        // Prior-hardest per session (the PR-badge baseline): the hardest send across every session that
        // started STRICTLY earlier — computed over the full set so a PR is global, not scoped/filtered.
        let priorHardest = priorHardestBySession(sessions, logsBySession: logsBySession)

        let groups = group(filtered, logsBySession: logsBySession, priorHardest: priorHardest,
                           scope: scope, now: now, calendar: calendar)

        // Scope-aware recovery (FG): only when filters are active AND the current scope is empty. If the
        // SAME filters still match a session somewhere in the full set, the matches are merely in another
        // period → suggest widening scope; if they match nothing at all → suggest clearing filters.
        let recovery: StaleFilterRecovery
        if groups.isEmpty, filters.isActive, !sessions.isEmpty {
            let matchesAnywhere = sessions.contains {
                matches($0, logs: logsBySession[$0.id] ?? [], filters: filters,
                        calendar: calendar, layoutName: layoutName)
            }
            recovery = matchesAnywhere ? .widenScope : .clearFilters
        } else {
            recovery = .none
        }

        return DisplayModel(groups: groups, facetValues: facetValues,
                            staleRecovery: recovery, totalSessions: sessions.count)
    }

    // MARK: - Scope windowing

    /// Keep sessions that fall inside the scope's trailing window from `now`: `.week` = the current
    /// calendar week, `.month` = the current calendar month, `.all` = everything. Newest-first.
    static func inScope(_ sessions: [SessionItem], scope: Scope, now: Date,
                        calendar: Calendar) -> [SessionItem] {
        let sorted = sessions.sorted { $0.startedAt > $1.startedAt }
        switch scope {
        case .all:
            return sorted
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return sorted }
            return sorted.filter { interval.contains($0.startedAt) || $0.isActive }
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: now) else { return sorted }
            return sorted.filter { interval.contains($0.startedAt) || $0.isActive }
        }
    }

    // MARK: - Faceted filtering + stale detection

    /// Whether a session passes every active facet + the search query (all AND-combined). `logs` are
    /// this session's logs (for the grade/status facets + name search over climbs).
    static func matches(_ session: SessionItem, logs: [KilterClimbLog], filters: Filters,
                        calendar: Calendar, layoutName: (Int) -> String?) -> Bool {
        for (facet, value) in filters.selections {
            switch facet {
            case .board:
                guard boardToken(session, layoutName: layoutName) == value else { return false }
            case .angle:
                guard angleToken(session.angle) == value else { return false }
            case .grade:
                guard logs.contains(where: { $0.gradeLabel == value }) else { return false }
            case .status:
                guard logs.contains(where: { $0.status.rawValue == value }) else { return false }
            case .source:
                guard sourceToken(session.source) == value else { return false }
            }
        }
        let q = filters.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        // Search matches the title, the board name, or any climb name in the session.
        if let t = session.title, t.lowercased().contains(q) { return true }
        if let name = session.layoutId.flatMap(layoutName)?.lowercased(), name.contains(q) { return true }
        return logs.contains { $0.climbName.lowercased().contains(q) }
    }

    /// Distinct selectable values per facet, each in a stable render order. Built over the FULL data set
    /// (every session + every log) so the chip rail is constant regardless of the current filter.
    static func facetValues(sessions: [SessionItem], logs: [KilterClimbLog],
                            calendar: Calendar, layoutName: (Int) -> String?) -> [Facet: [String]] {
        var out: [Facet: [String]] = [:]

        // Board: distinct layout tokens, by first appearance among newest-first sessions.
        var seenBoard = Set<String>()
        out[.board] = sessions.sorted { $0.startedAt > $1.startedAt }
            .compactMap { s -> String? in
                let token = boardToken(s, layoutName: layoutName)
                return seenBoard.insert(token).inserted ? token : nil
            }

        // Angle: ascending.
        out[.angle] = Set(sessions.map(\.angle)).sorted().map(angleToken)

        // Source: in a fixed canonical order, only those present.
        let presentSources = Set(sessions.map { sourceToken($0.source) })
        out[.source] = ["BLE", "Manual"].filter(presentSources.contains)

        // Grade: distinct grade labels, hardest→easiest by their representative difficulty, tie-broken by
        // the gradeLabel string so two labels at the same difficulty order deterministically (not by the
        // unordered Dictionary's iteration) (FF).
        var hardestByLabel: [String: Double] = [:]
        for l in logs { hardestByLabel[l.gradeLabel] = max(hardestByLabel[l.gradeLabel] ?? -.infinity, l.difficulty) }
        out[.grade] = hardestByLabel.keys.sorted {
            let (d0, d1) = (hardestByLabel[$0] ?? 0, hardestByLabel[$1] ?? 0)
            return d0 != d1 ? d0 > d1 : $0 < $1
        }

        // Status: canonical order, only those present.
        let presentStatuses = Set(logs.map(\.status))
        out[.status] = KilterAscentStatus.allCases.filter(presentStatuses.contains).map(\.rawValue)

        // Drop empty facets so the view only renders chips that can do something.
        return out.filter { !$0.value.isEmpty }
    }

    // MARK: - Grouping + roll-ups

    /// Bucket the (already scoped + filtered) sessions into period groups, newest period first, with a
    /// roll-up summary header per group. `.week`/`.month` bucket by ISO week / calendar month; `.all`
    /// is a single "All sessions" group (the timeline scrolls one list).
    ///
    /// An ACTIVE session (`endedAt == nil`) is bucketed by the CURRENT period (`now`), not its own
    /// possibly-old `startedAt` — so a session that's been open since last week never renders a stale
    /// week/month header in Week/Month scope (FD). Its grouping date is pinned to `now` for both the
    /// bucket key and the header.
    static func group(_ sessions: [SessionItem], logsBySession: [UUID: [KilterClimbLog]],
                      priorHardest: [UUID: Double] = [:],
                      scope: Scope, now: Date = .now, calendar: Calendar = .current) -> [Group] {
        guard !sessions.isEmpty else { return [] }

        // The date a session is bucketed/headlined by: `now` for an active session (so it lands in the
        // current period, never a stale one), else its real `startedAt`.
        func groupingDate(_ s: SessionItem) -> Date { s.isActive ? now : s.startedAt }

        func rows(_ ss: [SessionItem]) -> [SessionRow] {
            ss.sorted { $0.startedAt > $1.startedAt }.map { s in
                SessionRow(session: s, card: card(for: s, logs: logsBySession[s.id] ?? [],
                                                  priorHardestDifficulty: priorHardest[s.id]))
            }
        }

        if scope == .all {
            let summary = rollupSummary(sessions, logsBySession: logsBySession)
            return [Group(id: "all", headline: "All sessions", summary: summary, rows: rows(sessions))]
        }

        let keyed = Dictionary(grouping: sessions) { s -> String in
            scope == .week ? weekKey(groupingDate(s), calendar: calendar)
                           : monthKey(groupingDate(s), calendar: calendar)
        }
        return keyed.keys.sorted(by: >).map { key in
            let ss = keyed[key]!
            // Headline off a grouping date in THIS bucket (so an active session pinned to `now` headlines
            // the current period, not its stale start). All members share the key, so any one works.
            let headlineDate = groupingDate(ss[0])
            return Group(id: key,
                         headline: scope == .week ? weekHeadline(headlineDate, calendar: calendar)
                                                   : monthHeadline(headlineDate, calendar: calendar),
                         summary: rollupSummary(ss, logsBySession: logsBySession),
                         rows: rows(ss))
        }
    }

    /// For each session, the hardest send difficulty across every session that started STRICTLY earlier
    /// (the PR baseline). A session with no earlier *send* is absent from the map → the card treats it as
    /// "first-ever" and badges a PR whenever it sent something.
    static func priorHardestBySession(_ sessions: [SessionItem],
                                      logsBySession: [UUID: [KilterClimbLog]]) -> [UUID: Double] {
        // Tie-break identical `startedAt` by id so the running-max walk (and thus which session is awarded
        // the PR) is deterministic for sessions started at the same instant (FF).
        let chronological = sessions.sorted {
            $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt
                                         : $0.id.uuidString < $1.id.uuidString
        }
        var out: [UUID: Double] = [:]
        var running: Double? = nil   // hardest send seen so far (across earlier sessions)
        for s in chronological {
            if let r = running { out[s.id] = r }   // absent when no earlier send yet
            let hardestHere = (logsBySession[s.id] ?? []).filter(\.isSend).map(\.difficulty).max()
            if let h = hardestHere { running = max(running ?? -.infinity, h) }
        }
        return out
    }

    /// The roll-up header line: "7 sessions · 41 sent · hardest V7" (the hardest clause drops when
    /// nothing was sent in the period).
    static func rollupSummary(_ sessions: [SessionItem],
                              logsBySession: [UUID: [KilterClimbLog]]) -> String {
        let logs = sessions.flatMap { logsBySession[$0.id] ?? [] }
        let sent = logs.filter(\.isSend).count
        // Hardest send, tie-broken by gradeLabel so two equally-hard sends pick the same label every time
        // (not whichever the unordered flatMap happened to surface) (FF).
        let hardest = logs.filter(\.isSend).max {
            $0.difficulty != $1.difficulty ? $0.difficulty < $1.difficulty : $0.gradeLabel > $1.gradeLabel
        }?.gradeLabel
        var parts = ["\(sessions.count) session\(sessions.count == 1 ? "" : "s")",
                     "\(sent) sent"]
        if let hardest { parts.append("hardest \(hardest)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Adaptive card facts

    /// Build the adaptive card model for one session (Strava rule — exactly ONE notable badge at most).
    /// Default facts: Sends · Hardest · Duration. The badge swaps in the most notable of: a flash-rate
    /// chip (≥1 flash and flash-rate ≥ 0.5), a PR badge (this session set a new hardest send vs the rest
    /// — passed in as `priorHardest`), or # projects (≥1 project). PR wins over flash wins over projects.
    static func card(for session: SessionItem, logs: [KilterClimbLog],
                     priorHardestDifficulty: Double? = nil) -> CardModel {
        let sends = logs.filter(\.isSend)
        let hardest = sends.max { $0.difficulty < $1.difficulty }
        let projects = logs.filter { $0.status == .project }.count
        let flashes = logs.filter { $0.status == .flash }.count

        let facts: [CardFact] = [
            CardFact(kind: .sends, value: "\(sends.count)", label: sends.count == 1 ? "send" : "sends"),
            CardFact(kind: .hardest, value: hardest?.gradeLabel ?? "—", label: "hardest"),
            CardFact(kind: .duration, value: durationLabel(session), label: "duration"),
        ]

        let badge = notableBadge(sends: sends.count, flashes: flashes, projects: projects,
                                 hardest: hardest, priorHardestDifficulty: priorHardestDifficulty)

        let prov = CardFact(kind: .provenance,
                            value: sourceToken(session.source),
                            label: session.source == "ble" ? "Auto-captured" : "Logged by hand")

        return CardModel(id: session.id,
                         title: session.title ?? defaultTitle(session),
                         facts: facts, badge: badge, provenance: prov, isLive: session.isActive)
    }

    /// The ONE notable badge (or none). Priority: PR > flash-rate > projects — so the rarest, most
    /// celebration-worthy signal wins the single slot.
    static func notableBadge(sends: Int, flashes: Int, projects: Int,
                             hardest: KilterClimbLog?, priorHardestDifficulty: Double?) -> CardFact? {
        // PR: this session's hardest send beats every prior session's hardest.
        if let hardest, let prior = priorHardestDifficulty, hardest.difficulty > prior {
            return CardFact(kind: .prBadge, value: hardest.gradeLabel, label: "PR")
        }
        // First-ever hardest (no prior sends anywhere) is also a PR when something was sent.
        if let hardest, priorHardestDifficulty == nil, sends > 0 {
            return CardFact(kind: .prBadge, value: hardest.gradeLabel, label: "PR")
        }
        // Flash-rate: notable when ≥1 flash AND at least half the sends were flashes.
        if flashes > 0, sends > 0, Double(flashes) / Double(sends) >= 0.5 {
            let pct = Int((Double(flashes) / Double(sends) * 100).rounded())
            return CardFact(kind: .flashRate, value: "\(pct)%", label: "flash rate")
        }
        // Projects: notable when the session worked ≥1 project.
        if projects > 0 {
            return CardFact(kind: .projects, value: "\(projects)", label: projects == 1 ? "project" : "projects")
        }
        return nil
    }

    // MARK: - Token + label helpers (the chips' raw vocabulary)

    static func boardToken(_ session: SessionItem, layoutName: (Int) -> String?) -> String {
        session.layoutId.flatMap(layoutName) ?? (session.layoutId.map { "Layout \($0)" } ?? "Board")
    }
    static func angleToken(_ angle: Int) -> String { "\(angle)°" }
    static func sourceToken(_ source: String) -> String { source == "ble" ? "BLE" : "Manual" }

    static func defaultTitle(_ session: SessionItem) -> String {
        session.startedAt.formatted(.dateTime.weekday(.wide).day().month())
    }

    static func durationLabel(_ session: SessionItem) -> String {
        guard let end = session.endedAt else { return "live" }
        let minutes = max(0, Int(end.timeIntervalSince(session.startedAt) / 60))
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: - Calendar keys + headlines

    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    static func weekKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }
    static func monthHeadline(_ date: Date, calendar: Calendar) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }
    static func weekHeadline(_ date: Date, calendar: Calendar) -> String {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return weekKey(date, calendar: calendar)
        }
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "Week of \(interval.start.formatted(.dateTime.month().day())) – \(end.formatted(.dateTime.month().day()))"
    }
}

extension KilterHistoryModel.SessionItem {
    /// Map a SwiftData `KilterSession` to the value-mirror history item (so the pure model never touches
    /// the @Model). `hasHR` is derived from whether the persisted series is non-empty.
    static func from(_ session: KilterSession) -> KilterHistoryModel.SessionItem {
        KilterHistoryModel.SessionItem(
            id: session.id, startedAt: session.startedAt, endedAt: session.endedAt,
            angle: session.angle, source: session.source, layoutId: session.layoutId,
            title: session.title, hasHR: !session.hrSeries.isEmpty)
    }
}

// MARK: - Consistency surfaces (heatmap + calendar), pure

/// Pure inputs for the two consistency surfaces (Kilter Improvement P4): a GitHub-style activity heatmap
/// and a tappable month calendar. Both are derived from per-day session/send counts so the views are
/// dumb renderers and the bucketing is unit-tested. Foundation only.
enum KilterConsistency {

    /// One day in either surface: its date, how many sessions started that day, how many sends, and an
    /// intensity 0…1 (sends- or volume-scaled) the heatmap cell uses for its fill. `sessionIDs` lets a
    /// tapped cell/day open that day's session(s).
    struct Day: Sendable, Equatable, Identifiable {
        var date: Date
        var sessions: Int
        var sends: Int
        var intensity: Double
        var sessionIDs: [UUID]
        var id: Date { date }
        /// A day reads as "active" (gets fill / a dot) when it had a session OR any send — so an ad-hoc
        /// send-only day (`sessionId == nil`, no session row) still shows activity (FE). Tapping such a
        /// day is a no-op (no `sessionIDs` to open), but it's no longer invisibly faint.
        var isEmpty: Bool { sessions == 0 && sends == 0 }
    }

    /// Build a trailing-`weeks`-week heatmap ending at `now`, aligned to whole weeks (so columns are
    /// weeks and rows are weekdays, the GitHub layout). Intensity = a day's sends scaled by the busiest
    /// day in the window (so the accent always reaches full on the best day). Days with no session are
    /// emitted at intensity 0 (the faint empty cell).
    static func heatmap(sessions: [KilterHistoryModel.SessionItem], logs: [KilterClimbLog],
                        now: Date, weeks: Int = 26, calendar: Calendar = .current) -> [Day] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        guard let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(max(1, weeks) - 1), to: thisWeek)
        else { return [] }

        let sendsByDay = countsByDay(sessions: sessions, logs: logs, calendar: calendar)

        // One cell per day from the first week's start through the end of the current week.
        guard let lastDay = calendar.date(byAdding: .day, value: 6, to: thisWeek) else { return [] }
        // Collect the window's day keys first so intensity can be normalized over the days IN the window —
        // an out-of-window busy day must NOT crush the visible cells (FE).
        var keys: [Date] = []
        var cursor = firstWeek
        while cursor <= lastDay {
            keys.append(calendar.startOfDay(for: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let maxSends = keys.compactMap { sendsByDay[$0]?.sends }.max() ?? 0
        return keys.map { key in
            let entry = sendsByDay[key]
            let intensity = (maxSends > 0 && entry != nil) ? Double(entry!.sends) / Double(maxSends) : 0
            return Day(date: key, sessions: entry?.sessions ?? 0, sends: entry?.sends ?? 0,
                       intensity: min(1, intensity), sessionIDs: entry?.ids ?? [])
        }
    }

    /// Build the day cells for one calendar month containing `month` (only the real days of that month,
    /// in order) for the tappable month calendar. Empty days carry zero counts so the view can dot only
    /// the active ones.
    static func monthDays(sessions: [KilterHistoryModel.SessionItem], logs: [KilterClimbLog],
                          month: Date, calendar: Calendar = .current) -> [Day] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let sendsByDay = countsByDay(sessions: sessions, logs: logs, calendar: calendar)

        // The month's day keys, so intensity is normalized over THIS month (not an out-of-month busy
        // day) — the calendar-surface twin of the heatmap window normalization (FE).
        let keys: [Date] = range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: interval.start).map(calendar.startOfDay(for:))
        }
        let maxSends = keys.compactMap { sendsByDay[$0]?.sends }.max() ?? 0

        return keys.map { key in
            let entry = sendsByDay[key]
            let intensity = (maxSends > 0 && entry != nil) ? Double(entry!.sends) / Double(maxSends) : 0
            return Day(date: key, sessions: entry?.sessions ?? 0, sends: entry?.sends ?? 0,
                       intensity: min(1, intensity), sessionIDs: entry?.ids ?? [])
        }
    }

    /// Per-start-of-day tallies for the consistency surfaces. Two facts are bucketed by DIFFERENT days,
    /// on purpose (FE):
    ///   • **sessions** + **ids** — by the session's `startedAt` local day (a tapped day opens a session
    ///     that day).
    ///   • **sends** — by each LOG's `loggedAt` local day (NOT its session's `startedAt`), so a send
    ///     logged just after midnight lands on the calendar cell it actually happened on; and EVERY send
    ///     is counted, including ad-hoc logs with `sessionId == nil`, so the heatmap/calendar don't
    ///     under-report.
    private static func countsByDay(sessions: [KilterHistoryModel.SessionItem], logs: [KilterClimbLog],
                                    calendar: Calendar) -> [Date: (sessions: Int, sends: Int, ids: [UUID])] {
        var out: [Date: (sessions: Int, sends: Int, ids: [UUID])] = [:]
        for s in sessions {
            let key = calendar.startOfDay(for: s.startedAt)
            var entry = out[key] ?? (0, 0, [])
            entry.sessions += 1
            entry.ids.append(s.id)
            out[key] = entry
        }
        for l in logs where l.isSend {
            let key = calendar.startOfDay(for: l.loggedAt)
            var entry = out[key] ?? (0, 0, [])
            entry.sends += 1
            out[key] = entry
        }
        return out
    }
}
