import Foundation

// MARK: - Live point-by-point score (prompt 245, issue #438 step 2) — pure, Shared/
//
// The Watch's "You +1 / Alex +1" tally for the unit being played (a game, or a tennis / padel set). Kept as the list
// of points won, in order: every number on screen is derived from it, so Undo is just "drop the last point" and can
// never leave the tally in a state the rules couldn't reach. Compiled into the phone and the Watch (project.yml
// Shared glob) so both apply a tap the same way; pinned in `SnappetTests` (`RacketWatchTests`).

/// The rules the tally needs: a wire copy of the phone's `RacketFormat` for ONE unit (Shared/ can't see the app's
/// racket types). The phone builds it (`RacketLiveRules(format:unitIndex:)` in `RacketWatchBridge.swift`).
struct RacketLiveRules: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Every rally scores: first to `pointsTo`, win by 2, up to `cap` (badminton 30). TT, badminton, squash,
        /// pickleball (rally scoring — side-out scoring isn't modelled yet).
        case rally
        /// Tennis / padel: points (15–30–40–Ad) make games, games make a set to `pointsTo` with a 7-point tiebreak at
        /// `pointsTo`–`pointsTo`; or a deciding super tiebreak to 10.
        case sets
    }

    var kind: Kind
    /// Rally: points to win the game. Sets: games to win the set.
    var pointsTo: Int
    /// Rally: the score that wins outright, whatever the margin (badminton 30–29).
    var cap: Int?
    /// Sets: this unit is the deciding super tiebreak (to 10, win by 2).
    var superTiebreak: Bool
    /// Padel "Golden point" (PdDeuce, prompt 249): at 40–40 the next point wins the game. Optional on the wire, so an
    /// older Watch / phone decodes it as Advantage.
    var goldenPoint: Bool?

    init(kind: Kind, pointsTo: Int, cap: Int? = nil, superTiebreak: Bool = false, goldenPoint: Bool = false) {
        self.kind = kind
        self.pointsTo = max(1, pointsTo)
        self.cap = cap
        self.superTiebreak = kind == .sets && superTiebreak
        self.goldenPoint = kind == .sets && goldenPoint ? true : nil
    }
}

/// A finished unit, in the phone's `SetLog` terms (points for a game; games + tiebreak for a set; tiebreak points
/// for a super tiebreak).
struct RacketLiveUnitResult: Codable, Equatable, Sendable {
    var scoreFor: Int
    var scoreAgainst: Int
    var tiebreakFor: Int?
    var tiebreakAgainst: Int?
    var superTiebreak: Bool = false

    var won: Bool { scoreFor != scoreAgainst ? scoreFor > scoreAgainst : (tiebreakFor ?? 0) > (tiebreakAgainst ?? 0) }

    /// "11–9" · "7–6".
    var label: String { "\(scoreFor)–\(scoreAgainst)" }
}

struct RacketLiveScore: Codable, Equatable, Sendable {
    enum Side: String, Codable, Sendable { case us, them }

    var rules: RacketLiveRules
    /// Every point won in this unit, in order. The only stored state.
    private(set) var points: [Side] = []

    init(rules: RacketLiveRules, points: [Side] = []) {
        self.rules = rules
        self.points = []
        for p in points { point(p) }
    }

    /// The derived position after all `points`.
    struct Tally: Equatable, Sendable {
        /// Points in the current game (rally: the game; sets: the current game, tiebreak or super tiebreak).
        var pointsFor = 0
        var pointsAgainst = 0
        /// Sets only: games in this set.
        var gamesFor = 0
        var gamesAgainst = 0
        /// Sets only: the current game is the set's tiebreak.
        var inTiebreak = false
        var result: RacketLiveUnitResult?
    }

    var tally: Tally { Self.tally(points, rules) }
    var isFinished: Bool { tally.result != nil }
    var result: RacketLiveUnitResult? { tally.result }
    var isEmpty: Bool { points.isEmpty }

    /// One point to `side`. `false` (and no change) once the unit is decided.
    @discardableResult
    mutating func point(_ side: Side) -> Bool {
        guard !isFinished else { return false }
        points.append(side)
        return true
    }

    /// Take back the last point. `false` when there's nothing to undo.
    @discardableResult
    mutating func undo() -> Bool {
        guard !points.isEmpty else { return false }
        points.removeLast()
        return true
    }

    // MARK: Display

    /// The big number: "4 – 3" · "40 – 30" · "Ad – 40" · a tiebreak's points · the final "11 – 9" / "6 – 4".
    var display: String {
        let t = tally
        if let r = t.result { return "\(r.scoreFor) – \(r.scoreAgainst)" }
        if rules.kind == .rally || rules.superTiebreak || t.inTiebreak { return "\(t.pointsFor) – \(t.pointsAgainst)" }
        return Self.tennisPoints(t.pointsFor, t.pointsAgainst)
    }

    /// The line above it: "Game 1" · "Set 1 · Games 4–3" · "Set 1 · Tiebreak" · "Match tiebreak".
    func header(unitNumber: Int) -> String {
        switch rules.kind {
        case .rally: return "Game \(unitNumber)"
        case .sets:
            if rules.superTiebreak { return "Match tiebreak" }
            let t = tally
            if t.result == nil && t.inTiebreak { return "Set \(unitNumber) · Tiebreak" }
            let gf = t.result?.scoreFor ?? t.gamesFor, ga = t.result?.scoreAgainst ?? t.gamesAgainst
            return "Set \(unitNumber) · Games \(gf)–\(ga)"
        }
    }

    /// "0, 15, 30, 40", deuce "40 – 40", advantage "Ad – 40" / "40 – Ad".
    static func tennisPoints(_ a: Int, _ b: Int) -> String {
        let names = ["0", "15", "30", "40"]
        if a >= 3 && b >= 3 {
            if a == b { return "40 – 40" }
            return a > b ? "Ad – 40" : "40 – Ad"
        }
        return "\(names[min(a, 3)]) – \(names[min(b, 3)])"
    }

    // MARK: Rules

    private static func tally(_ points: [Side], _ rules: RacketLiveRules) -> Tally {
        var t = Tally()
        for side in points {
            guard t.result == nil else { break }
            if side == .us { t.pointsFor += 1 } else { t.pointsAgainst += 1 }
            switch rules.kind {
            case .rally:
                if gameWon(t.pointsFor, t.pointsAgainst, to: rules.pointsTo, cap: rules.cap) != nil {
                    t.result = .init(scoreFor: t.pointsFor, scoreAgainst: t.pointsAgainst)
                }
            case .sets where rules.superTiebreak:
                if gameWon(t.pointsFor, t.pointsAgainst, to: 10, cap: nil) != nil {
                    t.result = .init(scoreFor: t.pointsFor, scoreAgainst: t.pointsAgainst, superTiebreak: true)
                }
            case .sets:
                if t.inTiebreak {
                    guard let usWon = gameWon(t.pointsFor, t.pointsAgainst, to: 7, cap: nil) else { continue }
                    let tbFor = t.pointsFor, tbAgainst = t.pointsAgainst
                    if usWon { t.gamesFor += 1 } else { t.gamesAgainst += 1 }
                    t.result = .init(scoreFor: t.gamesFor, scoreAgainst: t.gamesAgainst,
                                     tiebreakFor: tbFor, tiebreakAgainst: tbAgainst)
                } else {
                    // Golden point: from 40–40 (3–3) the next point decides the game.
                    let golden = rules.goldenPoint == true && t.pointsFor >= 3 && t.pointsAgainst >= 3
                        && t.pointsFor != t.pointsAgainst
                    guard let usWon = golden ? t.pointsFor > t.pointsAgainst
                            : gameWon(t.pointsFor, t.pointsAgainst, to: 4, cap: nil) else { continue }
                    if usWon { t.gamesFor += 1 } else { t.gamesAgainst += 1 }
                    t.pointsFor = 0
                    t.pointsAgainst = 0
                    let to = rules.pointsTo
                    if max(t.gamesFor, t.gamesAgainst) >= to && abs(t.gamesFor - t.gamesAgainst) >= 2 {
                        t.result = .init(scoreFor: t.gamesFor, scoreAgainst: t.gamesAgainst)
                    } else if t.gamesFor == to && t.gamesAgainst == to {
                        t.inTiebreak = true
                    }
                }
            }
        }
        return t
    }

    /// `true` us, `false` them, `nil` not yet: first to `to`, win by 2, or reaching `cap` outright.
    private static func gameWon(_ a: Int, _ b: Int, to: Int, cap: Int?) -> Bool? {
        if let cap {
            if a >= cap { return true }
            if b >= cap { return false }
        }
        if a >= to && a - b >= 2 { return true }
        if b >= to && b - a >= 2 { return false }
        return nil
    }
}
