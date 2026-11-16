import Foundation

// MARK: - Game-by-game match recording and scoring without video (prompt 249, issue #438 parity) — pure
//
// The boards' match flow for the default "Game by game" mode and for "Play without video":
// Match → Camera (NoModelCamera) → Warmup → DimOff / CameraViewOff / StatsOff → (Interval, badminton) → Score
// (SaveGame) → Break (GameBreak) → Countdown (GameCountdown) → the next game … → match over; and Match → ScoreOnly.
// `RacketGameFlow` owns the game / interval / break / countdown phases; the capture itself (runs, parts,
// interruptions, "Still playing?") stays in `RacketRecordingMachine` with `recording: .byUnit`, which this flow drives
// through `pauseCapture` / `resumeCapture`. Foundation only, so it runs in `SnappetTests` (`RacketMatchFlowTests`).

// MARK: - The flow

/// One game-by-game match on the phone, from the warmup to match over. Every event takes `now` and returns the side
/// effects the host must perform; the host never decides a transition itself.
struct RacketGameFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Warmup: camera ready, nothing recorded until the game starts (Warmup board).
        case warmup
        /// A game (or set) being played.
        case playing
        /// Badminton's interval at 11 (BdInterval): the game goes on afterwards, no new clip or score.
        case interval(endsAt: Date)
        case intervalPaused(remaining: TimeInterval)
        /// The score sheet is up for the game just played (SaveGame). `matchOver`: Stop / End was tapped.
        case scoring(matchOver: Bool)
        /// Between games (GameBreak).
        case breakTime(endsAt: Date)
        case breakPaused(remaining: TimeInterval)
        /// The break ran out with auto-start off: the player starts the next game.
        case breakDone
        /// "Starting soon · Game 2" (GameCountdown): recording starts at zero.
        case countdown(endsAt: Date)
        case ended
    }

    enum Effect: Equatable, Sendable {
        /// Recording should run (a game started, an interval / a recorded break ended).
        case resumeCapture
        /// Recording should pause (a break or an interval with "Pause recording" on, match over).
        case pauseCapture
        /// Show the score sheet for the game just played.
        case openScore
        /// Match over: close, then Your videos when there's video.
        case matchOver
    }

    /// The choices on SaveGame / BdInterval, kept for the rest of the match.
    struct Options: Equatable, Sendable {
        var breakSec: Int
        /// "Start next game automatically · Recording starts when the break ends".
        var autoStart: Bool = true
        /// "Pause recording during the break · Each game saves as its own clip".
        var pauseRecordingInBreak: Bool = true
        /// The countdown before the next game.
        var countdownSec: Int = 3
        /// Badminton: an interval when the leading score first reaches this (11 in a game to 21).
        var intervalAt: Int?
        var intervalSec: Int = 60
        /// "Pause recording during intervals · Off keeps one clip for the game".
        var pauseRecordingInInterval: Bool = false

        init(sport: RacketSport, pointsTo: Int) {
            breakSec = Int(RacketWatchMatch.defaultBreakSec(sport))
            intervalAt = RacketGameFlow.intervalAt(sport: sport, pointsTo: pointsTo)
        }
    }

    /// `false`: Play without video (ScoreOnly) — the same games, breaks and countdowns, nothing filmed.
    let filming: Bool
    var options: Options
    private(set) var phase: Phase
    /// The game being played (0-based, an index into the match's `sets`).
    private(set) var unitIndex: Int
    private(set) var gameStartedAt: Date?
    /// The interval was taken in this game (it comes once).
    private(set) var intervalTaken = false
    /// Auto-start for the break running now (off once the score decides the match).
    private(set) var breakAutoStart = true

    init(filming: Bool, unitIndex: Int, options: Options, startInWarmup: Bool = true) {
        self.filming = filming
        self.unitIndex = unitIndex
        self.options = options
        phase = startInWarmup ? .warmup : .playing
    }

    /// Badminton has an interval when the leading score reaches 11 (to 21) or 8 (to 15); no other sport does.
    static func intervalAt(sport: RacketSport, pointsTo: Int) -> Int? {
        guard sport == .badminton else { return nil }
        return pointsTo == 15 ? 8 : 11
    }

    var isEnded: Bool { phase == .ended }

    /// Whether the camera should be writing in this phase (the host reconciles after an interruption is resumed).
    var wantsCapture: Bool {
        guard filming else { return false }
        switch phase {
        case .playing, .scoring: return true
        case .interval, .intervalPaused: return !options.pauseRecordingInInterval
        case .breakTime, .breakPaused, .breakDone, .countdown: return !options.pauseRecordingInBreak
        case .warmup, .ended: return false
        }
    }

    // MARK: Games

    /// Start recording / the next game (Warmup "Start recording", Watch Start, the countdown reaching zero, "Start
    /// game 2" after a break with auto-start off).
    @discardableResult
    mutating func startGame(now: Date) -> [Effect] {
        switch phase {
        case .warmup, .breakTime, .breakPaused, .breakDone, .countdown: break
        default: return []
        }
        phase = .playing
        gameStartedAt = now
        intervalTaken = false
        return filming ? [.resumeCapture] : []
    }

    /// The live tally changed (a Watch or phone tap). Badminton's interval starts when the leading score first
    /// reaches 11; a finished tally opens the score sheet (Tiebreak → Score "Set ends").
    @discardableResult
    mutating func pointsChanged(_ score: RacketLiveScore, now: Date) -> [Effect] {
        guard phase == .playing || isInInterval else { return [] }
        if score.isFinished { return endGame(matchOver: false, now: now) }
        guard phase == .playing, !intervalTaken, let at = options.intervalAt, score.rules.kind == .rally else { return [] }
        let t = score.tally
        guard max(t.pointsFor, t.pointsAgainst) >= at else { return [] }
        intervalTaken = true
        phase = .interval(endsAt: now.addingTimeInterval(TimeInterval(options.intervalSec)))
        return filming && options.pauseRecordingInInterval ? [.pauseCapture] : []
    }

    var isInInterval: Bool {
        switch phase {
        case .interval, .intervalPaused: return true
        default: return false
        }
    }

    /// "Next game" / "Stop" (red outline → the score sheet, then match over) / Watch "End game".
    @discardableResult
    mutating func endGame(matchOver: Bool, now: Date) -> [Effect] {
        guard phase == .playing || isInInterval else { return [] }
        let resume = isInInterval && filming && options.pauseRecordingInInterval
        phase = .scoring(matchOver: matchOver)
        // The game's clip runs until the score is saved (an interval's pause ends with the game).
        return (resume ? [.resumeCapture] : []) + [.openScore]
    }

    /// The score sheet was cancelled: back to the game.
    mutating func cancelScore() {
        guard case .scoring = phase else { return }
        phase = .playing
    }

    /// "Save, start break" / "Later" (`startBreak: true`) or "Save, match over". `decided`: the saved score decides
    /// the match, so auto-start stops ("Auto-start stops once the score decides the match").
    @discardableResult
    mutating func saved(startBreak: Bool, decided: Bool, now: Date) -> [Effect] {
        guard case .scoring(let matchOver) = phase else { return [] }
        unitIndex += 1
        gameStartedAt = nil
        if matchOver || !startBreak { return finish() }
        breakAutoStart = options.autoStart && !decided
        phase = .breakTime(endsAt: now.addingTimeInterval(TimeInterval(options.breakSec)))
        return filming && options.pauseRecordingInBreak ? [.pauseCapture] : []
    }

    /// "End match" on the break (Break → Analyzing), or the recording ended for good.
    @discardableResult
    mutating func endMatch() -> [Effect] {
        guard !isEnded else { return [] }
        if case .scoring = phase { unitIndex += 1 }
        return finish()
    }

    private mutating func finish() -> [Effect] {
        phase = .ended
        return (filming ? [.pauseCapture] : []) + [.matchOver]
    }

    // MARK: Interval (BdInterval)

    mutating func pauseInterval(now: Date) {
        guard case .interval(let endsAt) = phase else { return }
        phase = .intervalPaused(remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    mutating func resumeInterval(now: Date) {
        guard case .intervalPaused(let left) = phase else { return }
        phase = .interval(endsAt: now.addingTimeInterval(left))
    }

    mutating func addInterval(_ sec: TimeInterval) {
        switch phase {
        case .interval(let endsAt): phase = .interval(endsAt: endsAt.addingTimeInterval(sec))
        case .intervalPaused(let left): phase = .intervalPaused(remaining: left + sec)
        default: break
        }
    }

    /// "Skip interval", or the interval timer running out: the game goes on.
    @discardableResult
    mutating func endInterval() -> [Effect] {
        guard isInInterval else { return [] }
        phase = .playing
        return filming && options.pauseRecordingInInterval ? [.resumeCapture] : []
    }

    /// The switch on the interval: on pauses the recording now, off resumes it.
    @discardableResult
    mutating func setPauseRecordingInInterval(_ on: Bool) -> [Effect] {
        guard options.pauseRecordingInInterval != on else { return [] }
        options.pauseRecordingInInterval = on
        guard filming, isInInterval else { return [] }
        return [on ? .pauseCapture : .resumeCapture]
    }

    // MARK: Break (GameBreak)

    mutating func pauseBreak(now: Date) {
        guard case .breakTime(let endsAt) = phase else { return }
        phase = .breakPaused(remaining: max(0, endsAt.timeIntervalSince(now)))
    }

    mutating func resumeBreak(now: Date) {
        guard case .breakPaused(let left) = phase else { return }
        phase = .breakTime(endsAt: now.addingTimeInterval(left))
    }

    mutating func addBreak(_ sec: TimeInterval) {
        switch phase {
        case .breakTime(let endsAt): phase = .breakTime(endsAt: endsAt.addingTimeInterval(sec))
        case .breakPaused(let left): phase = .breakPaused(remaining: left + sec)
        default: break
        }
    }

    /// The break's Auto-start switch.
    mutating func setBreakAutoStart(_ on: Bool) {
        breakAutoStart = on
        options.autoStart = on
    }

    /// "Skip break, start Game 2": the countdown.
    mutating func skipBreak(now: Date) {
        switch phase {
        case .breakTime, .breakPaused, .breakDone:
            phase = .countdown(endsAt: now.addingTimeInterval(TimeInterval(options.countdownSec)))
        default: break
        }
    }

    // MARK: Countdown (GameCountdown)

    /// "Wait returns to a paused break timer."
    mutating func wait() {
        guard case .countdown = phase else { return }
        phase = .breakPaused(remaining: 0)
    }

    mutating func extendCountdown(by sec: TimeInterval) {
        guard case .countdown(let endsAt) = phase else { return }
        phase = .countdown(endsAt: endsAt.addingTimeInterval(sec))
    }

    // MARK: Clock

    /// Advance the timers. Call about once a second.
    @discardableResult
    mutating func tick(now: Date) -> [Effect] {
        switch phase {
        case .interval(let endsAt) where now >= endsAt:
            return endInterval()
        case .breakTime(let endsAt) where now >= endsAt:
            if breakAutoStart {
                phase = .countdown(endsAt: endsAt.addingTimeInterval(TimeInterval(options.countdownSec)))
                if now >= endsAt.addingTimeInterval(TimeInterval(options.countdownSec)) { return tick(now: now) }
            } else {
                phase = .breakDone
            }
            return []
        case .countdown(let endsAt) where now >= endsAt:
            return startGame(now: endsAt)
        default:
            return []
        }
    }

    /// The timer word, tone and ring for the interval / break / countdown.
    func display(now: Date) -> RacketTimerDisplay? {
        switch phase {
        case .interval(let endsAt):
            let left = max(0, endsAt.timeIntervalSince(now))
            return .init(word: "Interval", tone: .rest, seconds: left, progress: min(1, left / Double(max(1, options.intervalSec))))
        case .intervalPaused(let left):
            return .init(word: "Interval, paused", tone: .restPaused, seconds: left,
                         progress: min(1, left / Double(max(1, options.intervalSec))))
        case .breakTime(let endsAt):
            let left = max(0, endsAt.timeIntervalSince(now))
            return .init(word: "Break", tone: .rest, seconds: left, progress: min(1, left / Double(max(1, options.breakSec))))
        case .breakPaused(let left):
            return .init(word: "Break, paused", tone: .restPaused, seconds: left,
                         progress: min(1, left / Double(max(1, options.breakSec))))
        case .breakDone:
            return .init(word: "Break done", tone: .rest, seconds: 0, progress: 0)
        case .countdown(let endsAt):
            let left = max(0, endsAt.timeIntervalSince(now))
            return .init(word: "Starting soon", tone: .work, seconds: left,
                         progress: min(1, left / Double(max(1, options.countdownSec))))
        case .warmup, .playing, .scoring, .ended:
            return nil
        }
    }
}

// MARK: - Who serves

/// Who serves the next point, from who served first (Warmup "Who serves first?") and the points so far. `nil` when
/// the player skipped the question.
enum RacketServe {
    enum Side: String, Codable, Sendable { case us, them
        var other: Side { self == .us ? .them : .us }
    }

    /// - Parameters:
    ///   - firstServer: who served the match's first point.
    ///   - unitIndex: the game / set being played (0-based).
    ///   - previous: the units already logged (their scores), for who starts this one.
    ///   - points: the points of this unit, in order (`RacketLiveScore.points`).
    static func server(sport: RacketSport, firstServer: Side?, unitIndex: Int, previous: [RacketUnitScore],
                       points: [RacketLiveScore.Side]) -> Side? {
        guard let firstServer else { return nil }
        switch sport {
        case .badminton, .squash, .pickleball:
            // Rally scoring: the rally winner serves next; the previous game's winner serves first.
            if let last = points.last { return last == .us ? .us : .them }
            guard unitIndex > 0, let prev = previous.last else { return firstServer }
            return prev.scoreFor > prev.scoreAgainst ? .us : .them
        case .tableTennis:
            // Two serves each, one each from 10–10; the receiver of game 1 serves first in game 2, and so on.
            let gameFirst = unitIndex % 2 == 0 ? firstServer : firstServer.other
            let p = points.count
            let flips = p < 20 ? p / 2 : p - 10
            return flips % 2 == 0 ? gameFirst : gameFirst.other
        case .tennis, .padel:
            // The server changes every game, across sets; in a tiebreak the next server serves one, then two each.
            let gamesBefore = previous.reduce(0) { $0 + $1.scoreFor + $1.scoreAgainst }
            var games = 0, pf = 0, pa = 0, inTB = false
            var gf = 0, ga = 0
            for side in points {
                if side == .us { pf += 1 } else { pa += 1 }
                if !inTB, (pf >= 4 || pa >= 4), abs(pf - pa) >= 2 {
                    if pf > pa { gf += 1 } else { ga += 1 }
                    games += 1; pf = 0; pa = 0
                    if gf == 6 && ga == 6 { inTB = true }
                }
            }
            let total = gamesBefore + games
            let gameServer = total % 2 == 0 ? firstServer : firstServer.other
            guard inTB else { return gameServer }
            let tbPoints = pf + pa
            return ((tbPoints + 1) / 2) % 2 == 0 ? gameServer : gameServer.other
        }
    }
}

// MARK: - Phone heat (Warm / PhoneWarm)

/// How warm the phone is, from `ProcessInfo.ThermalState`'s raw value (0 nominal, 1 fair, 2 serious, 3 critical).
/// Serious: keep recording, pause the camera view and say "▲ Warm"; critical: iOS stops the camera (InterruptedStop).
enum RacketThermalLevel: String, Equatable, Sendable {
    case ok, warm, tooHot

    static func from(rawValue: Int) -> RacketThermalLevel {
        switch rawValue {
        case ..<2: return .ok
        case 2: return .warm
        default: return .tooHot
        }
    }

    /// The header's right-hand word: "Phone OK" / "▲ Warm".
    var headerLabel: String { self == .ok ? "Phone OK" : "▲ Warm" }
}

// MARK: - Copy (per sport)

enum RacketGameCopy {
    /// "Game 1" / "Set 2".
    static func unitTitle(_ unit: RacketUnit, index: Int) -> String { "\(unit.noun.capitalized) \(index + 1)" }

    /// The table tennis boards say "after the game"; every other sport "after the match".
    static func afterWord(_ sport: RacketSport) -> String { sport == .tableTennis ? "game" : "match" }

    /// DimOff: "Recording. Rallies will be found after the match."
    static func recordingLine(_ sport: RacketSport) -> String { "Recording. Rallies will be found after the \(afterWord(sport))." }

    /// CameraViewOff: "Live tracking is off. Rallies will be found after the match."
    static let cameraTrackingOffLine = "Live tracking is off. Rallies will be found after the match."

    /// StatsOff: "Rally and shot stats appear after the match."
    static func statsAfterLine(_ sport: RacketSport) -> String { "Rally and shot stats appear after the \(afterWord(sport))." }

    /// StatsOff's points tile: "Points played" (table tennis) / "Points tagged" (the others).
    static func pointsLabel(_ sport: RacketSport) -> String { sport == .tableTennis ? "Points played" : "Points tagged" }

    /// Warmup's live-tracking line: "Off: rallies are found after the game / match".
    static func warmupTrackingLine(_ sport: RacketSport) -> String { "Off: rallies are found after the \(afterWord(sport))" }

    /// Warmup: "Game by game saves nothing until you start the game. Everything records warmup too."
    static func warmupLine(_ unit: RacketUnit) -> String {
        "Game by game saves nothing until you start the \(unit.noun). Everything records warmup too."
    }

    /// The line under the big score: "Game 1 · you’re serving" (rally sports with a known server), "Games 4–3 · Set 1"
    /// (tennis / padel), "Score from Watch" (table tennis, once the Watch has a point), else "Game 1".
    static func scoreCaption(sport: RacketSport, unitIndex: Int, score: RacketLiveScore?, server: RacketServe.Side?,
                             them: String, fromWatch: Bool = true) -> String {
        let title = unitTitle(sport.unit, index: unitIndex)
        if sport.usesSets {
            let t = score?.tally ?? .init()
            if score?.rules.superTiebreak == true { return "Match tiebreak" }
            return "Games \(t.gamesFor)–\(t.gamesAgainst) · \(title)"
        }
        // Phone taps (ScoreOnly) aren't "from Watch".
        if sport == .tableTennis { return fromWatch && score?.isEmpty == false ? "Score from Watch" : title }
        switch server {
        case .us?: return "\(title) · you’re serving"
        case .them?: return "\(title) · \(them) serving"
        case nil: return title
        }
    }

    /// TnTiebreak: "Set 1 · games 6–6 · first to 7, win by 2".
    static func tiebreakLine(unitIndex: Int, gamesTo: Int) -> String {
        "Set \(unitIndex + 1) · games \(gamesTo)–\(gamesTo) · first to 7, win by 2"
    }

    static let tiebreakWatchLine = "The Watch switches from 15, 30, 40 to plain points."

    /// SaveGame's subtitle: the sport's rule, then where the numbers came from.
    static func scoreSubtitle(sport: RacketSport, fromWatch: Bool, cap: Int?) -> String {
        switch sport {
        case .tableTennis:
            return fromWatch ? "Filled in from your Watch taps. Fix it now or later." : "Fix it now or later."
        case .badminton:
            let rule = cap.map { "Win by 2, capped at \($0)." } ?? "Win by 2."
            return fromWatch ? "\(rule) Filled in from your Watch." : rule
        case .tennis, .padel:
            return fromWatch ? "Games in this set. Filled in from your Watch." : "Games in this set."
        case .pickleball, .squash:
            return fromWatch ? "Win by 2. Filled in from your Watch." : "Win by 2."
        }
    }

    /// SaveGame's break chips: table tennis offers 0:30, squash starts at 1:30, the rest at 1:00.
    static func breakChips(_ sport: RacketSport) -> [Int] {
        switch sport {
        case .tableTennis: return [30, 60, 120, 300]
        case .squash: return [90, 120, 300]
        default: return [60, 120, 300]
        }
    }

    /// GameBreak: "Game 2 starts by itself after this" / auto-start off.
    static func breakLine(unit: RacketUnit, next: Int, autoStart: Bool) -> String {
        autoStart ? "\(unit.noun.capitalized) \(next) starts by itself after this"
                  : "Auto-start is off: you start the next \(unit.noun) yourself"
    }

    /// The match form's live header: "Best of 3" over "Games to 21" / "Sets to 6".
    static func formatHeader(_ format: RacketFormat) -> (top: String, bottom: String) {
        let top: String
        switch format.bestOf {
        case nil: top = "Open play"
        case 1?: top = format.sport.usesSets ? "One set" : "One game"
        case let n?: top = "Best of \(n)"
        }
        return (top, "\(format.sport.unit.noun.capitalized)s to \(format.pointsTo)")
    }

    /// "Doubles adds your side of the court, a partner and two opponents."
    static let doublesHelper = "Doubles adds your side of the court, a partner and two opponents."
    /// "Finds your rallies and builds a timeline. Video saves to your Photos library."
    static let filmHelper = "Finds your rallies and builds a timeline. Video saves to your Photos library."
    /// TtSessionHub's footnote.
    static let hubFootnote = "You choose how to record on each match and drill. End session stops any recording and shows your recap. Close keeps the session open."
}

// MARK: - The game-by-game recording as parts (Your videos)

extension RacketRecordingLog {
    /// Game by game (prompt 249): this log came from the game-by-game screen (its games are marked, no split needed).
    var isGameByGame: Bool { modeRaw == RacketRecordingMode.byUnit.rawValue }

    /// The game being filmed at recording time `t` (seconds on this log's timeline): its set index, or nil between
    /// games (a recorded break).
    func gameIndex(at t: Double) -> Int? {
        marks.last { $0.kind == .game && $0.startSec <= t + 0.5 && ($0.endSec.map { t < $0 } ?? true) }?.index
    }
}

enum RacketGameByGameSplit {
    /// One game part per game mark (its set index), and a break part for any recorded stretch between games — the
    /// split Your videos reads, applied as soon as it's recorded (each game is already its own clip).
    static func parts(_ log: RacketRecordingLog) -> [RacketVideoPart] {
        let games = log.marks.filter { $0.kind == .game }.sorted { $0.startSec < $1.startSec }
        var parts: [RacketVideoPart] = []
        var cursor: Double = 0
        let total = log.timelineSec
        for g in games {
            let end = g.endSec ?? total
            if g.startSec - cursor >= RacketSplitProposal.minPartSec, recorded(log, cursor, g.startSec) {
                parts.append(.init(kind: cursor == 0 ? .warmup : .breakTime, startSec: cursor, endSec: g.startSec))
            }
            parts.append(.init(kind: .game, startSec: g.startSec, endSec: max(g.startSec, end), setIndex: g.index))
            cursor = max(cursor, end)
        }
        if total - cursor >= RacketSplitProposal.minPartSec, recorded(log, cursor, total) {
            parts.append(.init(kind: .notPlay, startSec: cursor, endSec: total))
        }
        return parts
    }

    /// Any video in [a, b)?
    private static func recorded(_ log: RacketRecordingLog, _ a: Double, _ b: Double) -> Bool {
        log.runs.contains { ($0.endSec ?? .infinity) > a + 0.5 && $0.startSec < b - 0.5 }
    }

    /// The split to store on the log (applied: the games are known).
    static func split(_ log: RacketRecordingLog, now: Date) -> RacketSplit? {
        let p = parts(log)
        guard p.contains(where: { $0.kind == .game }) else { return nil }
        return RacketSplit(parts: p, appliedAt: now)
    }
}

// MARK: - The recording header's clock

extension RacketClock {
    /// The boards' recording header: zero-padded "09:41" / "48:20", "1:02:04" past an hour (TtRecordAll). Rings keep
    /// `mmss` ("0:45").
    static func recordingHeader(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Session recap (TtSessionRecap)

enum RacketRecapLine {
    /// "1:24:10 · average heart rate 132"; just the time with no heart rate.
    static func line(durationSec: TimeInterval, bpms: [Double]) -> String {
        let time = RacketClock.elapsed(durationSec)
        guard !bpms.isEmpty else { return time }
        let avg = bpms.reduce(0, +) / Double(bpms.count)
        return "\(time) · average heart rate \(Int(avg.rounded()))"
    }
}

// MARK: - The match form's chips (Match / XxMatch boards)

enum RacketMatchFormChoices {
    /// The boards' format chips: TT best of 3 / 5 / 7, badminton best of 3 / one game, squash and tennis best of
    /// 3 / 5; pickleball keeps its options until PbScoring is built.
    static func bestOf(_ sport: RacketSport) -> [Int] {
        switch sport {
        case .tableTennis: return [3, 5, 7]
        case .badminton: return [3, 1]
        case .squash, .tennis: return [3, 5]
        case .pickleball, .padel: return sport.bestOfOptions
        }
    }

    static func bestOfLabel(_ sport: RacketSport, _ n: Int) -> String {
        n == 1 ? (sport.usesSets ? "One set" : "One game") : "Best of \(n)"
    }

    /// "Games to 15" next to the format chips (badminton, squash).
    static func altPointsTo(_ sport: RacketSport) -> Int? {
        switch sport {
        case .badminton, .squash: return 15
        default: return nil
        }
    }
}
