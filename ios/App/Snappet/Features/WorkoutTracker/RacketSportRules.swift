import Foundation

// MARK: - Sport-specific rules from the boards (prompt 252, issue #438 parity, the last batch) — pure
//
// PbScoring / PbSideOut (pickleball traditional side-out scoring and its "4–2–1" call), TnMatch "No-ad", TnServe (serve
// details), PdWall (did it bounce before the wall?), SqLet (let, stroke or no let), and the doubles serve lines that name
// the player ("Mia serving", "Mia serving, right court", "Mia, server 2"). The tally itself is `Shared/RacketLiveScore`
// (the Watch runs the same one); this file maps a match onto it and words the result. Foundation only; unit-tested in
// `RacketSportRulesTests`.

// MARK: - The tally rules for a unit

extension RacketServe.Side {
    var live: RacketLiveScore.Side { self == .us ? .us : .them }
    init(_ s: RacketLiveScore.Side) { self = s == .us ? .us : .them }
}

enum RacketSideOut {
    /// Who serves a side-out game's first rally. Game 1: who served first (you, when nobody said — the call needs a
    /// server); after that it alternates, the side that received first in a game serving first in the next.
    static func servesFirst(firstServer: RacketServe.Side?, unitIndex: Int) -> RacketLiveScore.Side {
        let first = (firstServer ?? .us).live
        return unitIndex % 2 == 0 ? first : first.other
    }
}

extension SessionExercise {
    /// The live tally rules for unit `unitIndex` of this match. `firstServer` overrides the stored "Who serves first?"
    /// (the warmup screen before it's saved).
    func racketLiveRules(unitIndex: Int, firstServer: RacketServe.Side?? = nil) -> RacketLiveRules {
        let first = firstServer ?? racketFirstServerRaw.flatMap(RacketServe.Side.init(rawValue:))
        return RacketLiveRules(format: racketFormat, unitIndex: unitIndex, firstServer: first, doubles: isDoubles)
    }

    /// Doubles: who serves first for your side (Warmup "Who serves first for us?").
    var racketOurFirstServer: RacketDoublesServe.Player? {
        racketOurFirstServerRaw.flatMap(RacketDoublesServe.Player.init(rawValue:))
    }
}

// MARK: - Who serves, by name (doubles)

/// The player serving within a side. The boards name your partner ("Mia serving"); the app knows a name only when you
/// said who serves first for your side (Warmup), and only while the rules fix the order: the whole match in tennis /
/// padel (a team keeps its order from set to set, as almost every team does), the first game in table tennis,
/// badminton and pickleball (the next game's first server is the serving side's free choice). The other side's players
/// are never named — Snappet doesn't know their order. Squash doubles names no one (its serving order isn't modelled).
enum RacketDoublesServe {
    enum Player: String, Codable, CaseIterable, Sendable {
        case you, partner
        var other: Player { self == .you ? .partner : .you }
    }

    enum Court: String, Sendable { case right, left }

    struct Info: Equatable, Sendable {
        var side: RacketServe.Side
        /// Your side only, when known.
        var player: Player?
        /// Badminton: the serving side's service court (even score ⇒ right).
        var court: Court?
        /// Pickleball side-out doubles: server 1 or 2.
        var serverNumber: Int?
    }

    /// Who serves the next point of unit `unitIndex`, given its points so far. `nil` when the side isn't known.
    static func info(sport: RacketSport, rules: RacketLiveRules, firstServer: RacketServe.Side?, ourFirst: Player?,
                     unitIndex: Int, previous: [RacketUnitScore], points: [RacketLiveScore.Side],
                     doubles: Bool) -> Info? {
        guard let side = RacketServe.server(sport: sport, firstServer: firstServer, unitIndex: unitIndex,
                                            previous: previous, points: points, rules: rules) else { return nil }
        var info = Info(side: side)
        let tally = RacketLiveScore(rules: rules, points: points).tally
        if rules.isSideOut, doubles { info.serverNumber = tally.serverNumber }
        if sport == .badminton, doubles {
            let s = side == .us ? tally.pointsFor : tally.pointsAgainst
            info.court = s % 2 == 0 ? .right : .left
        }
        guard doubles, side == .us, let ourFirst else { return info }
        switch sport {
        case .tennis, .padel:
            // The rotation A1 · B1 · A2 · B2: your side's k-th service game is your first server's when k is even.
            let r = RacketServe.tennisRotation(previous: previous, points: points, rules: rules)
            info.player = (r / 2) % 2 == 0 ? ourFirst : ourFirst.other
        case .tableTennis:
            guard unitIndex == 0, let firstServer else { break }
            // Service turns alternate sides; your side's turns alternate your two players.
            let j = RacketServe.turn(tableTennisPoints: points.count)
            let ours = firstServer == .us ? j / 2 : (j - 1) / 2
            info.player = ours % 2 == 0 ? ourFirst : ourFirst.other
        case .badminton:
            guard unitIndex == 0, let firstServer else { break }
            info.player = badmintonServer(firstServer: firstServer, ourFirst: ourFirst, points: points)
        case .pickleball:
            guard unitIndex == 0, rules.isSideOut else { break }
            info.player = pickleballServer(rules: rules, ourFirst: ourFirst, points: points)
        case .squash:
            break
        }
        return info
    }

    /// Badminton doubles: a side's players change service courts only when they win a rally as the serving side; a side
    /// that wins the serve back serves from the court of its score (even ⇒ right). Your first server is in the court
    /// your side serves from the first time it serves.
    static func badmintonServer(firstServer: RacketServe.Side, ourFirst: Player, points: [RacketLiveScore.Side]) -> Player? {
        var serving = firstServer
        var ours = 0
        // Who stands in your right court; known from your side's first serve.
        var right: Player? = firstServer == .us ? ourFirst : nil
        for w in points {
            let winner = RacketServe.Side(w)
            if winner == .us {
                ours += 1
                if serving == .us {
                    right = right?.other
                } else if right == nil {
                    right = ours % 2 == 0 ? ourFirst : ourFirst.other
                }
            }
            serving = winner
        }
        guard serving == .us, let right else { return nil }
        return ours % 2 == 0 ? right : right.other
    }

    /// Pickleball side-out doubles: your players swap sides each time your side scores, so the player on the right at
    /// your score s is your first server when s is even. Each time your side wins the serve, that player is server 1
    /// (at the game's start, the one server); server 2 is the partner.
    static func pickleballServer(rules: RacketLiveRules, ourFirst: Player, points: [RacketLiveScore.Side]) -> Player? {
        var serving = rules.servesFirst ?? .us
        var server = 2
        var firstOfHand = true
        var ours = 0
        var starter: Player? = serving == .us ? ourFirst : nil
        for w in points {
            if w == serving {
                if w == .us { ours += 1 }
            } else if server == 1 {
                server = 2
                firstOfHand = false
            } else {
                serving = serving.other
                server = 1
                firstOfHand = true
                if serving == .us { starter = ours % 2 == 0 ? ourFirst : ourFirst.other }
            }
        }
        guard serving == .us, let starter else { return nil }
        return firstOfHand ? starter : starter.other
    }
}

// MARK: - Copy

enum RacketServeCopy {
    /// A player's name on the serve lines: "You" / the partner's name.
    static func name(_ p: RacketDoublesServe.Player, partner: String?) -> String {
        p == .you ? "You" : ((partner?.isEmpty == false ? partner : nil) ?? "Partner")
    }

    /// Who, in words: your player by name when known, else the side ("Us" / "Them", "You" / "Alex").
    static func who(_ info: RacketDoublesServe.Info, partner: String?, sides: (us: String, them: String)) -> String {
        if let p = info.player { return name(p, partner: partner) }
        return info.side == .us ? sides.us : sides.them
    }

    /// "You’re serving" / "Mia serving" / "Alex serving".
    static func serving(_ who: String) -> String { who == "You" ? "You’re serving" : "\(who) serving" }

    /// The doubles tag line (DoublesTag "Mia serving", BdDoublesTag "Mia serving, right court", PbDoublesTag "Mia,
    /// server 2").
    static func doublesLine(_ info: RacketDoublesServe.Info, partner: String?, sides: (us: String, them: String)) -> String {
        let w = who(info, partner: partner, sides: sides)
        if let n = info.serverNumber { return "\(w), server \(n)" }
        if let c = info.court { return "\(serving(w)), \(c.rawValue) court" }
        return serving(w)
    }

    /// The game screen's caption for pickleball side-out (PbDimOff "Serving · server 1"); singles reads like the other
    /// rally sports ("Game 1 · you’re serving").
    static func sideOutCaption(_ tally: RacketLiveScore.Tally, unitTitle: String, them: String, doubles: Bool) -> String {
        guard let s = tally.serving else { return unitTitle }
        if doubles, let n = tally.serverNumber {
            return s == .us ? "Serving · server \(n)" : "\(them) serving · server \(n)"
        }
        return s == .us ? "\(unitTitle) · you’re serving" : "\(unitTitle) · \(them) serving"
    }

    /// PbSideOut's panel: "Server 1 lost the rally" / "No point. Your partner serves next." / "Side-out. They serve
    /// next." (singles: "You lost the serve" … "Side-out. Alex serves next.").
    static func sideOutPanel(_ c: RacketLiveScore.ServeChange, sides: (us: String, them: String),
                             doubles: Bool) -> (title: String, line: String) {
        let title: String
        if let n = c.serverNumber {
            title = c.side == .us ? "Server \(n) lost the rally" : "Their server \(n) lost the rally"
        } else {
            title = c.side == .us ? "You lost the rally on your serve" : "\(sides.them) lost the rally on their serve"
        }
        let line: String
        if !c.sideOut {
            line = c.side == .us ? "No point. Your partner serves next." : "No point. Their partner serves next."
        } else if c.side == .us {
            line = doubles ? "Side-out. They serve next." : "Side-out. \(sides.them) serves next."
        } else {
            line = doubles ? "Side-out. You serve next." : "Side-out. You serve next."
        }
        return (title, line)
    }

    static let sideOutFootnote = "At the start of a game, only one server serves before the first side-out."

    /// PbScoring's panel.
    static let scoreCallTitle = "Doubles score call: 4 – 2 – 1"
    static let scoreCallLine = "Serving score, receiving score, then server 1 or 2."
}

// MARK: - The tag sheet's score line per sport

enum RacketTagSportLine {
    /// Tennis / padel: "Games 4–3" · "Point 40–30" (TnTag / PdTag) — the set as your tags have it when this rally starts.
    /// A tiebreak reads "Tiebreak 5–4", a deciding super tiebreak "Match tiebreak 6–4".
    static func sets(rules: RacketLiveRules, points: [RacketLiveScore.Side]) -> (games: String, point: String) {
        let t = RacketLiveScore(rules: rules, points: points).tally
        if rules.superTiebreak { return ("Match tiebreak", "\(t.pointsFor)–\(t.pointsAgainst)") }
        let games = "Games \(t.result?.scoreFor ?? t.gamesFor)–\(t.result?.scoreAgainst ?? t.gamesAgainst)"
        if t.result != nil { return (games, "Set over") }
        if t.inTiebreak { return (games, "Tiebreak \(t.pointsFor)–\(t.pointsAgainst)") }
        return (games, "Point " + RacketLiveScore.tennisPoints(t.pointsFor, t.pointsAgainst).replacingOccurrences(of: " – ", with: "–"))
    }

    /// Pickleball side-out (PbTag "4–2–1 · Mia serving next"): the call and who serves next once you've picked this
    /// rally's winner; before that, the call and who serves this rally.
    static func pickleball(rules: RacketLiveRules, pointsBefore: [RacketLiveScore.Side], winner: RacketLiveScore.Side?,
                           ourFirst: RacketDoublesServe.Player?, unitIndex: Int, partner: String?,
                           sides: (us: String, them: String), doubles: Bool) -> (call: String, serve: String) {
        let pts = pointsBefore + (winner.map { [$0] } ?? [])
        let score = RacketLiveScore(rules: rules, points: pts)
        let call = score.isFinished ? score.display.replacingOccurrences(of: " – ", with: "–") : score.display
        guard let info = RacketDoublesServe.info(sport: .pickleball, rules: rules, firstServer: nil, ourFirst: ourFirst,
                                                 unitIndex: unitIndex, previous: [], points: pts, doubles: doubles),
              !score.isFinished else { return (call, score.isFinished ? "Game over" : "") }
        if doubles { return (call, RacketServeCopy.doublesLine(info, partner: partner, sides: sides)) }
        let w = RacketServeCopy.who(info, partner: partner, sides: sides)
        return (call, winner == nil ? RacketServeCopy.serving(w) : "\(w) serving next")
    }
}

// MARK: - TnServe: serve details

/// TnServe "How did the serve go?". Stored on the rally (`RacketRally.serveRaw`).
enum RacketServeOutcome: String, Codable, CaseIterable, Sendable {
    case firstIn, secondIn, doubleFault, ace, letReplay

    var label: String {
        switch self {
        case .firstIn: return "First serve in"
        case .secondIn: return "Second serve in"
        case .doubleFault: return "Double fault"
        case .ace: return "Ace"
        case .letReplay: return "Let, replay"
        }
    }

    static let footnote = "A first-serve fault doesn’t end the point. Only a double fault gives it away."

    /// What the serve says about the point: an ace wins it for the server, a double fault gives it to the returner, a
    /// let replays it (no winner). `nil` winner ⇒ the serve doesn't decide it. Unknown server ⇒ no winner implied.
    static func implied(_ o: RacketServeOutcome, server: RacketServe.Side?) -> (winner: RacketRallyWinner?, ending: RacketRallyEnding?) {
        switch o {
        case .ace: return (server.map { $0 == .us ? .us : .them }, .winner)
        case .doubleFault: return (server.map { $0 == .us ? .them : .us }, .doubleFault)
        case .letReplay: return (nil, .letReplay)
        case .firstIn, .secondIn: return (nil, nil)
        }
    }
}

// MARK: - PdWall: did it bounce before the wall?

/// PdWall "Did the ball bounce first?". Stored on the rally (`RacketRally.wallRaw`) and reflected in the ending chip.
enum RacketWallBounce: String, Codable, CaseIterable, Sendable {
    case bouncedThenWall, wallFirst, outOfCourt

    var title: String {
        switch self {
        case .bouncedThenWall: return "Bounced, then wall"
        case .wallFirst: return "Hit the wall before bouncing"
        case .outOfCourt: return "Went out of the court"
        }
    }

    var subtitle: String {
        switch self {
        case .bouncedThenWall: return "Still in play if returned in time"
        case .wallFirst: return "Point against the hitter"
        case .outOfCourt: return "Depends on local rules; tag who won"
        }
    }

    /// The ending chip it sets: wall first ⇒ "Hit wall first"; out of the court ⇒ "Out". "Bounced, then wall" is still
    /// in play, so it clears a "Hit wall first" picked before and leaves any other ending.
    static func ending(_ w: RacketWallBounce, current: RacketRallyEnding?) -> RacketRallyEnding? {
        switch w {
        case .wallFirst: return .hitWallFirst
        case .outOfCourt: return .out
        case .bouncedThenWall: return current == .hitWallFirst ? nil : current
        }
    }
}

// MARK: - SqLet: let, stroke or no let

/// SqLet "Was there interference?" — the decision is the ending chip itself (Let (replay) / Stroke / No let).
enum RacketLetCall: String, CaseIterable, Sendable {
    case letReplay, stroke, noLet

    var title: String {
        switch self {
        case .letReplay: return "Let"
        case .stroke: return "Stroke"
        case .noLet: return "No let"
        }
    }

    var subtitle: String {
        switch self {
        case .letReplay: return "Replay the rally"
        case .stroke: return "Point to the player who was blocked"
        case .noLet: return "Point to the other player"
        }
    }

    var ending: RacketRallyEnding {
        switch self {
        case .letReplay: return .letReplay
        case .stroke: return .stroke
        case .noLet: return .noLet
        }
    }

    init?(ending: RacketRallyEnding?) {
        switch ending {
        case .letReplay?: self = .letReplay
        case .stroke?: self = .stroke
        case .noLet?: self = .noLet
        default: return nil
        }
    }

    static let footnote = "Your tag decides how this rally scores. Snappet won’t judge this from video."
}

// MARK: - The tag sheet's sport link (TnTag "Serve details", PdTag "Did it bounce first?", SqTag "Let, stroke or no let")

enum RacketTagDetail: String, Identifiable, Sendable {
    case serve, wall, letCall
    var id: String { rawValue }

    static func link(for sport: RacketSport) -> RacketTagDetail? {
        switch sport {
        case .tennis: return .serve
        case .padel: return .wall
        case .squash: return .letCall
        default: return nil
        }
    }

    var linkTitle: String {
        switch self {
        case .serve: return "Serve details"
        case .wall: return "Did it bounce first?"
        case .letCall: return "Let, stroke or no let"
        }
    }
}
