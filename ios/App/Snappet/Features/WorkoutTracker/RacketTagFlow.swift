import Foundation

// MARK: - Tagging parity (prompt 251, issue #438) — pure
//
// The rules sheet (RallyRules / XxRules), FixRally's "What went wrong?", shot-by-shot tagging by hand (ShotTags /
// DoublesShots), the tag sheet's running score and serve line (QuickTag / DoublesTag), LiveTag's "last rally" range
// from the recording screen, Timeline's "+ Add a missed rally", and game-by-game clips adopted as a recording log.
// Tested in `RacketTagFlowTests`. Nothing here uses a model: every number is from your marks, taps and tags.

// MARK: - What counts as a rally (RallyRules / XxRules)

enum RacketRallyRules {
    struct Row: Equatable, Sendable {
        var what: String
        var result: String
    }

    struct Sheet: Equatable, Sendable {
        var intro: String
        var rows: [Row]
        var footer: String
    }

    /// Copied from the boards, in their order.
    static func sheet(for sport: RacketSport) -> Sheet {
        func r(_ a: String, _ b: String) -> Row { Row(what: a, result: b) }
        switch sport {
        case .tableTennis:
            return Sheet(intro: "A rally starts with the serve and ends when the point is decided or replayed.",
                         rows: [r("Ball misses the table", "Point to opponent"), r("Ball stops in the net", "Point to opponent"),
                                r("Two bounces on one side", "Point to hitter"), r("Serve fault", "Point to receiver"),
                                r("Missed swing", "Point to opponent"), r("Edge ball, hits table top", "Point to hitter"),
                                r("Let on serve", "Replay, no point"), r("Ball from another table", "Replay, no point"),
                                r("Picking up the ball, knocking", "Not a rally")],
                         footer: "Snappet may miss these on video. Your tag always wins.")
        case .badminton:
            return Sheet(intro: "A rally starts with the serve and ends when the shuttle lands or play is called. Every rally scores unless it’s a let.",
                         rows: [r("Shuttle lands in", "Point to hitter"), r("Shuttle lands out", "Point to opponent"),
                                r("Shuttle in the net", "Point to opponent"), r("Service fault", "Point to receiver"),
                                r("Missed shot", "Point to opponent"), r("Shuttle hits a player", "Point to other side"),
                                r("Let", "Replay, no point"), r("Shuttle from another court", "Replay, no point"),
                                r("Picking up the shuttle", "Not a rally")],
                         footer: "The rally winner serves next. Your tag always wins.")
        case .tennis:
            return Sheet(intro: "A rally starts with a serve that lands in and ends when the point is decided. A fault alone doesn’t end the point.",
                         rows: [r("First-serve fault", "Second serve"), r("Double fault", "Point to returner"),
                                r("Let on serve", "Replay that serve"), r("Ball lands out", "Point to opponent"),
                                r("Ball in the net", "Point to opponent"), r("Two bounces", "Point to hitter"),
                                r("Interrupted", "Replay the point")],
                         footer: "Points become games, and games become sets. Changeovers aren’t tracked; recording keeps going. Your tag always wins.")
        case .pickleball:
            return Sheet(intro: "A rally starts with the serve. In traditional scoring, it only earns a point for the serving side.",
                         rows: [r("Serving side wins", "Point to server"), r("Receiving side wins", "No point: next server, or side-out"),
                                r("Rally scoring picked", "Every rally scores"), r("Ball lands out", "Rally to opponent"),
                                r("Ball in the net", "Rally to opponent"), r("Volley from the kitchen", "Rally to opponent"),
                                r("Broke two-bounce rule", "Rally to opponent"), r("Ball from another court", "Replay")],
                         footer: "Local rules vary. Your tag always wins.")
        case .padel:
            return Sheet(intro: "A rally starts with an underhand serve. The ball must bounce before touching the walls, then walls stay in play.",
                         rows: [r("First-serve fault", "Second serve"), r("Double fault", "Point to returners"),
                                r("Hit wall before bouncing", "Point against hitter"), r("Bounced, then wall", "Still in play"),
                                r("Two bounces", "Point to hitter"), r("Ball in the net", "Point to opponents"),
                                r("Let on serve", "Replay that serve")],
                         footer: "Formats vary by club. Changeovers aren’t tracked; recording keeps going. Your tag always wins.")
        case .squash:
            return Sheet(intro: "A rally starts with the serve. It usually scores unless it’s called a let.",
                         rows: [r("Ball hits the tin", "Point to opponent"), r("Ball hits above the out line", "Point to opponent"),
                                r("Two bounces, not up", "Point to hitter"), r("Service fault", "Point to receiver"),
                                r("Let", "Replay, no point"), r("Stroke", "Point to blocked player"),
                                r("No let", "Point to other player")],
                         footer: "Your tag always wins. Snappet won’t judge interference.")
        }
    }
}

// MARK: - FixRally "What went wrong? Optional"

enum RacketFixReason: String, Codable, CaseIterable, Sendable {
    case startedLate, endedEarly, wrongCourt, pickup

    /// XxFix chips: table tennis says "Wrong table"; badminton picks up a shuttle.
    func label(_ sport: RacketSport) -> String {
        switch self {
        case .startedLate: return "Started late"
        case .endedEarly: return "Ended early"
        case .wrongCourt: return sport == .tableTennis ? "Wrong table" : "Wrong court"
        case .pickup: return sport == .badminton ? "Shuttle pickup" : "Ball pickup"
        }
    }

    /// Toggle one reason in a stored list (nil when empty, so an untouched rally stays nil).
    static func toggled(_ raw: [String]?, _ r: RacketFixReason) -> [String]? {
        var set = raw ?? []
        if let i = set.firstIndex(of: r.rawValue) { set.remove(at: i) } else { set.append(r.rawValue) }
        let ordered = allCases.map(\.rawValue).filter(set.contains)
        return ordered.isEmpty ? nil : ordered
    }
}

// MARK: - Shot by shot (ShotTags / DoublesShots), by hand

/// One shot of a rally. Singles: `side` is enough ("You" / "Alex"); doubles may name the player (optional).
struct RacketShot: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// `RacketRallyWinner.rawValue` of the side that hit it ("us" / "them").
    var sideRaw: String
    /// Doubles: who hit it ("You", "Mia", a player of theirs); nil = not named ("Player?").
    var player: String?
    /// "fh" / "bh".
    var handRaw: String
    /// `RacketShotType` label for the sport ("Serve", "Push", …); nil = not chosen yet.
    var type: String?

    var side: RacketRallyWinner { RacketRallyWinner(rawValue: sideRaw) ?? .us }
    var isBackhand: Bool { handRaw == "bh" }
    var handLabel: String { isBackhand ? "BH" : "FH" }
}

enum RacketShotType {
    /// The shot names on each sport's Shots / DoublesShots boards (union, in a playing order), then "Other".
    static func choices(for sport: RacketSport) -> [String] {
        switch sport {
        case .tableTennis: return ["Serve", "Push", "Topspin", "Block", "Smash", "Other"]
        case .badminton: return ["Serve", "Clear", "Drop", "Smash", "Drive", "Lift", "Net shot", "Push", "Block", "Other"]
        case .tennis: return ["Serve", "Return", "Drive", "Slice", "Volley", "Lob", "Drop", "Smash", "Other"]
        case .pickleball: return ["Serve", "Return", "Third-shot drop", "Dink", "Drive", "Volley", "Lob", "Reset", "Smash", "Other"]
        case .padel: return ["Serve", "Return", "Volley", "Bandeja", "Vibora", "Lob", "Smash", "Bajada", "Wall return", "Other"]
        case .squash: return ["Serve", "Return", "Drive", "Cross-court", "Boast", "Drop", "Volley", "Lob", "Other"]
        }
    }
}

enum RacketShotTagging {
    /// "+ Add a shot": the next shot is the other side's (rallies alternate); the first is a serve by `firstSide`.
    static func adding(to shots: [RacketShot], firstSide: RacketRallyWinner = .us) -> [RacketShot] {
        let side: RacketRallyWinner = shots.last.map { $0.side == .us ? .them : .us } ?? firstSide
        return shots + [RacketShot(sideRaw: side.rawValue, player: nil, handRaw: "fh", type: shots.isEmpty ? "Serve" : nil)]
    }

    /// Tap the side: swap it (the rest stay as they are).
    static func swapSide(_ shots: [RacketShot], id: UUID) -> [RacketShot] {
        shots.map { s in
            guard s.id == id else { return s }
            var q = s
            q.sideRaw = s.side == .us ? RacketRallyWinner.them.rawValue : RacketRallyWinner.us.rawValue
            q.player = nil
            return q
        }
    }

    static func toggleHand(_ shots: [RacketShot], id: UUID) -> [RacketShot] {
        shots.map { s in guard s.id == id else { return s }; var q = s; q.handRaw = s.isBackhand ? "fh" : "bh"; return q }
    }

    static func setType(_ shots: [RacketShot], id: UUID, type: String?) -> [RacketShot] {
        shots.map { s in guard s.id == id else { return s }; var q = s; q.type = type; return q }
    }

    static func setPlayer(_ shots: [RacketShot], id: UUID, player: String?) -> [RacketShot] {
        shots.map { s in guard s.id == id else { return s }; var q = s; q.player = player; return q }
    }

    static func remove(_ shots: [RacketShot], id: UUID) -> [RacketShot] { shots.filter { $0.id != id } }

    /// Doubles players on a side: ours are you + partner, theirs the opponents' players.
    static func players(side: RacketRallyWinner, partner: String?, opponents: [String]) -> [String] {
        side == .us ? ["You"] + [partner].compactMap { $0?.isEmpty == false ? $0 : nil } : opponents
    }

    /// The rally's shots for saving: nil when there are none (so an untouched rally stays nil).
    static func stored(_ shots: [RacketShot]) -> [RacketShot]? { shots.isEmpty ? nil : shots }

    /// The first rally of a part with no shots tagged ("Tag every shot" starts there), else the first rally.
    static func firstToTag(_ rallies: [RacketRally]) -> RacketRally? {
        let rs = rallies.filter(\.isRally).sorted { $0.startSec < $1.startSec }
        return rs.first { ($0.shots ?? []).isEmpty } ?? rs.first
    }
}

// MARK: - The tag sheet's score and serve lines (QuickTag · DoublesTag)

enum RacketTagScore {
    /// "So far 6–5": your tagged winners before this rally in the part.
    static func soFar(before id: UUID, in rallies: [RacketRally]) -> (us: Int, them: Int) {
        let rs = rallies.filter(\.isRally).sorted { $0.startSec < $1.startSec }
        guard let i = rs.firstIndex(where: { $0.id == id }) else { return (0, 0) }
        return RacketPlaybackPolicy.runningScore(through: i, in: rs)
    }

    /// The winners before this rally, as the serve rules read points.
    static func points(before id: UUID, in rallies: [RacketRally]) -> [RacketLiveScore.Side] {
        let rs = rallies.filter(\.isRally).sorted { $0.startSec < $1.startSec }
        guard let i = rs.firstIndex(where: { $0.id == id }) else { return [] }
        return rs.prefix(i).compactMap { r in r.winner.map { $0 == .us ? .us : .them } }
    }

    /// DoublesTag's serve line: "Us serving" from who served first and your tags so far; nil when not known.
    static func servingLine(sport: RacketSport, firstServer: RacketServe.Side?, unitIndex: Int?,
                            previous: [RacketUnitScore], rallyID: UUID, rallies: [RacketRally],
                            sides: (us: String, them: String)) -> String? {
        guard let firstServer, let unitIndex else { return nil }
        let pts = points(before: rallyID, in: rallies)
        guard let s = RacketServe.server(sport: sport, firstServer: firstServer, unitIndex: unitIndex,
                                         previous: Array(previous.prefix(unitIndex)), points: pts) else { return nil }
        return "\(s == .us ? sides.us : sides.them) serving"
    }
}

// MARK: - LiveTag: the last rally, tagged right after it on the recording screen

enum RacketLiveTag {
    /// No live rally finding: the last rally is the stretch since the previous score tap / tagged rally (or the game's
    /// start), at most `maxSec` long and at least `minSec`.
    static let maxSec: Double = 20
    static let minSec: Double = 2

    static func range(now t: Double, since boundary: Double?) -> ClosedRange<Double> {
        let start = max(0, max(boundary ?? 0, t - maxSec))
        return min(start, max(0, t - minSec))...t
    }

    /// The boundary: the latest score tap, tagged rally end or game start before `t`.
    static func boundary(log: RacketRecordingLog, before t: Double) -> Double? {
        let taps = log.marks.filter { $0.kind == .point || $0.kind == .firstPoint || $0.kind == .newGame }.map(\.startSec)
        let games = log.marks.filter { $0.kind == .game }.map(\.startSec)
        let ends = log.allRallies.map(\.endSec)
        return (taps + games + ends).filter { $0 < t - 0.25 }.max()
    }

    /// "Rally 7 ended": the number this rally gets among the recording's rallies.
    static func number(of range: ClosedRange<Double>, in rallies: [RacketRally]) -> Int {
        rallies.filter { $0.isRally && $0.startSec < range.lowerBound }.count + 1
    }

    /// Save the tagged rally (or "Not a rally") onto the recording's rallies, trimming any overlap with the one before.
    static func add(_ rallies: [RacketRally], range: ClosedRange<Double>, winner: RacketRallyWinner?,
                    ending: RacketRallyEnding?, notRally: Bool) -> [RacketRally] {
        var a = range.lowerBound
        if let prev = rallies.filter({ $0.startSec < range.upperBound }).map(\.endSec).filter({ $0 > a }).max() { a = prev }
        guard range.upperBound - a >= RacketRallyMarking.minRallySec else { return rallies }
        var r = RacketRally(startSec: a, endSec: range.upperBound, winner: notRally ? nil : winner,
                            ending: notRally ? nil : ending, notRally: notRally ? true : nil)
        r.sourceRaw = nil
        return RacketRallyMarking.insert(r, into: rallies)
    }
}

// MARK: - Timeline "+ Add a missed rally" (FixRally in add mode)

enum RacketMissedRally {
    static let defaultSec: Double = 6

    /// A new rally at the playhead, `defaultSec` long, clamped to the part and shortened to fit before the next rally;
    /// nil when the playhead is inside a rally or there's no room.
    static func make(at t: Double, within lo: Double, _ hi: Double, existing: [RacketRally]) -> RacketRally? {
        let a = min(max(lo, t), hi)
        if existing.contains(where: { a >= $0.startSec - 0.01 && a < $0.endSec }) { return nil }
        let next = existing.map(\.startSec).filter { $0 > a }.min() ?? hi
        let b = min(hi, next, a + defaultSec)
        guard b - a >= RacketRallyMarking.minRallySec else { return nil }
        return RacketRally(startSec: a, endSec: b)
    }
}

// MARK: - Game-by-game clips (prompt 203's per-game camera) as a recording log

enum RacketClipAdoption {
    struct Clip: Equatable, Sendable {
        var localIdentifier: String
        /// Seconds from the session's start when it began.
        var offsetSec: Double
        var durationSec: Double
        /// The game / block it was filmed for.
        var unitIndex: Int?
    }

    /// One log over the clips, in time order: each clip an asset and a run; for a match a `game` mark per clip that
    /// belongs to a game, for a drill a `block` mark; the game-by-game split applied. nil with no usable clip.
    static func log(_ clips: [Clip], sessionStart: Date, drill: Bool, now: Date) -> RacketRecordingLog? {
        let cs = clips.filter { $0.durationSec > 0.5 }.sorted { $0.offsetSec < $1.offsetSec }
        guard let first = cs.first else { return nil }
        var log = RacketRecordingLog(startedAt: sessionStart.addingTimeInterval(first.offsetSec))
        log.modeRaw = RacketRecordingMode.byUnit.rawValue
        var cursor = 0.0
        for c in cs {
            let start = max(cursor, c.offsetSec - first.offsetSec)
            let end = start + c.durationSec
            log.assets.append(.init(localIdentifier: c.localIdentifier, startSec: start, durationSec: c.durationSec))
            log.runs.append(.init(startSec: start, endSec: end))
            if let i = c.unitIndex {
                log.marks.append(.init(kindRaw: (drill ? RacketRecordingLog.MarkKind.block : .game).rawValue,
                                       index: i, startSec: start, endSec: end))
            }
            cursor = end
        }
        log.endedAt = log.startedAt.addingTimeInterval(cursor)
        if !drill { log.split = RacketGameByGameSplit.split(log, now: now) }
        return log
    }
}

// MARK: - Your videos: a send waiting for its reply (FindRallies "Sent to ChatGPT")

enum RacketAIWaiting {
    /// The latest send of this part with no reply brought back from that app since.
    static func request(_ log: RacketRecordingLog, partStart: Double, partEnd: Double) -> RacketAIRequest? {
        let overlaps: (Double, Double) -> Bool = { a, b in a < partEnd - 0.01 && b > partStart + 0.01 }
        guard let req = log.allAIRequests.filter({ overlaps($0.partStart, $0.partEnd) }).max(by: { $0.sentAt < $1.sentAt })
        else { return nil }
        let replied = log.allAIImports.contains {
            overlaps($0.partStart, $0.partEnd) && $0.importedAt >= req.sentAt && ($0.appRaw == req.appRaw || req.app == .other)
        }
        return replied ? nil : req
    }

    /// "Sent to ChatGPT" · "Sent Oct 28. Bring its reply back when it's ready."
    static func lines(_ req: RacketAIRequest) -> (title: String, detail: String) {
        ("Sent to \(req.app.name)",
         "Sent \(req.sentAt.formatted(.dateTime.month(.abbreviated).day())). Bring its reply back when it’s ready.")
    }
}

// MARK: - SplitPhotos: a video from Photos (the Camera app) added to a match or drill

enum RacketPhotosImport {
    struct Unit: Equatable, Sendable {
        var index: Int
        var completedAt: Date?
        var durationSec: Double?
    }

    /// The video lines up with the session when they overlap, give or take an hour.
    static func linesUp(videoStart: Date, durationSec: Double, sessionStart: Date, sessionEnd: Date?) -> Bool {
        let vEnd = videoStart.addingTimeInterval(durationSec)
        let sEnd = sessionEnd ?? sessionStart.addingTimeInterval(4 * 3600)
        return videoStart < sEnd.addingTimeInterval(3600) && vEnd > sessionStart.addingTimeInterval(-3600)
    }

    /// A recording log over one Photos video. "Find games and drills" reads the games / blocks you logged (their end
    /// time and length) and places them on the video: a match gets New game / first point / break marks for the split
    /// proposal, a drill gets block marks. With nothing to place, the split proposes one stretch you fix by hand.
    static func log(assetID: String, videoStart: Date, durationSec: Double, units: [Unit], drill: Bool,
                    findParts: Bool) -> RacketRecordingLog {
        var log = RacketRecordingLog(startedAt: videoStart)
        log.assets = [.init(localIdentifier: assetID, startSec: 0, durationSec: durationSec)]
        log.runs = [.init(startSec: 0, endSec: durationSec)]
        log.endedAt = videoStart.addingTimeInterval(durationSec)
        log.baseSetIndex = 0
        if !findParts { log.keptAsOne = drill ? nil : true; return log }
        for u in units.sorted(by: { $0.index < $1.index }) {
            guard let done = u.completedAt, let len = u.durationSec, len > 0 else { continue }
            let end = done.timeIntervalSince(videoStart)
            let start = end - len
            guard end > 1, start < durationSec - 1 else { continue }
            let a = max(0, start), b = min(durationSec, end)
            if drill {
                log.marks.append(.init(kindRaw: RacketRecordingLog.MarkKind.block.rawValue, index: u.index, startSec: a, endSec: b))
            } else {
                if a > 5 { log.marks.append(.init(kindRaw: RacketRecordingLog.MarkKind.newGame.rawValue, startSec: a)) }
                log.marks.append(.init(kindRaw: RacketRecordingLog.MarkKind.firstPoint.rawValue, startSec: min(b, a + 15)))
                if b < durationSec - 5 {
                    log.marks.append(.init(kindRaw: RacketRecordingLog.MarkKind.breakStart.rawValue, startSec: b))
                }
            }
        }
        log.marks.sort { $0.startSec < $1.startSec }
        return log
    }
}
