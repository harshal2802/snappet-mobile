import Foundation

/// **Pure racket-sports read model** (prompt 203): the numbers every surface shows — the session's
/// tournament record, head-to-head against an opponent, a drill's accuracy, the Library headline, the Clips
/// post title, and each game's time window (for per-game heart rate). Derived from `SessionExercise` /
/// `SetLog` only — Foundation, unit-tested in `RacketStatsTests`.
enum RacketStats {

    /// Ids a racket entity is logged under. A match's activity is the SPORT (every opponent is the same
    /// "Table tennis match" in the Library); a drill's is the sport + its name.
    static func matchExerciseId(_ sport: RacketSport) -> String { "adhoc-racket-match-\(sport.rawValue)" }
    static func drillExerciseId(_ sport: RacketSport) -> String { "adhoc-racket-drill-\(sport.rawValue)" }
    /// The display name a match entity carries (its activity name — the page shows the opponent instead).
    static func matchActivityName(_ sport: RacketSport) -> String { "\(sport.label) match" }

    // MARK: - Records

    struct Record: Equatable, Sendable {
        var won = 0
        var lost = 0
        var played: Int { won + lost }
        /// "3W – 1L".
        var label: String { "\(won)W – \(lost)L" }
        /// "7–3" (the H2H form).
        var shortLabel: String { "\(won)–\(lost)" }
        var winRate: Double? { played > 0 ? Double(won) / Double(played) : nil }
    }

    /// Won/lost over the DECIDED matches among `entities` (open-play and unfinished matches don't count).
    static func record(_ entities: [SessionExercise]) -> Record {
        var r = Record()
        for ex in entities where ex.isRacketMatch {
            switch ex.racketState.result { case true?: r.won += 1; case false?: r.lost += 1; case nil: break }
        }
        return r
    }

    /// Head-to-head vs one opponent in one sport, across `history` (+ any extra entities, e.g. the live
    /// session's). Opponent names match case- and diacritic-insensitively.
    static func headToHead(opponent: String?, sport: RacketSport?, history: [WorkoutSession],
                           including extra: [SessionExercise] = []) -> Record {
        guard let key = opponent.map(normalize), !key.isEmpty else { return Record() }
        let all = history.flatMap(\.exercises) + extra
        return record(all.filter { $0.isRacketMatch && $0.racketSport == sport && normalize($0.opponent ?? "") == key })
    }

    /// Distinct recent opponents for a sport, most recent first (the new-match sheet's chips).
    static func recentOpponents(sport: RacketSport, history: [WorkoutSession], limit: Int = 4) -> [String] {
        recentValues(history: history, limit: limit) { $0.isRacketMatch && $0.racketSport == sport ? $0.opponent : nil }
    }

    /// Distinct recent event names across every racket match.
    static func recentEvents(history: [WorkoutSession], limit: Int = 3) -> [String] {
        recentValues(history: history, limit: limit) { $0.isRacketMatch ? $0.racketEvent : nil }
    }

    /// Distinct drills previously logged for a sport, most recent first, with their measure.
    static func recentDrills(sport: RacketSport, history: [WorkoutSession]) -> [(name: String, measure: RacketDrillMeasure)] {
        var seen = Set<String>(), out: [(String, RacketDrillMeasure)] = []
        for s in history.sorted(by: { $0.startedAt > $1.startedAt }) {
            for ex in s.exercises where ex.isRacketDrill && ex.racketSport == sport {
                let name = ex.displayName ?? ""
                guard !name.isEmpty, seen.insert(normalize(name)).inserted else { continue }
                out.append((name, ex.drillMeasure))
            }
        }
        return out
    }

    private static func recentValues(history: [WorkoutSession], limit: Int,
                                     _ value: (SessionExercise) -> String?) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in history.sorted(by: { $0.startedAt > $1.startedAt }) {
            for ex in s.exercises.reversed() {
                guard let v = value(ex)?.trimmingCharacters(in: .whitespaces), !v.isEmpty,
                      seen.insert(normalize(v)).inserted else { continue }
                out.append(v)
                if out.count == limit { return out }
            }
        }
        return out
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Session summary

    struct SessionSummary: Equatable, Sendable {
        var record: Record
        var matches: Int
        var units: Int
        var drills: Int
        var sport: RacketSport?
        var event: String?
    }

    /// The racket roll-up for a session, or `nil` when it has no racket entity.
    static func summary(_ exercises: [SessionExercise]) -> SessionSummary? {
        let racket = exercises.filter { $0.discipline == .racket }
        guard !racket.isEmpty else { return nil }
        let matches = racket.filter(\.isRacketMatch)
        return SessionSummary(
            record: record(matches),
            matches: matches.count,
            units: matches.reduce(0) { $0 + $1.racketUnits.count },
            drills: racket.filter(\.isRacketDrill).count,
            sport: racket.first?.racketSport,
            event: matches.compactMap(\.racketEvent).first { !$0.isEmpty })
    }

    /// One match in a line: "11–7 9–11 12–10 11–8".
    static func unitsLine(_ ex: SessionExercise) -> String {
        ex.racketUnits.map(\.label).joined(separator: "  ")
    }

    /// "R16 · vs Alex Chen" — the match's row title.
    static func matchRowTitle(_ ex: SessionExercise) -> String {
        [ex.racketRound, ex.racketMatchTitle].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// The Clips post / share title: "R16 vs Alex Chen · Won 3–1" (in play: "· 2–1").
    static func postTitle(_ ex: SessionExercise) -> String {
        if ex.isRacketDrill {
            guard let line = drillLine(ex) else { return ex.displayName ?? "Drill" }
            return "\(ex.displayName ?? "Drill") · \(line)"
        }
        let state = ex.racketState
        let head = [ex.racketRound, ex.racketMatchTitle].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        guard let result = state.result else {
            return state.playedUnits > 0 ? "\(head) · \(state.scoreLabel)" : head
        }
        return "\(head) · \(result ? "Won" : "Lost") \(state.scoreLabel)"
    }

    /// The Clips post subtitle: "City Open · Table tennis · 11–7 9–11 12–10 11–8".
    static func postSubtitle(_ ex: SessionExercise) -> String {
        var parts: [String] = []
        if let e = ex.racketEvent, !e.isEmpty { parts.append(e) }
        if let sport = ex.racketSport { parts.append(sport.label) }
        if ex.isRacketMatch, !ex.racketUnits.isEmpty { parts.append(unitsLine(ex)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Drills

    /// A drill's best block, in words: "76%" (made/tried) · "rally 42" · total time.
    static func drillLine(_ ex: SessionExercise) -> String? {
        let done = ex.sets.filter { $0.completedAt != nil }
        guard !done.isEmpty else { return nil }
        switch ex.drillMeasure {
        case .madeTried:
            let made = done.compactMap(\.drillMade).reduce(0, +)
            let tried = done.compactMap(\.drillTried).reduce(0, +)
            guard let acc = RacketScoring.accuracy(made: made, tried: tried) else { return "\(done.count) blocks" }
            return "\(made)/\(tried) · \(percent(acc))"
        case .longestRally:
            guard let best = done.compactMap(\.longestRally).max() else { return "\(done.count) blocks" }
            return "rally \(best)"
        case .time:
            let t = done.compactMap(\.durationSec).reduce(0, +)
            return t > 0 ? SetMeasure.formatDuration(t) : "\(done.count) blocks"
        }
    }

    /// One drill block's ledger text: "33/50 66%" · "rally 18" · "3:00".
    static func blockLine(_ set: SetLog, measure: RacketDrillMeasure) -> String {
        var parts: [String] = []
        switch measure {
        case .madeTried:
            if let m = set.drillMade, let t = set.drillTried {
                parts.append("\(m)/\(t)")
                if let acc = RacketScoring.accuracy(made: m, tried: t) { parts.append(percent(acc)) }
            }
        case .longestRally:
            if let r = set.longestRally { parts.append("rally \(r)") }
        case .time: break
        }
        if let d = set.durationSec, d > 0 { parts.append(SetMeasure.formatDuration(d)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: - Library headline / last line

    /// The Library row headline + its sort value: a match activity's record ("7W – 3L", win rate), a drill's
    /// best accuracy / rally / total time.
    static func headline(_ ents: [SessionExercise]) -> (String?, Double?) {
        guard let first = ents.first else { return (nil, nil) }
        if first.isRacketMatch {
            let r = record(ents)
            return r.played > 0 ? (r.label, r.winRate) : (nil, nil)
        }
        let done = ents.flatMap { $0.sets.filter { $0.completedAt != nil } }
        switch first.drillMeasure {
        case .madeTried:
            let best = done.compactMap { RacketScoring.accuracy(made: $0.drillMade, tried: $0.drillTried) }.max()
            return (best.map(percent), best)
        case .longestRally:
            let best = done.compactMap(\.longestRally).max()
            return (best.map { "rally \($0)" }, best.map(Double.init))
        case .time:
            let t = done.compactMap(\.durationSec).reduce(0, +)
            return t > 0 ? (SetMeasure.formatDuration(t), t) : (nil, nil)
        }
    }

    /// The pickers' "Last: …" line: "W 3–1 vs Alex" / "3 blocks · 76%".
    static func lastLine(_ ex: SessionExercise) -> String? {
        if ex.isRacketMatch {
            let s = ex.racketState
            guard s.playedUnits > 0 || s.end != nil else { return nil }
            return "\(s.shortResult) \(ex.racketMatchTitle)"
        }
        return drillLine(ex)
    }

    // MARK: - Per-unit time windows (per-game heart rate, clip placement)

    struct UnitWindow: Equatable, Sendable {
        var index: Int
        /// Seconds from session start.
        var start: Double
        var end: Double
    }

    /// Each logged unit's window on the session timeline. A unit ends when it was logged; it starts at its
    /// timed duration back from there, else when the previous unit ended. The FIRST untimed unit has no previous
    /// end — it gets this match's typical unit length (the median of its other units), else `fallbackSec`, so
    /// the rest before a match isn't counted as play (2026-10-26: a flat 10 min pulled in the break between
    /// tournament matches). Clipped to the session start.
    static func unitWindows(_ ex: SessionExercise, sessionStart: Date,
                            fallbackSec: Double = 300) -> [UnitWindow] {
        let logged = ex.sets.enumerated().compactMap { i, set in
            set.completedAt.map { (index: i, end: $0.timeIntervalSince(sessionStart), duration: set.durationSec) }
        }
        var lengths: [Double] = []
        for (j, u) in logged.enumerated() {
            if let d = u.duration, d > 0 { lengths.append(d) }
            else if j > 0 { lengths.append(u.end - logged[j - 1].end) }
        }
        let typical = median(lengths.filter { $0 > 0 }) ?? fallbackSec
        var out: [UnitWindow] = []
        var previousEnd: Double?
        for u in logged {
            let start: Double
            if let d = u.duration, d > 0 { start = u.end - d }
            else if let p = previousEnd { start = p }
            else { start = u.end - typical }
            out.append(UnitWindow(index: u.index, start: max(0, min(start, u.end)), end: max(0, u.end)))
            previousEnd = u.end
        }
        return out
    }

    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Average / peak bpm inside each unit window (units with no samples are left out).
    struct UnitHR: Equatable, Sendable {
        var index: Int
        var avg: Double
        var peak: Double
        /// Time per zone 1…5 (index 0 = zone 1), seconds — drives the zone bar.
        var zoneSeconds: [Double]
    }

    static func unitHR(_ ex: SessionExercise, series: [HRPoint], sessionStart: Date,
                       maxHR: Double) -> [UnitHR] {
        let pts = series.sorted { $0.t < $1.t }
        return unitWindows(ex, sessionStart: sessionStart).compactMap { w in
            let inside = pts.filter { $0.t >= w.start && $0.t <= w.end }
            guard !inside.isEmpty else { return nil }
            let avg = inside.map(\.bpm).reduce(0, +) / Double(inside.count)
            var zones = [Double](repeating: 0, count: 5)
            for (j, p) in inside.enumerated() {
                let next = j + 1 < inside.count ? inside[j + 1].t : min(w.end, p.t + 5)
                let z = HeartRateZone.forBpm(p.bpm, maxHR: maxHR).rawValue
                if z >= 1 && z <= 5 { zones[z - 1] += max(0, next - p.t) }
            }
            return UnitHR(index: w.index, avg: avg, peak: inside.map(\.bpm).max() ?? avg, zoneSeconds: zones)
        }
    }
}
