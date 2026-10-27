import Foundation

// MARK: - Racket sports (prompt 203) — the pure rules engine
//
// A racket entity is a `SessionExercise` with the `.racket` discipline, a `RacketSport`, and a mode:
//
//   • **Match** — against an opponent, in a format (best of N, points to T). Each logged `SetLog` is one
//     scored UNIT: a game (table tennis / badminton / squash / pickleball — points) or a set (tennis /
//     padel — games, plus an optional tiebreak). The match result is DERIVED from those units, never
//     stored, so editing or deleting a game can't leave a stale "won 3–1" behind.
//   • **Drill** — practice blocks: time, plus optionally made/tried or a longest rally.
//
// Scores are checked against the sport's rules but never BLOCKED: a retirement, a house rule or a typo
// fixed later all have to be saveable (the score sheet shows an amber warning instead). The winner of a
// unit is simply the higher score.
//
// Foundation only — unit-tested in `RacketScoringTests` with no device.

/// The six supported racket sports.
enum RacketSport: String, Codable, CaseIterable, Identifiable, Sendable {
    case tableTennis, badminton, tennis, padel, pickleball, squash
    var id: String { rawValue }

    var label: String {
        switch self {
        case .tableTennis: return "Table tennis"
        case .badminton:   return "Badminton"
        case .tennis:      return "Tennis"
        case .padel:       return "Padel"
        case .pickleball:  return "Pickleball"
        case .squash:      return "Squash"
        }
    }

    /// SF Symbol for the sport (padel shares tennis's figure — there's no padel glyph).
    var symbol: String {
        switch self {
        case .tableTennis: return "figure.table.tennis"
        case .badminton:   return "figure.badminton"
        case .tennis, .padel: return "figure.tennis"
        case .pickleball:  return "figure.pickleball"
        case .squash:      return "figure.squash"
        }
    }

    /// What one logged effort of a match scores: a game of points, or a set of games.
    var unit: RacketUnit { usesSets ? .set : .game }

    /// Tennis and padel score sets of games (with tiebreaks); the rest score games of points.
    var usesSets: Bool { self == .tennis || self == .padel }

    /// Points to win a game (or games to win a set, for tennis / padel).
    var defaultPointsTo: Int {
        switch self {
        case .tableTennis, .squash, .pickleball: return 11
        case .badminton: return 21
        case .tennis, .padel: return 6
        }
    }

    /// The alternatives offered in the format row (only pickleball's games vary in practice).
    var pointsToOptions: [Int] {
        switch self {
        case .pickleball: return [11, 15, 21]
        default: return [defaultPointsTo]
        }
    }

    /// Badminton's 30-point cap (29–29 → next point wins). `nil` ⇒ uncapped win-by-2.
    var cap: Int? { self == .badminton ? 30 : nil }

    var defaultBestOf: Int {
        switch self {
        case .tableTennis, .squash: return 5
        case .badminton, .pickleball, .tennis, .padel: return 3
        }
    }

    var bestOfOptions: [Int] {
        switch self {
        case .tableTennis: return [3, 5, 7]
        case .squash: return [3, 5]
        case .badminton, .pickleball: return [1, 3]
        case .tennis: return [1, 3, 5]
        case .padel: return [1, 3]
        }
    }

    /// Padel is (almost always) played as doubles.
    var defaultsToDoubles: Bool { self == .padel }

    /// The one-line default format under the sport in the picker ("games to 11 · best of 5").
    var formatSummary: String {
        usesSets
            ? "sets to \(defaultPointsTo) · tiebreak"
            : "games to \(defaultPointsTo) · best of \(defaultBestOf)"
    }
}

/// What one match effort scores.
enum RacketUnit: String, Codable, Sendable {
    case game, set
    var noun: String { rawValue }
    /// "G" / "S" — the short prefix on game chips ("G3 12–10").
    var shortPrefix: String { self == .game ? "G" : "S" }
}

/// Match (scored vs an opponent) or Drill (practice blocks).
enum RacketMode: String, Codable, CaseIterable, Sendable {
    case match, drill
    var label: String { self == .match ? "Match" : "Drill" }
}

/// What a drill block measures (beyond its time, which every block may carry).
enum RacketDrillMeasure: String, Codable, CaseIterable, Sendable {
    /// Made / tried → accuracy % (serves in, multiball hits on target).
    case madeTried
    /// Longest rally / consecutive hits.
    case longestRally
    /// Time only (footwork, shadow play).
    case time

    var label: String {
        switch self {
        case .madeTried: return "Made / tried"
        case .longestRally: return "Longest rally"
        case .time: return "Time"
        }
    }
}

/// How a match ended when it wasn't simply played out (retirement / walkover). `nil` ⇒ played out.
enum RacketMatchEnd: String, Codable, CaseIterable, Sendable {
    case opponentRetired, iRetired, walkoverWin, walkoverLoss

    var won: Bool { self == .opponentRetired || self == .walkoverWin }
    var label: String {
        switch self {
        case .opponentRetired: return "Opponent retired"
        case .iRetired: return "Retired"
        case .walkoverWin: return "Walkover (won)"
        case .walkoverLoss: return "Walkover (lost)"
        }
    }
}

/// A match's format: how many units, to how many points, and (tennis/padel) a deciding super tiebreak.
struct RacketFormat: Equatable, Sendable {
    var sport: RacketSport
    /// Best of N units. `nil` ⇒ open / untimed — log as many games as you play, never auto-decided.
    var bestOf: Int?
    /// Points to win a game (games to win a set for tennis / padel).
    var pointsTo: Int
    /// Tennis / padel: the deciding set is a super tiebreak to 10.
    var superTiebreak: Bool

    /// `bestOf: nil` is an open format; use `RacketFormat.defaults(for:)` for the sport's standard one.
    init(sport: RacketSport, bestOf: Int?, pointsTo: Int? = nil, superTiebreak: Bool = false) {
        self.sport = sport
        self.bestOf = bestOf.flatMap { $0 > 0 ? $0 : nil }
        self.pointsTo = pointsTo ?? sport.defaultPointsTo
        self.superTiebreak = sport.usesSets && superTiebreak
    }

    /// The sport's standard format (table tennis: best of 5 to 11; tennis: best of 3 sets).
    static func defaults(for sport: RacketSport) -> RacketFormat {
        RacketFormat(sport: sport, bestOf: sport.defaultBestOf)
    }

    /// Units needed to win (3 of a best of 5). `nil` for an open format.
    var unitsToWin: Int? { bestOf.map { $0 / 2 + 1 } }

    /// "Best of 5" / "Best of 3 sets" / "Open play".
    var label: String {
        guard let bestOf else { return "Open play" }
        if bestOf == 1 { return sport.usesSets ? "One set" : "One game" }
        return sport.usesSets ? "Best of \(bestOf) sets" : "Best of \(bestOf)"
    }

    /// The scoreboard's sub-label ("first to 3" / "super-TB decider").
    var sublabel: String {
        guard let need = unitsToWin else { return "log every \(sport.unit.noun)" }
        if superTiebreak { return "super-TB decider" }
        return "first to \(need)"
    }

    /// Is unit `index` (0-based) the deciding super tiebreak? Only when the format asks for one, the
    /// match is level going into its last possible unit.
    func isSuperTiebreak(index: Int) -> Bool {
        guard superTiebreak, let bestOf, bestOf > 1 else { return false }
        return index == bestOf - 1
    }
}

/// One scored unit as logged: points (a game) or games (a set) for and against, plus a tiebreak.
struct RacketUnitScore: Equatable, Sendable {
    var scoreFor: Int
    var scoreAgainst: Int
    var tiebreakFor: Int?
    var tiebreakAgainst: Int?
    /// This unit was a deciding super tiebreak (its score IS the tiebreak points).
    var superTiebreak: Bool = false

    /// `nil` when level (an unfinished / mis-entered unit — counts for neither side).
    var won: Bool? {
        if scoreFor != scoreAgainst { return scoreFor > scoreAgainst }
        if let a = tiebreakFor, let b = tiebreakAgainst, a != b { return a > b }
        return nil
    }

    /// "11–7" · "6–4" · "7–6 (5)" (the loser's tiebreak points, the standard way) · "STB 10–8".
    var label: String {
        if superTiebreak { return "\(scoreFor)–\(scoreAgainst)" }
        var s = "\(scoreFor)–\(scoreAgainst)"
        if let a = tiebreakFor, let b = tiebreakAgainst {
            s += " (\(min(a, b)))"
        }
        return s
    }

    /// The long tiebreak form for the score sheet: "6–7 (5–7)".
    var longLabel: String {
        guard !superTiebreak, let a = tiebreakFor, let b = tiebreakAgainst else { return label }
        return "\(scoreFor)–\(scoreAgainst) (\(a)–\(b))"
    }
}

extension SetLog {
    /// The racket unit score this effort carries, or `nil` when it isn't a scored match unit.
    var racketScore: RacketUnitScore? {
        guard let f = scoreFor, let a = scoreAgainst else { return nil }
        return RacketUnitScore(scoreFor: f, scoreAgainst: a, tiebreakFor: tiebreakFor,
                               tiebreakAgainst: tiebreakAgainst, superTiebreak: superTiebreak ?? false)
    }
}

/// The verdict on an entered score. Never blocks saving.
enum RacketScoreCheck: Equatable, Sendable {
    /// A legal score; `won` is the user's result.
    case valid(won: Bool)
    /// Saveable, but not a complete unit under the rules (shown amber).
    case warning(String)

    var isValid: Bool { if case .valid = self { return true } else { return false } }
}

enum RacketScoring {

    // MARK: Rules

    /// Check one unit's score under the format's rules.
    static func check(_ score: RacketUnitScore, format: RacketFormat) -> RacketScoreCheck {
        if score.superTiebreak {
            return checkGame(score.scoreFor, score.scoreAgainst, to: 10, cap: nil, noun: "super tiebreak")
        }
        if format.sport.usesSets { return checkSet(score, gamesTo: format.pointsTo) }
        return checkGame(score.scoreFor, score.scoreAgainst, to: format.pointsTo, cap: format.sport.cap, noun: "game")
    }

    /// A points game: to `to`, win by 2, optionally capped (badminton: 30–29 wins).
    static func checkGame(_ a: Int, _ b: Int, to: Int, cap: Int?, noun: String = "game") -> RacketScoreCheck {
        guard a >= 0, b >= 0 else { return .warning("Scores can't be negative") }
        if a == b { return .warning("Level — someone has to win the \(noun)") }
        let hi = max(a, b), lo = min(a, b), won = a > b
        if let cap {
            if hi > cap { return .warning("Badminton games end at \(cap)") }
            if hi == cap { return lo >= cap - 2 ? .valid(won: won) : .warning("\(hi)–\(lo) isn't a finished \(noun)") }
        }
        if hi < to { return .warning("A \(noun) goes to \(to)") }
        if hi == to { return lo <= to - 2 ? .valid(won: won) : .warning("Win by 2 — keep playing past \(hi)–\(lo)") }
        // Past the target: deuce play ends exactly two clear.
        return hi - lo == 2 ? .valid(won: won) : .warning("After \(to - 1)–\(to - 1) it ends two clear")
    }

    /// A tennis / padel set: to `gamesTo` (6), win by 2, 7–5 legal, 7–6 needs a tiebreak to 7.
    static func checkSet(_ s: RacketUnitScore, gamesTo: Int) -> RacketScoreCheck {
        let a = s.scoreFor, b = s.scoreAgainst
        guard a >= 0, b >= 0 else { return .warning("Scores can't be negative") }
        if a == b { return .warning("Level — someone has to win the set") }
        let hi = max(a, b), lo = min(a, b), won = a > b
        if hi == gamesTo + 1 && lo == gamesTo {
            guard let ta = s.tiebreakFor, let tb = s.tiebreakAgainst else {
                return .warning("\(hi)–\(lo) — add the tiebreak score")
            }
            // The tiebreak must agree with the set and be a legal tiebreak to 7.
            if (ta > tb) != won { return .warning("The tiebreak winner should win the set") }
            if case .warning(let why) = checkGame(ta, tb, to: 7, cap: nil, noun: "tiebreak") { return .warning(why) }
            return .valid(won: won)
        }
        if hi == gamesTo { return lo <= gamesTo - 2 ? .valid(won: won) : .warning("\(hi)–\(lo) — a set is won by 2") }
        if hi == gamesTo + 1 && lo == gamesTo - 1 { return .valid(won: won) }
        if hi < gamesTo { return .warning("A set goes to \(gamesTo)") }
        return .warning("\(hi)–\(lo) isn't a finished set")
    }

    /// Does this set score need a tiebreak row (7–6 / 6–7)?
    static func needsTiebreak(_ a: Int, _ b: Int, gamesTo: Int) -> Bool {
        max(a, b) == gamesTo + 1 && min(a, b) == gamesTo
    }

    // MARK: Match state

    /// Everything the match page shows, derived from the logged units.
    struct MatchState: Equatable, Sendable {
        var won: Int
        var lost: Int
        /// The logged units in order (level units included — they show, but count for nobody).
        var units: [RacketUnitScore]
        /// `true` / `false` once decided; `nil` while in play (or for an open format).
        var result: Bool?
        /// How the match ended when not played out.
        var end: RacketMatchEnd?

        var isDecided: Bool { result != nil }
        /// "3–1" from the user's side.
        var scoreLabel: String { "\(won)–\(lost)" }
        /// "W 3–1" / "L 1–3" / "2–1" in play / "W ret." for a retirement.
        var shortResult: String {
            if let end, end == .walkoverWin { return "W w/o" }
            if let end, end == .walkoverLoss { return "L w/o" }
            guard let result else { return scoreLabel }
            return "\(result ? "W" : "L") \(scoreLabel)\(end != nil ? " ret." : "")"
        }
        var playedUnits: Int { units.count }
    }

    static func state(units: [RacketUnitScore], format: RacketFormat, end: RacketMatchEnd? = nil) -> MatchState {
        var won = 0, lost = 0
        for u in units {
            switch u.won { case true?: won += 1; case false?: lost += 1; case nil: break }
        }
        var result: Bool?
        if let end {
            result = end.won
        } else if let need = format.unitsToWin {
            if won >= need { result = true } else if lost >= need { result = false }
        }
        return MatchState(won: won, lost: lost, units: units, result: result, end: end)
    }

    /// Match point / set point for the next unit: winning it would decide the match, for either side.
    enum Pressure: Equatable, Sendable { case none, matchPointFor, matchPointAgainst, decider }

    static func pressure(_ s: MatchState, format: RacketFormat) -> Pressure {
        guard !s.isDecided, let need = format.unitsToWin else { return .none }
        let mine = s.won == need - 1, theirs = s.lost == need - 1
        if mine && theirs { return .decider }
        if mine { return .matchPointFor }
        if theirs { return .matchPointAgainst }
        return .none
    }

    // MARK: Score entry helpers

    /// The score sheet's starting values: the winning side's target already filled (11–0), so the usual
    /// entry is one tap on the loser's score. Sets start 6–0; a super tiebreak 10–0.
    static func initialScore(format: RacketFormat, superTiebreak: Bool) -> (Int, Int) {
        superTiebreak ? (10, 0) : (format.pointsTo, 0)
    }

    /// Common results as one-tap chips for the user's WIN (swap flips them).
    static func quickScores(format: RacketFormat, superTiebreak: Bool) -> [(Int, Int)] {
        if superTiebreak { return [(10, 6), (10, 8), (11, 9)] }
        if format.sport.usesSets { return [(6, 2), (6, 4), (7, 5), (7, 6)] }
        let t = format.pointsTo
        return [(t, t - 6), (t, t - 2), (t + 1, t - 1)]
    }

    /// Who won, in a sentence, for the score sheet: "you win game 4 · match 3–1".
    static func verdictLine(_ check: RacketScoreCheck, unitNumber: Int, unit: RacketUnit,
                            after: MatchState) -> String {
        switch check {
        case .warning(let why): return why
        case .valid(let won):
            var s = "\(won ? "You win" : "You lose") \(unit.noun) \(unitNumber)"
            if let r = after.result { s += " · match \(r ? "won" : "lost") \(after.scoreLabel)" }
            else { s += " · \(after.scoreLabel)" }
            return s
        }
    }

    // MARK: Totals

    /// Points (game sports) or games (set sports) for and against across the units.
    static func totals(_ units: [RacketUnitScore]) -> (forTotal: Int, against: Int) {
        units.reduce((0, 0)) { ($0.0 + $1.scoreFor, $0.1 + $1.scoreAgainst) }
    }

    /// Accuracy % for a made/tried drill block, or `nil` when nothing was tried.
    static func accuracy(made: Int?, tried: Int?) -> Double? {
        guard let made, let tried, tried > 0 else { return nil }
        return Double(min(made, tried)) / Double(tried)
    }
}

// MARK: - SessionExercise accessors

extension SessionExercise {
    /// The racket sport (a racket entity always has one; `nil` for every other discipline).
    var racketSport: RacketSport? { racketSportRaw.flatMap(RacketSport.init(rawValue:)) }
    var racketMode: RacketMode { racketModeRaw.flatMap(RacketMode.init(rawValue:)) ?? .match }
    var isRacketMatch: Bool { discipline == .racket && racketMode == .match }
    var isRacketDrill: Bool { discipline == .racket && racketMode == .drill }
    var racketEnd: RacketMatchEnd? { racketEndRaw.flatMap(RacketMatchEnd.init(rawValue:)) }
    var drillMeasure: RacketDrillMeasure { drillMeasureRaw.flatMap(RacketDrillMeasure.init(rawValue:)) ?? .time }
    var isDoubles: Bool { partner?.isEmpty == false }

    /// The match format (stored fields over the sport's defaults). `racketBestOf == 0` ⇒ open play.
    var racketFormat: RacketFormat {
        let sport = racketSport ?? .tableTennis
        let bestOf: Int? = racketBestOf.map { $0 > 0 ? $0 : nil } ?? sport.defaultBestOf
        return RacketFormat(sport: sport, bestOf: bestOf, pointsTo: racketPointsTo,
                            superTiebreak: racketSuperTiebreak ?? false)
    }

    /// The logged, scored units in order.
    var racketUnits: [RacketUnitScore] { sets.compactMap(\.racketScore) }

    /// The derived match state (score, result, pressure inputs).
    var racketState: RacketScoring.MatchState {
        RacketScoring.state(units: racketUnits, format: racketFormat, end: racketEnd)
    }

    /// "vs Alex Chen" / "You & Mia vs Jordan & Lee" — the match's headline.
    var racketMatchTitle: String {
        let opp = opponent?.isEmpty == false ? opponent! : "Opponent"
        if let partner, !partner.isEmpty { return "You & \(partner) vs \(opp)" }
        return "vs \(opp)"
    }
}

// MARK: - Tournament rounds

enum RacketRounds {
    /// The usual knockout ladder, earliest first.
    static let ladder = ["R128", "R64", "R32", "R16", "QF", "SF", "F"]

    /// The round after `round` for "Next match" ("R16" → "QF", "Group 1" → "Group 2"); `nil` when unknown.
    static func next(after round: String?) -> String? {
        guard let round = round?.trimmingCharacters(in: .whitespaces), !round.isEmpty else { return nil }
        if let i = ladder.firstIndex(where: { $0.caseInsensitiveCompare(round) == .orderedSame }) {
            return i + 1 < ladder.count ? ladder[i + 1] : nil
        }
        // A trailing number counts up ("Group 1" → "Group 2", "Round 3" → "Round 4").
        let digits = round.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(String(digits.reversed())) else { return nil }
        return String(round.dropLast(digits.count)) + "\(n + 1)"
    }
}

// MARK: - Suggested drills

/// A suggested practice drill for a sport — the drill picker's "Suggested" list.
struct RacketDrillSuggestion: Equatable, Sendable, Identifiable {
    var name: String
    var measure: RacketDrillMeasure
    var id: String { name }
}

enum RacketDrillCatalog {
    static func suggestions(for sport: RacketSport) -> [RacketDrillSuggestion] {
        func d(_ n: String, _ m: RacketDrillMeasure) -> RacketDrillSuggestion { .init(name: n, measure: m) }
        switch sport {
        case .tableTennis:
            return [d("Short backspin serve", .madeTried), d("Forehand loop vs block", .longestRally),
                    d("Falkenberg footwork", .time), d("Multiball — backhand flick", .madeTried),
                    d("Forehand–backhand switch", .longestRally), d("Shadow play", .time)]
        case .badminton:
            return [d("Low serve", .madeTried), d("Clears — length", .madeTried), d("Net kills", .madeTried),
                    d("Six-corner footwork", .time), d("Drive rally", .longestRally), d("Smash & defend", .time)]
        case .tennis:
            return [d("First serve in", .madeTried), d("Second serve kick", .madeTried),
                    d("Cross-court forehand rally", .longestRally), d("Backhand down the line", .madeTried),
                    d("Volley at the net", .longestRally), d("Split-step footwork", .time)]
        case .padel:
            return [d("Bandeja", .madeTried), d("Wall rebound (bajada)", .madeTried), d("Vibora", .madeTried),
                    d("Net volley rally", .longestRally), d("Lob & cover", .time)]
        case .pickleball:
            return [d("Third-shot drop", .madeTried), d("Dinking rally", .longestRally), d("Deep serve", .madeTried),
                    d("Reset from transition", .madeTried), d("Speed-up & counter", .time)]
        case .squash:
            return [d("Straight drive length", .madeTried), d("Boast–drive", .longestRally),
                    d("Ghosting", .time), d("Volley drop", .madeTried), d("Solo rally", .longestRally)]
        }
    }
}
