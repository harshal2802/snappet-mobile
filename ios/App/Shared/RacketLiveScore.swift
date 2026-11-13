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
        /// pickleball rally scoring; pickleball's traditional side-out scoring sets `sideOut` (prompt 252).
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
    // Prompt 252 (PbScoring / PbSideOut) — optional on the wire, so an older Watch / phone decodes rally scoring.
    /// Pickleball "Traditional, side-out": only the serving side scores; the receiving side winning a rally takes the
    /// serve (after the second server in doubles).
    var sideOut: Bool?
    /// Side-out doubles: two servers per side ("4–2–1"), and the game's first side has one server only ("0–0–2").
    var doubles: Bool?
    /// Side-out: who serves this unit's first rally (`nil` read as us).
    var servesFirst: RacketLiveScore.Side?

    init(kind: Kind, pointsTo: Int, cap: Int? = nil, superTiebreak: Bool = false, goldenPoint: Bool = false,
         sideOut: Bool = false, doubles: Bool = false, servesFirst: RacketLiveScore.Side? = nil) {
        self.kind = kind
        self.pointsTo = max(1, pointsTo)
        self.cap = cap
        self.superTiebreak = kind == .sets && superTiebreak
        self.goldenPoint = kind == .sets && goldenPoint ? true : nil
        let so = kind == .rally && sideOut
        self.sideOut = so ? true : nil
        self.doubles = so && doubles ? true : nil
        self.servesFirst = so ? (servesFirst ?? .us) : nil
    }

    /// Only the serving side scores (pickleball traditional scoring).
    var isSideOut: Bool { sideOut == true }

    /// The score buttons (Watch, PbWatchMark): "You +1 / Alex +1"; side-out "We won / They won" (PbWatch) — a receiving
    /// win doesn't score, so it isn't "+1".
    func scoreButtons(us: String, them: String) -> (us: String, them: String) {
        guard isSideOut else { return ("\(us) +1", "\(them) +1") }
        return us == "Us" ? ("We won", "They won") : ("\(us) won", "\(them) won")
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
    enum Side: String, Codable, Sendable {
        case us, them
        var other: Side { self == .us ? .them : .us }
    }

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
        /// Side-out only: who serves the next rally, and (doubles) whether it's server 1 or 2.
        var serving: Side?
        var serverNumber: Int?
        /// Side-out only (PbSideOut): the serving side's losses since the last point scored, oldest first — "Server 1
        /// lost the rally" then "Server 2 lost the rally · Side-out". Starts over after a point or a side-out's next loss.
        var serveChanges: [ServeChange] = []
    }

    /// A rally the serving side lost under side-out scoring: no point, the next server or a side-out.
    struct ServeChange: Equatable, Sendable {
        /// The side that was serving and lost the rally.
        var side: Side
        /// Doubles: the server number that lost it (1 or 2); `nil` in singles.
        var serverNumber: Int?
        /// The serve went to the other side.
        var sideOut: Bool
        /// The call after it ("4 – 2 – 2").
        var callAfter: String
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
        if rules.isSideOut { return Self.call(t, doubles: rules.doubles == true, spaced: false) }
        if rules.kind == .rally || rules.superTiebreak || t.inTiebreak { return "\(t.pointsFor) – \(t.pointsAgainst)" }
        return Self.tennisPoints(t.pointsFor, t.pointsAgainst)
    }

    /// The line above it: "Game 1" · "Set 1 · Games 4–3" · "Set 1 · Tiebreak" · "Match tiebreak".
    func header(unitNumber: Int) -> String {
        switch rules.kind {
        case .rally:
            // PbWatch: "Game 1 · you serve".
            if rules.isSideOut, !isFinished, let s = tally.serving {
                return "Game \(unitNumber) · \(s == .us ? "you serve" : "they serve")"
            }
            return "Game \(unitNumber)"
        case .sets:
            if rules.superTiebreak { return "Match tiebreak" }
            let t = tally
            if t.result == nil && t.inTiebreak { return "Set \(unitNumber) · Tiebreak" }
            let gf = t.result?.scoreFor ?? t.gamesFor, ga = t.result?.scoreAgainst ?? t.gamesAgainst
            return "Set \(unitNumber) · Games \(gf)–\(ga)"
        }
    }

    /// The side-out call: the serving side's score first, then the receiving side's, then (doubles) the server number —
    /// "4–2–1" (PbDim, PbWatch, PbTag), spaced "4 – 2 – 2" on PbSideOut.
    static func call(_ t: Tally, doubles: Bool, spaced: Bool) -> String {
        let serving = t.serving ?? .us
        let a = serving == .us ? t.pointsFor : t.pointsAgainst
        let b = serving == .us ? t.pointsAgainst : t.pointsFor
        let parts = [a, b] + (doubles ? [t.serverNumber ?? 1] : [])
        return parts.map(String.init).joined(separator: spaced ? " – " : "–")
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
        if rules.isSideOut { return sideOutTally(points, rules) }
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

    /// Pickleball traditional scoring. `points` are the rally winners. The serving side winning scores and keeps the
    /// serve (same server); losing hands it to the second server (doubles, server 1 only) or to the other side
    /// (side-out, their server 1). The game's first serving side starts on server 2: one server before the first
    /// side-out. Only the serving side can reach the target, so a game ends on a serve: to `pointsTo`, win by 2.
    private static func sideOutTally(_ points: [Side], _ rules: RacketLiveRules) -> Tally {
        let doubles = rules.doubles == true
        var t = Tally()
        t.serving = rules.servesFirst ?? .us
        t.serverNumber = doubles ? 2 : nil
        for side in points {
            guard t.result == nil, let serving = t.serving else { break }
            if side == serving {
                if side == .us { t.pointsFor += 1 } else { t.pointsAgainst += 1 }
                t.serveChanges = []
                if gameWon(t.pointsFor, t.pointsAgainst, to: rules.pointsTo, cap: rules.cap) != nil {
                    t.result = .init(scoreFor: t.pointsFor, scoreAgainst: t.pointsAgainst)
                }
            } else {
                let lostBy = t.serverNumber
                let sideOut = !(doubles && t.serverNumber == 1)
                if sideOut {
                    t.serving = serving.other
                    t.serverNumber = doubles ? 1 : nil
                } else {
                    t.serverNumber = 2
                }
                if t.serveChanges.last?.sideOut == true { t.serveChanges = [] }
                t.serveChanges.append(.init(side: serving, serverNumber: lostBy, sideOut: sideOut,
                                            callAfter: call(t, doubles: doubles, spaced: true)))
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
