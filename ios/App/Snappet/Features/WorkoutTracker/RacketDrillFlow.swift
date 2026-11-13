import Foundation

// MARK: - Drill parity: library, details, copy, review, trend (prompt 250, issue #438) — pure
//
// The boards' drill flow for every recording mode: Drills (library, per sport) → Setup / SetupFirst / SqSolo (summary
// rows) ⇄ Customize (Drill details) → Camera check → BlockStart → Block (BlockOff / BlockAll) ⇄ Paused → Rest (RestOff /
// RestEverything) ⇄ RestPaused → … → Review → DrillTrend / DrillVideos. The timers and capture live in
// `RacketRecordingMachine`; this file holds the choices, the copy and the numbers. Foundation only, so it runs in
// `SnappetTests` (`RacketDrillFlowTests`).

// MARK: - Choices per sport (DrillCustomize boards)

enum RacketDrillChoices {
    /// "How are you practising?" (TT With a partner / Robot / Multiball / Solo; Bd Feeder / Multi-shuttle; …).
    static func practising(_ sport: RacketSport) -> [String] {
        switch sport {
        case .tableTennis: return ["With a partner", "Robot", "Multiball", "Solo"]
        case .badminton: return ["With a partner", "Feeder", "Multi-shuttle", "Solo"]
        case .tennis: return ["With a partner", "Ball machine", "Feeding", "Solo"]
        case .pickleball: return ["With a partner", "Ball machine", "Drilling group", "Solo"]
        case .padel: return ["With partners", "Ball machine", "Coach feeding", "Solo"]
        case .squash: return ["With a partner", "Coach feeding", "Solo"]
        }
    }

    /// Focus, first row: the hand.
    static let hands = ["Forehand", "Backhand", "Mix"]

    /// Focus, second row: the stroke.
    static func strokes(_ sport: RacketSport) -> [String] {
        switch sport {
        case .tableTennis: return ["Topspin", "Push", "Block", "Drive", "Smash", "Flick", "Serve", "Footwork"]
        case .badminton: return ["Serve", "Lift", "Clear", "Drop", "Net shot", "Smash", "Drive", "Push", "Block"]
        case .tennis: return ["Serve", "Return", "Drive", "Slice", "Volley", "Lob", "Smash", "Drop"]
        case .pickleball: return ["Serve", "Return", "Third-shot drop", "Dink", "Volley", "Lob", "Drive", "Smash", "Reset"]
        case .padel: return ["Serve", "Return", "Volley", "Wall return", "Bandeja", "Lob", "Vibora", "Smash", "Bajada"]
        case .squash: return ["Serve", "Return", "Drive", "Boast", "Drop", "Volley", "Lob", "Cross-court"]
        }
    }

    /// Pattern (Optional).
    static func patterns(_ sport: RacketSport) -> [String] {
        switch sport {
        case .tableTennis: return ["Cross-court", "Down the line", "Two-point", "Random"]
        case .badminton: return ["Straight", "Cross-court", "Random"]
        case .tennis: return ["Cross-court", "Down the line", "Inside-out", "Random"]
        case .pickleball: return ["Cross-court", "Straight", "Middle", "Random"]
        case .padel: return ["At the net", "Cross-court", "Off the wall", "Random"]
        case .squash: return ["Straight and boast", "Length", "Cross-court", "Random"]
        }
    }

    /// The court diagram's grid (the boards' mini table: 6 across, 3 deep). A zone is `row * columns + column`.
    static let columns = 6
    static let rows = 3

    /// "Rest is set on the ready screen" — the Customize plan's limits.
    static let blockRange = 1...12
    static let blockSecStep = 30
    static let blockSecRange = 30...1800
}

// MARK: - Drill details (Customize → Setup rows)

struct RacketDrillDetails: Equatable, Sendable {
    var practising: String?
    var hand: String?
    var stroke: String?
    var pattern: String?
    var fromZone: Int?
    var toZone: Int?
    /// "Beat 24 shots" (longest rally) / "Beat 76%" (made / tried); nil ⇒ no goal.
    var goal: Int?

    init(practising: String? = nil, hand: String? = nil, stroke: String? = nil, pattern: String? = nil,
         fromZone: Int? = nil, toZone: Int? = nil, goal: Int? = nil) {
        self.practising = practising
        self.hand = hand
        self.stroke = stroke
        self.pattern = pattern
        self.fromZone = fromZone
        self.toZone = toZone
        self.goal = goal
    }

    init(from ex: SessionExercise) {
        self.init(practising: ex.drillPractising, hand: ex.drillHand, stroke: ex.drillStroke, pattern: ex.drillPattern,
                  fromZone: ex.drillFromZone, toZone: ex.drillToZone, goal: ex.drillGoal)
    }

    func apply(to ex: inout SessionExercise) {
        ex.drillPractising = practising
        ex.drillHand = hand
        ex.drillStroke = stroke
        ex.drillPattern = pattern
        ex.drillFromZone = fromZone
        ex.drillToZone = toZone
        ex.drillGoal = goal
    }

    /// "Forehand topspin"; nil before a focus is chosen.
    var focusLine: String? {
        switch (hand, stroke) {
        case let (h?, s?): return "\(h) \(s.lowercased())"
        case let (h?, nil): return h
        case let (nil, s?): return s
        default: return nil
        }
    }

    var hasFocus: Bool { hand != nil || stroke != nil }

    /// SetupFirst's gate: "Choose what you're practising and your focus first."
    var canStart: Bool { practising != nil && hasFocus }

    /// Review's tags: table tennis shows the hand and the stroke apart (PracticeReview "Forehand · Topspin"), the other
    /// sports as one ("Forehand drive").
    func tags(sport: RacketSport) -> [String] {
        var out: [String] = []
        if let practising { out.append(practising) }
        if sport == .tableTennis {
            if let hand { out.append(hand) }
            if let stroke { out.append(stroke) }
        } else if let f = focusLine {
            out.append(f)
        }
        if let pattern { out.append(pattern) }
        return out
    }
}

// MARK: - The goal ("Beat 24 shots · Last time 24")

enum RacketDrillGoal {
    /// "Beat 24 shots" / "Beat 76%"; nil for a timed drill or no goal.
    static func text(_ goal: Int?, measure: RacketDrillMeasure) -> String? {
        guard let goal else { return nil }
        switch measure {
        case .longestRally: return "Beat \(goal) shots"
        case .madeTried: return "Beat \(goal)%"
        case .time: return nil
        }
    }

    /// "Last time 24" / "Last time 76%".
    static func lastTime(_ value: Int?, measure: RacketDrillMeasure) -> String? {
        guard let value, measure != .time else { return nil }
        return measure == .madeTried ? "Last time \(value)%" : "Last time \(value)"
    }

    /// Block screen: "Goal: beat 24 shots".
    static func blockLine(_ goal: Int?, measure: RacketDrillMeasure) -> String? {
        text(goal, measure: measure).map { "Goal: " + $0.prefix(1).lowercased() + $0.dropFirst() }
    }

    /// The step for −/+ on the goal.
    static func step(_ measure: RacketDrillMeasure) -> Int { measure == .madeTried ? 5 : 1 }
}

// MARK: - History ("Last time", first time, best)

enum RacketDrillHistory {
    /// The drills with this sport and name in `history`, newest first (finished sessions with at least one block).
    static func sessions(sport: RacketSport, name: String, history: [WorkoutSession]) -> [(date: Date, ex: SessionExercise)] {
        let key = RacketStats.normalize(name)
        return history.filter { !$0.isActive }.sorted { $0.startedAt > $1.startedAt }.compactMap { s in
            guard let ex = s.exercises.last(where: {
                $0.isRacketDrill && $0.racketSport == sport && RacketStats.normalize($0.displayName ?? "") == key
                    && !$0.sets.isEmpty
            }) else { return nil }
            return (s.startedAt, ex)
        }
    }

    /// Never done before: SetupFirst.
    static func isFirstTime(sport: RacketSport, name: String, history: [WorkoutSession]) -> Bool {
        sessions(sport: sport, name: name, history: history).isEmpty
    }

    /// A drill session's number for its measure: longest rally (shots), made / tried (%), or total time (seconds).
    static func value(_ sets: [SetLog], measure: RacketDrillMeasure) -> Int? {
        switch measure {
        case .longestRally: return sets.compactMap(\.longestRally).max()
        case .madeTried:
            let made = sets.compactMap(\.drillMade).reduce(0, +), tried = sets.compactMap(\.drillTried).reduce(0, +)
            return RacketScoring.accuracy(made: made, tried: tried).map { Int(($0 * 100).rounded()) }
        case .time:
            let t = sets.compactMap(\.durationSec).reduce(0, +)
            return t > 0 ? Int(t) : nil
        }
    }

    /// The last session's number ("Last time 24").
    static func lastValue(sport: RacketSport, name: String, measure: RacketDrillMeasure, history: [WorkoutSession]) -> Int? {
        sessions(sport: sport, name: name, history: history).lazy.compactMap { value($0.ex.sets, measure: measure) }.first
    }

    /// The best over every past session.
    static func best(sport: RacketSport, name: String, measure: RacketDrillMeasure, history: [WorkoutSession]) -> Int? {
        sessions(sport: sport, name: name, history: history).compactMap { value($0.ex.sets, measure: measure) }.max()
    }
}

// MARK: - Library (DrillLibrary / XxDrills)

struct RacketDrillLibraryItem: Equatable, Sendable, Identifiable {
    var name: String
    var measure: RacketDrillMeasure
    var categories: [String]
    var id: String { name }

    /// "Video helps" (a count you can check on video) or "Timer" (a timed drill).
    var tag: String { measure == .time ? "Timer" : "Video helps" }
}

enum RacketDrillLibrary {
    /// The category chips after All / Recent.
    static func categories(_ sport: RacketSport) -> [String] {
        switch sport {
        case .tableTennis: return ["Serve", "Receive", "Forehand", "Backhand", "Footwork", "Multiball", "Game-like"]
        case .badminton: return ["Serve", "Net play", "Smash", "Clear", "Footwork"]
        case .tennis: return ["Serve", "Forehand", "Backhand", "Volley", "Footwork"]
        case .pickleball: return ["Dink", "Drop", "Serve", "Transition"]
        case .padel: return ["Overhead", "Wall", "Volley", "Lob"]
        case .squash: return ["Length", "Volley", "Boast", "Solo", "Ghosting"]
        }
    }

    static let all = "All"
    static let recent = "Recent"

    /// The boards' drills per sport, in their order.
    static func items(_ sport: RacketSport) -> [RacketDrillLibraryItem] {
        func d(_ n: String, _ m: RacketDrillMeasure, _ c: [String]) -> RacketDrillLibraryItem { .init(name: n, measure: m, categories: c) }
        switch sport {
        case .tableTennis:
            return [d("Forehand loop vs block", .longestRally, ["Forehand", "Game-like"]),
                    d("Forehand–backhand switch", .longestRally, ["Forehand", "Backhand", "Footwork"]),
                    d("Backhand block consistency", .longestRally, ["Backhand"]),
                    d("Short backspin serve", .madeTried, ["Serve"]),
                    d("Third-ball attack", .madeTried, ["Serve", "Game-like"]),
                    d("Multiball — backhand flick", .madeTried, ["Multiball", "Backhand", "Receive"]),
                    d("Falkenberg footwork", .time, ["Footwork"]),
                    d("Shadow play", .time, ["Footwork"])]
        case .badminton:
            return [d("Drive rally", .longestRally, ["Net play"]), d("Low serve", .madeTried, ["Serve"]),
                    d("Clears — length", .madeTried, ["Clear"]), d("Net kills", .madeTried, ["Net play"]),
                    d("Six-corner footwork", .time, ["Footwork"]), d("Smash & defend", .time, ["Smash"])]
        case .tennis:
            return [d("Cross-court forehand rally", .longestRally, ["Forehand"]), d("First serve in", .madeTried, ["Serve"]),
                    d("Second serve kick", .madeTried, ["Serve"]), d("Backhand down the line", .madeTried, ["Backhand"]),
                    d("Volley at the net", .longestRally, ["Volley"]), d("Split-step footwork", .time, ["Footwork"])]
        case .pickleball:
            return [d("Dinking rally", .longestRally, ["Dink"]), d("Third-shot drop", .madeTried, ["Drop"]),
                    d("Deep serve", .madeTried, ["Serve"]), d("Reset from transition", .madeTried, ["Transition"]),
                    d("Speed-up & counter", .time, ["Transition"])]
        case .padel:
            return [d("Net volley rally", .longestRally, ["Volley"]), d("Bandeja", .madeTried, ["Overhead"]),
                    d("Wall rebound (bajada)", .madeTried, ["Wall", "Overhead"]), d("Vibora", .madeTried, ["Overhead"]),
                    d("Lob & cover", .time, ["Lob"])]
        case .squash:
            return [d("Boast–drive", .longestRally, ["Boast", "Length"]), d("Straight drive length", .madeTried, ["Length"]),
                    d("Volley drop", .madeTried, ["Volley"]), d("Ghosting", .time, ["Ghosting"]),
                    d("Solo rally", .longestRally, ["Solo"])]
        }
    }

    /// The rows for a chip and a search: catalog drills plus your own (not in the catalog) after them.
    static func filtered(_ sport: RacketSport, category: String, query: String, recent: [RacketDrillLibraryItem])
        -> [RacketDrillLibraryItem] {
        let catalog = items(sport)
        let names = Set(catalog.map { RacketStats.normalize($0.name) })
        let yours = recent.filter { !names.contains(RacketStats.normalize($0.name)) }
        let q = RacketStats.normalize(query)
        let base: [RacketDrillLibraryItem]
        switch category {
        case all: base = catalog + yours
        case Self.recent: base = recent
        default: base = catalog.filter { $0.categories.contains(category) }
        }
        return base.filter { q.isEmpty || RacketStats.normalize($0.name).contains(q) }
    }

    /// Squash's solo drill opens SqSolo ("Just you on court").
    static func isSolo(sport: RacketSport, name: String, practising: String?) -> Bool {
        sport == .squash && (RacketStats.normalize(name) == RacketStats.normalize("Solo rally") || practising == "Solo")
    }

    /// The Recent row's detail: "Longest rally · last 18 shots".
    static func recentDetail(_ measure: RacketDrillMeasure, last: Int?) -> String {
        guard let last else { return measure.label }
        switch measure {
        case .longestRally: return "\(measure.label) · last \(last) shots"
        case .madeTried: return "\(measure.label) · last \(last)%"
        case .time: return "\(measure.label) · last \(RacketClock.mmss(TimeInterval(last)))"
        }
    }
}

// MARK: - Feel (Easy / About right / Hard)

enum RacketDrillFeel: String, Codable, CaseIterable, Sendable {
    case easy, aboutRight, hard

    var label: String {
        switch self {
        case .easy: return "Easy"
        case .aboutRight: return "About right"
        case .hard: return "Hard"
        }
    }
}

extension SetLog {
    var drillFeel: RacketDrillFeel? { drillFeelRaw.flatMap(RacketDrillFeel.init(rawValue:)) }
}

// MARK: - Copy on the drill screens

enum RacketDrillCopy {
    /// The block header's left side: "● Recording 03:12" (block by block), "● Recording everything", "Not recording".
    enum Status: Equatable { case recording(seconds: TimeInterval), recordingEverything, paused, notRecording, startingSoon }

    static func statusText(_ s: Status) -> String {
        switch s {
        case .recording(let sec): return "● Recording \(RacketClock.recordingHeader(sec))"
        case .recordingEverything: return "● Recording everything"
        case .paused: return "Ⅱ Recording paused"
        case .notRecording: return "Not recording"
        case .startingSoon: return "Starting soon"
        }
    }

    /// BlockOff's line under the ring.
    static func blockLine(measure: RacketDrillMeasure, recording: RacketRecordingMode) -> String {
        let lead = recording == .off ? "Not filming." : "Recording."
        switch measure {
        case .longestRally:
            return recording == .off ? "\(lead) Log your longest rally at the end of the block."
                : "\(lead) Log your longest rally at the end of the block, or find rallies afterwards."
        case .madeTried:
            return recording == .off ? "\(lead) Log made and tried at the end of the block."
                : "\(lead) Log made and tried at the end of the block, or find rallies afterwards."
        case .time:
            return "\(lead) The block is logged from its timer."
        }
    }

    /// BlockAll's footnote.
    static let everythingFootnote = "Blocks and rests are marked from your timers, so there’s nothing to split by hand."

    /// Paused: table tennis says why you'd pause; the others keep it short.
    static func pausedLine(_ sport: RacketSport) -> String {
        sport == .tableTennis ? "Picking up balls or taking a call? Nothing is recorded or counted while paused."
                              : "Nothing is recorded or counted while paused."
    }

    /// The rest ring's caption: "Block 3 starts by itself after this".
    static func restCaption(next: Int, autoStart: Bool) -> String {
        autoStart ? "Block \(next) starts by itself after this" : "Auto-start is off: you start the next block yourself"
    }

    /// The countdown's line.
    static func countdownLine(recording: RacketRecordingMode, firstOfRun: Bool) -> String {
        switch recording {
        case .off: return "The block timer starts at zero"
        case .everything where !firstOfRun: return "Still recording. The block timer starts at zero."
        default: return "Recording and the block timer start at zero"
        }
    }

    /// Under Wait.
    static func waitLine(firstOfRun: Bool) -> String {
        firstOfRun ? "Wait goes back to the camera." : "Wait returns to a paused rest timer."
    }

    /// The rest's logging source line: the model's suggestion only when a scan of this block found rallies (it never has
    /// during the drill: scans run afterwards), else "You enter this".
    static func logSource(scanFound: Bool) -> String { scanFound ? "Suggested from video" : "You enter this" }

    /// "Find rallies after the drill" was tapped: the block's number waits for the scan.
    static let findAfterLine = "Rallies will be found after the drill"
}

// MARK: - Review (PracticeReview)

struct RacketDrillReview: Equatable, Sendable {
    struct Bar: Equatable, Sendable {
        var label: String
        var value: Double
        var text: String
        var best: Bool
    }
    struct Bucket: Equatable, Sendable {
        var label: String
        var count: Int
    }

    var headlineTitle: String
    /// "19 shots" / "76%" / "15:00"; nil before any number is logged.
    var headline: String?
    var lastTime: String?
    var newBest: Bool
    var bars: [Bar]
    var rallies: Int
    var buckets: [Bucket]
    /// "3 blocks · 3 clips" / "3 blocks · no video".
    var blocksLine: String

    /// - Parameters:
    ///   - sets: this drill's blocks.
    ///   - last: last session's number (`RacketDrillHistory.lastValue`); `best`: the best before this session.
    static func make(sets: [SetLog], measure: RacketDrillMeasure, last: Int?, best: Int?, log: RacketRecordingLog?)
        -> RacketDrillReview {
        let value = RacketDrillHistory.value(sets, measure: measure)
        let newBest = value.map { v in best.map { v > $0 } ?? false } ?? false
        var bars: [Bar] = []
        for (i, s) in sets.enumerated() {
            let label = "Block \(i + 1)"
            switch measure {
            case .longestRally:
                let v = s.longestRally ?? 0
                bars.append(.init(label: label, value: Double(v), text: s.longestRally.map(String.init) ?? "–", best: false))
            case .madeTried:
                let acc = s.drillTried.flatMap { t in s.drillMade.flatMap { RacketScoring.accuracy(made: $0, tried: t) } }
                bars.append(.init(label: label, value: (acc ?? 0) * 100, text: acc.map(RacketStats.percent) ?? "–", best: false))
            case .time:
                let t = s.durationSec ?? 0
                bars.append(.init(label: label, value: t, text: RacketClock.mmss(t), best: false))
            }
        }
        if newBest, measure != .time, let top = bars.map(\.value).max(), let i = bars.lastIndex(where: { $0.value == top }) {
            bars[i].best = true
        }
        let headline: String? = value.map { v in
            switch measure {
            case .longestRally: return "\(v) shots"
            case .madeTried: return "\(v)%"
            case .time: return RacketClock.mmss(TimeInterval(v))
            }
        }
        let rallies = (log?.allRallies ?? []).filter(\.isRally)
        let n = sets.count
        let clips = log.map { l in l.runs.filter { ($0.endSec ?? .infinity) > $0.startSec }.count } ?? 0
        let blocksLine = "\(n) \(n == 1 ? "block" : "blocks") · " + (log == nil ? "no video"
            : l(clips, "clip", "clips"))
        return RacketDrillReview(headlineTitle: measure.label, headline: headline,
                                 lastTime: RacketDrillGoal.lastTime(last, measure: measure),
                                 newBest: newBest, bars: bars, rallies: rallies.count,
                                 buckets: buckets(rallies.map(\.durationSec)), blocksLine: blocksLine)
    }

    private static func l(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// Rally lengths from video. The boards bucket by shots; with no shot count yet (Capabilities: Shot count is not
    /// available), the buckets are seconds, labelled so.
    static func buckets(_ durations: [Double]) -> [Bucket] {
        let edges: [(String, ClosedRange<Double>)] = [("1–4 s", 0...4.999), ("5–9 s", 5...9.999), ("10–14 s", 10...14.999),
                                                      ("15 s+", 15...Double.greatestFiniteMagnitude)]
        return edges.map { e in Bucket(label: e.0, count: durations.filter { e.1.contains($0) }.count) }
    }
}

// MARK: - Progress (DrillTrend)

enum RacketDrillTrend {
    enum Metric: String, CaseIterable, Sendable { case measure, ralliesPerBlock }

    struct Point: Equatable, Sendable, Identifiable {
        var id: Int
        var date: Date
        var value: Double
        var label: String
        var isToday: Bool
    }

    struct Summary: Equatable, Sendable {
        var points: [Point]
        var best: Double?
        var average: Double?
        var sessions: Int
        var bestYet: Bool
    }

    /// The last five sessions of this drill (past ones from history, then today's), oldest first.
    static func summary(sport: RacketSport, name: String, measure: RacketDrillMeasure, metric: Metric,
                        history: [WorkoutSession], today: SessionExercise?, now: Date, calendar: Calendar = .current)
        -> Summary {
        let past = RacketDrillHistory.sessions(sport: sport, name: name, history: history)
        var all: [(date: Date, ex: SessionExercise, today: Bool)] = past.map { ($0.date, $0.ex, false) }.reversed()
        if let today, !today.sets.isEmpty { all.append((now, today, true)) }
        func v(_ ex: SessionExercise) -> Double? {
            switch metric {
            case .measure: return RacketDrillHistory.value(ex.sets, measure: measure).map(Double.init)
            case .ralliesPerBlock:
                guard let log = ex.racketRecordingLog, !ex.sets.isEmpty else { return nil }
                let n = log.allRallies.filter(\.isRally).count
                return Double(n) / Double(ex.sets.count)
            }
        }
        let valued = all.compactMap { e in v(e.ex).map { (e.date, $0, e.today) } }
        let last5 = Array(valued.suffix(5))
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.dateFormat = "MMM d"
        let points = last5.enumerated().map { i, e in
            Point(id: i, date: e.0, value: e.1,
                  label: e.2 || calendar.isDate(e.0, inSameDayAs: now) ? "Today" : fmt.string(from: e.0), isToday: e.2)
        }
        let values = last5.map(\.1)
        let best = valued.map(\.1).max()
        let bestYet = (points.last.map { p in p.isToday && p.value >= (best ?? 0) && valued.count > 1 }) ?? false
        return Summary(points: points, best: best,
                       average: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                       sessions: valued.count, bestYet: bestYet)
    }

    /// "Hard → About right over the last 3 sessions": the most common feel per session (the latest when tied).
    static func feelLine(sport: RacketSport, name: String, history: [WorkoutSession], today: SessionExercise?) -> String? {
        var sessions = RacketDrillHistory.sessions(sport: sport, name: name, history: history).map(\.ex).reversed()
            .map { $0 }
        if let today { sessions.append(today) }
        let feels: [RacketDrillFeel] = sessions.suffix(3).compactMap { ex in
            let f = ex.sets.compactMap(\.drillFeel)
            guard !f.isEmpty else { return nil }
            return RacketDrillFeel.allCases.max { a, b in f.filter { $0 == a }.count < f.filter { $0 == b }.count }
        }
        guard let first = feels.first, let last = feels.last else { return nil }
        let span = "over the last \(feels.count) \(feels.count == 1 ? "session" : "sessions")"
        return first == last ? "\(last.label) \(span)" : "\(first.label) → \(last.label) \(span)"
    }

    /// "15.2" (one decimal), "19" (whole).
    static func number(_ v: Double) -> String {
        v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

// MARK: - Court zones (Customize "From / To")

enum RacketCourtZoneRule {
    /// DrillCustomize's diagram: From in the middle row left of the net, To in the top row across it.
    static let boardDefault: (from: Int?, to: Int?) = (8, 4)

    /// A tap on zone `z`: the first sets From, the next sets To, a third starts again; tapping a chosen zone clears it.
    static func tap(_ z: Int, from: Int?, to: Int?) -> (from: Int?, to: Int?) {
        if z == from { return (to, nil) }
        if z == to { return (from, nil) }
        if from == nil { return (z, to) }
        if to == nil { return (from, z) }
        return (z, nil)
    }
}
