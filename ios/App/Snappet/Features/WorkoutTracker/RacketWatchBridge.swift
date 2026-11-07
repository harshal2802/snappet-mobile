import Foundation

// MARK: - Racket on the Watch, phone side (prompt 245, issue #438 step 2) — pure
//
// Maps the phone's racket state onto the Watch wire (`Shared/RacketWatchMessage.swift`) and the Watch's taps back onto
// it: the record-everything machine (`RacketRecordingMachine`, step 1) for the recording screen, and
// `RacketWatchMatch` for a game-by-game match on the pager's match page. Foundation only; the WatchConnectivity edge is
// `Services/RacketWatchRelay.swift`. Tested in `RacketWatchTests`.

// MARK: - Rules, sides, copy

extension RacketLiveRules {
    /// The tally rules for unit `unitIndex` (0-based) of a match in `format`.
    init(format: RacketFormat, unitIndex: Int) {
        if format.sport.usesSets {
            self.init(kind: .sets, pointsTo: format.pointsTo, superTiebreak: format.isSuperTiebreak(index: unitIndex))
        } else {
            self.init(kind: .rally, pointsTo: format.pointsTo, cap: format.sport.cap)
        }
    }
}

extension RacketLiveUnitResult {
    var unitScore: RacketUnitScore {
        RacketUnitScore(scoreFor: scoreFor, scoreAgainst: scoreAgainst, tiebreakFor: tiebreakFor,
                        tiebreakAgainst: tiebreakAgainst, superTiebreak: superTiebreak)
    }
}

extension RacketLiveScore {
    /// What "End game" logs: the decided result, or — ended early — where the tally stands (points for a game, games
    /// for a set). The phone's score check warns on an unfinished one; it still saves (prompt 203).
    var provisionalResult: RacketLiveUnitResult {
        if let result { return result }
        let t = tally
        if rules.kind == .rally || rules.superTiebreak {
            return .init(scoreFor: t.pointsFor, scoreAgainst: t.pointsAgainst, superTiebreak: rules.superTiebreak)
        }
        return .init(scoreFor: t.gamesFor, scoreAgainst: t.gamesAgainst)
    }
}

extension SetLog {
    /// A unit tallied on the Watch: its score, counted, marked "from Watch" until confirmed on the phone.
    init(watchResult r: RacketLiveUnitResult, durationSec: TimeInterval?) {
        self.init()
        scoreFor = r.scoreFor
        scoreAgainst = r.scoreAgainst
        tiebreakFor = r.tiebreakFor
        tiebreakAgainst = r.tiebreakAgainst
        superTiebreak = r.superTiebreak ? true : nil
        scoreFromWatch = true
        self.durationSec = durationSec
    }
}

/// What the Watch needs to know about the match / drill beyond its phase.
struct RacketWatchContext: Equatable, Sendable {
    var sessionID: UUID
    var sport: RacketSport
    var sideUs: String
    var sideThem: String
    /// The unit being played (1-based).
    var unitNumber: Int
    /// "Games 1–0" once a unit is logged; "Won 3–1" once decided.
    var matchLine: String?
    var drillTitle: String?

    init(sessionID: UUID, sport: RacketSport, sideUs: String, sideThem: String, unitNumber: Int,
         matchLine: String? = nil, drillTitle: String? = nil) {
        self.sessionID = sessionID
        self.sport = sport
        self.sideUs = sideUs
        self.sideThem = sideThem
        self.unitNumber = unitNumber
        self.matchLine = matchLine
        self.drillTitle = drillTitle
    }

    init(_ ex: SessionExercise) {
        let sides = RacketWatchCopy.sides(opponent: ex.opponent, doubles: ex.isDoubles)
        let state = ex.racketState
        let sport = ex.racketSport ?? .tableTennis
        self.init(sessionID: ex.id, sport: sport, sideUs: sides.us, sideThem: sides.them,
                  unitNumber: ex.sets.count + 1,
                  matchLine: ex.isRacketMatch ? RacketWatchCopy.matchLine(state, unit: sport.unit) : nil,
                  drillTitle: ex.isRacketDrill ? ex.displayName : nil)
    }
}

enum RacketWatchCopy {
    /// The score buttons' names: "You" / "Alex" in singles, "Us" / "Them" in doubles (boards: XxWatch).
    static func sides(opponent: String?, doubles: Bool) -> (us: String, them: String) {
        if doubles { return ("Us", "Them") }
        let first = opponent?.split(separator: " ").first.map(String.init)
        return ("You", (first?.isEmpty == false ? first : nil) ?? "Them")
    }

    /// The line under the Watch score (boards' `wnote`; table tennis's rally tag and serve tracking come later).
    static func note(_ sport: RacketSport) -> String {
        switch sport {
        case .tableTennis: return "Tap who won each point."
        case .badminton: return "The rally winner serves next"
        case .tennis, .padel: return "Tap for the point winner"
        case .squash: return "Every rally scores unless it’s a let"
        case .pickleball: return "Every rally scores"
        }
    }

    /// "Games 2–1" while playing, "Won 3–1" / "Lost 1–3" once decided; nil before the first unit.
    static func matchLine(_ s: RacketScoring.MatchState, unit: RacketUnit) -> String? {
        guard s.playedUnits > 0 || s.end != nil else { return nil }
        if let won = s.result { return "\(won ? "Won" : "Lost") \(s.scoreLabel)" }
        return "\(unit.noun.capitalized)s \(s.scoreLabel)"
    }

    static let cameraFootnote = "Snappet must be open on the phone’s camera screen."
}

// MARK: - The recording screen (record everything) ↔ Watch

enum RacketWatchBridge {
    /// The Watch's view of the record-everything screen. `revision` is stamped by the relay.
    static func coverState(_ m: RacketRecordingMachine, context c: RacketWatchContext, score: RacketLiveScore,
                           now: Date) -> RacketWatchState {
        let blocks = m.plan?.blocks ?? 1
        let surface: RacketWatchState.Surface
        switch m.phase {
        case .ready:
            surface = .start(.init(title: "Start block \((m.log?.blockMarks.count ?? 0) + 1)?", cameraReady: true,
                                   footnote: RacketWatchCopy.cameraFootnote))
        case .recordingMatch:
            surface = .marks(.init(clock: recordedClock(m), unitNumber: c.unitNumber, score: score,
                                   matchLine: c.matchLine, markCount: m.log?.userMarkCount ?? 0))
        case .countdown(let b, let endsAt):
            surface = .countdown(.init(block: b, blocks: blocks, endsAt: endsAt,
                                       totalSec: TimeInterval(m.plan?.countdownSec ?? 5)))
        case .block(let b, let startedAt):
            surface = .block(.init(index: b, blocks: blocks, startedAt: startedAt,
                                   totalSec: TimeInterval(m.plan?.blockSec ?? 300), recording: m.capturing))
        case .rest(let a, let endsAt):
            surface = .rest(rest(m, after: a, endsAt: endsAt, remaining: 0, paused: false, done: false))
        case .restPaused(let a, let left):
            surface = .rest(rest(m, after: a, endsAt: nil, remaining: left, paused: true, done: false))
        case .restDone(let a):
            surface = .rest(rest(m, after: a, endsAt: nil, remaining: 0, paused: false, done: true))
        case .ended(let route):
            if route == .drillReview {
                surface = .ended(.init(title: "Drill done", line: m.log?.drillSummaryLine ?? "1 recording"))
            } else {
                surface = .ended(.init(title: "Recording saved", line: "Split it into \(c.sport.unit.noun)s on the phone."))
            }
        }
        var notice: RacketWatchState.Notice?
        if let i = m.interruption {
            notice = .init(reason: stopReason(i), canResume: i.canResume, savedUpToSec: m.log?.savedUpToSec)
        } else if m.isEnded && m.endedByStillPlaying {
            notice = .init(reason: .stillPlayingTimeout, canResume: false, savedUpToSec: m.log?.savedUpToSec)
        }
        let still = m.stillPlayingAskedAt.map {
            RacketWatchState.StillPlaying(askedAt: $0, minutes: Int((m.stillPlayingSec ?? 0) / 60),
                                          answerWindowSec: RacketStillPlaying.answerWindowSec)
        }
        return RacketWatchState(sessionID: c.sessionID, revision: 0, sport: c.sport.label, unitNoun: c.sport.unit.noun,
                                sideUs: c.sideUs, sideThem: c.sideThem,
                                note: m.racketMode == .match ? RacketWatchCopy.note(c.sport) : nil,
                                surface: surface, stillPlaying: still, notice: notice)
    }

    private static func rest(_ m: RacketRecordingMachine, after a: Int, endsAt: Date?, remaining: TimeInterval,
                             paused: Bool, done: Bool) -> RacketWatchState.Rest {
        .init(after: a, blocks: m.plan?.blocks ?? 1, endsAt: endsAt, remainingSec: remaining,
              totalSec: TimeInterval(m.plan?.restSec ?? 60), paused: paused, done: done,
              autoStart: m.plan?.autoStart ?? true)
    }

    /// Recorded time as a clock the Watch runs itself: the closed runs as the base, counting from the open run's
    /// start. Stable between events, so the phone needn't send a snapshot every second.
    static func recordedClock(_ m: RacketRecordingMachine) -> RacketWatchClock {
        guard let log = m.log else { return .init(base: 0, asOf: .distantPast, running: false) }
        let closed = log.runs.reduce(0.0) { $0 + max(0, ($1.endSec ?? $1.startSec) - $1.startSec) }
        if m.capturing, let open = log.runs.last, open.endSec == nil {
            return .init(base: closed, asOf: log.startedAt.addingTimeInterval(open.startSec), running: true)
        }
        return .init(base: closed, asOf: log.startedAt, running: false)
    }

    static func stopReason(_ i: RacketInterruption) -> RacketWatchStopReason {
        switch i {
        case .call: return .call
        case .appLeft: return .appLeft
        case .cameraBusy: return .cameraBusy
        case .cameraError: return .cameraError
        case .storageFull: return .storageFull
        case .tooHot: return .tooHot
        }
    }

    /// What a Watch tap did on the recording screen, beyond the machine's own effects.
    struct CoverOutcome: Equatable, Sendable {
        var effects: [RacketRecordingMachine.Effect] = []
        /// A tallied game / set finished: log it "from Watch" (the tally restarts for the next unit).
        var unitFinished: RacketLiveUnitResult?
        /// "New game" from the Watch: restart the tally for the next unit, logging nothing.
        var resetScore = false
    }

    /// Apply a Watch tap to the record-everything machine and the live tally. Every tap counts as activity for
    /// "Still playing?" (prompt 245; step 1 counted only phone taps).
    static func apply(_ command: RacketWatchCommand, to m: inout RacketRecordingMachine, score: inout RacketLiveScore,
                      now: Date) -> CoverOutcome {
        var out = CoverOutcome()
        guard !m.isEnded else { return out }
        m.noteActivity(now: now)
        switch command {
        case .start:
            if m.phase == .ready { out.effects = m.startNextBlock(now: now) }
        case .notYet, .endUnit:
            break
        case .pointUs, .pointThem:
            let firstOfGame = score.isEmpty
            guard m.phase == .recordingMatch, score.point(command == .pointUs ? .us : .them) else { break }
            // Play has started: the split tells a warmup / break from the game after it (prompt 246).
            if firstOfGame { m.mark(.firstPoint, now: now) }
            if let r = score.result {
                // A finished game is a new game on the recording, for the split (step 3).
                m.mark(.newGame, now: now)
                out.unitFinished = r
            }
        case .undo:
            if m.phase == .recordingMatch { score.undo() }
        case .mark:
            m.mark(.moment, now: now)
        case .newUnit:
            guard m.phase == .recordingMatch else { break }
            m.mark(.newGame, now: now)
            out.resetScore = true
        case .breakStarts:
            m.mark(.breakStart, now: now)
        case .stopAndSplit, .stopDrill, .finishDrill, .stopRecording, .endMatch:
            out.effects = m.end(now: now)
        case .endBlock:
            out.effects = m.endBlock(now: now)
        case .pauseTimer:
            m.pauseRest(now: now)
        case .resumeTimer:
            m.resumeRest(now: now)
        case .add30:
            if case .countdown = m.phase { m.extendCountdown(by: 30, now: now) } else { m.addRest(30, now: now) }
        case .add60:
            m.addRest(60, now: now)
        case .skip:
            out.effects = m.startNextBlock(now: now)
        case .keepPlaying:
            m.keepPlaying(now: now)
        }
        return out
    }
}

// MARK: - A game-by-game match on the Watch (Watch · WatchBreak · WatchStart)

/// The Watch side of a game-by-game match (prompt 203's "film the game", or not filmed): Start game N → score it point
/// by point → End game logs it "from Watch" → a break ring → the next game; Hold to end match. The phone's own Start /
/// End game flow keeps working; this only adds the wrist.
struct RacketWatchMatch: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case ready
        case scoring(startedAt: Date)
        case breakTime(endsAt: Date?, remaining: TimeInterval, paused: Bool)
        case ended
    }

    enum Effect: Equatable, Sendable {
        /// Start the phone's unit clock (`racketTimers`), as "Start game" on the phone does.
        case startUnitTimer(Date)
        /// Log the unit "from Watch" with how long it took.
        case logUnit(RacketLiveUnitResult, durationSec: TimeInterval)
        /// "Hold to end match": the Watch is done with this match.
        case endMatch
    }

    let exerciseID: UUID
    let breakSec: TimeInterval
    private(set) var unitIndex: Int
    private(set) var score: RacketLiveScore
    private(set) var phase: Phase = .ready
    /// "11–9", the unit just logged (the break board's header).
    private(set) var lastUnitLabel: String?

    init(exerciseID: UUID, unitIndex: Int, rules: RacketLiveRules, breakSec: TimeInterval, startedAt: Date? = nil) {
        self.exerciseID = exerciseID
        self.unitIndex = unitIndex
        self.breakSec = breakSec
        score = RacketLiveScore(rules: rules)
        if let startedAt { phase = .scoring(startedAt: startedAt) }
    }

    /// The rest between games / sets: 1:00 in table tennis, 1:30 in squash, 2:00 otherwise (the boards' defaults).
    static func defaultBreakSec(_ sport: RacketSport) -> TimeInterval {
        switch sport {
        case .tableTennis: return 60
        case .squash: return 90
        case .badminton, .tennis, .padel, .pickleball: return 120
        }
    }

    mutating func apply(_ command: RacketWatchCommand, now: Date) -> [Effect] {
        switch (command, phase) {
        case (.start, .ready):
            phase = .scoring(startedAt: now)
            return [.startUnitTimer(now)]
        case (.pointUs, .scoring), (.pointThem, .scoring):
            score.point(command == .pointUs ? .us : .them)
            return []
        case (.undo, .scoring):
            score.undo()
            return []
        case (.endUnit, .scoring(let startedAt)):
            guard !score.isEmpty else { return [] }
            return [.logUnit(score.provisionalResult, durationSec: now.timeIntervalSince(startedAt))]
        case (.endMatch, let p):
            var effects: [Effect] = []
            if case .scoring(let startedAt) = p, !score.isEmpty {
                effects.append(.logUnit(score.provisionalResult, durationSec: now.timeIntervalSince(startedAt)))
            }
            phase = .ended
            return effects + [.endMatch]
        case (.pauseTimer, .breakTime(let endsAt, _, false)):
            phase = .breakTime(endsAt: nil, remaining: max(0, (endsAt ?? now).timeIntervalSince(now)), paused: true)
            return []
        case (.resumeTimer, .breakTime(_, let left, true)):
            phase = .breakTime(endsAt: now.addingTimeInterval(left), remaining: 0, paused: false)
            return []
        case (.add30, .breakTime(let endsAt, let left, let paused)):
            phase = paused ? .breakTime(endsAt: nil, remaining: left + 30, paused: true)
                           : .breakTime(endsAt: (endsAt ?? now).addingTimeInterval(30), remaining: 0, paused: false)
            return []
        case (.skip, .breakTime):
            phase = .scoring(startedAt: now)
            return [.startUnitTimer(now)]
        default:
            return []
        }
    }

    /// The break ran out: the next game starts (the Watch taps you).
    mutating func tick(now: Date) -> [Effect] {
        guard case .breakTime(let endsAt?, _, false) = phase, now >= endsAt else { return [] }
        phase = .scoring(startedAt: endsAt)
        return [.startUnitTimer(endsAt)]
    }

    /// The phone logged a unit (from the Watch or its own score sheet): move on to the next one with its rules.
    /// After a Watch-ended unit, a break follows; a decided match ends.
    mutating func logged(unitCount: Int, rules: RacketLiveRules, lastLabel: String?, decided: Bool, fromWatch: Bool,
                         now: Date) {
        guard unitCount != unitIndex else { return }
        unitIndex = unitCount
        score = RacketLiveScore(rules: rules)
        lastUnitLabel = lastLabel
        if decided { phase = .ended }
        else if fromWatch { phase = .breakTime(endsAt: now.addingTimeInterval(breakSec), remaining: 0, paused: false) }
        else { phase = .ready }
    }

    /// The phone's own "Start game".
    mutating func startedOnPhone(at date: Date) {
        if case .scoring = phase { return }
        phase = .scoring(startedAt: date)
    }

    func state(context c: RacketWatchContext) -> RacketWatchState {
        let noun = c.sport.unit.noun
        let surface: RacketWatchState.Surface
        switch phase {
        case .ready:
            surface = .start(.init(title: "Start \(noun) \(unitIndex + 1)?", cameraReady: false,
                                   footnote: "Starts the \(noun) clock on your phone."))
        case .scoring(let startedAt):
            surface = .scoring(.init(unitNumber: unitIndex + 1, score: score,
                                     clock: .init(base: 0, asOf: startedAt, running: true), matchLine: c.matchLine))
        case .breakTime(let endsAt, let left, let paused):
            surface = .matchBreak(.init(unitNumber: unitIndex, unitScore: lastUnitLabel ?? "",
                                        endsAt: endsAt, remainingSec: left, totalSec: breakSec, paused: paused))
        case .ended:
            surface = .ended(.init(title: c.matchLine ?? "Match over", line: "Confirm the scores on the phone."))
        }
        return RacketWatchState(sessionID: c.sessionID, revision: 0, sport: c.sport.label, unitNoun: noun,
                                sideUs: c.sideUs, sideThem: c.sideThem, note: RacketWatchCopy.note(c.sport),
                                surface: surface, stillPlaying: nil, notice: nil)
    }
}

// MARK: - Command de-dupe

/// A Watch tap can arrive twice (`sendMessage` reported a failure after delivering, then `transferUserInfo` re-sent it).
/// Remembers the last few command ids so each tap applies once.
struct RacketWatchCommandLedger: Equatable, Sendable {
    var capacity = 64
    private(set) var ids: [UUID] = []

    /// `true` the first time an id is seen.
    mutating func firstTime(_ id: UUID) -> Bool {
        guard !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > capacity { ids.removeFirst(ids.count - capacity) }
        return true
    }
}
