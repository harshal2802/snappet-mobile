import Foundation

// MARK: - Rally marks and tags (prompt 246, issue #438 step 3) — pure
//
// With no model yet (rally finding is step 5), the player marks rallies by hand on a part's timeline (Mark start /
// Mark end) and tags them: who won, how it ended (per sport, optional), and in doubles who made the last shot. Tags
// show in "From your tags" and count in history. Boards: TtNoModelTimeline, TtNoModelTag (+ Bd/Tn/Pb/Pd/Sq),
// DoublesTag, Timeline, FixRally, TtTagDone, TtManualSummary. Tested in `RacketRallyTagsTests`.

/// Who won a rally.
enum RacketRallyWinner: String, Codable, CaseIterable, Sendable { case us, them }

/// How a rally ended. One vocabulary; each sport offers its own list, in the boards' order.
enum RacketRallyEnding: String, Codable, CaseIterable, Sendable {
    case landedIn, winner, out, net, tin, notUp, doubleBounce, serveFault, serviceFault, doubleFault, kitchenFault,
         twoBounceFault, hitWallFirst, edgeBall, missedSwing, missedShot, hitPlayer, letReplay, stroke, noLet, interrupted

    var label: String {
        switch self {
        case .landedIn: return "Landed in"
        case .winner: return "Winner"
        case .out: return "Out"
        case .net: return "Net"
        case .tin: return "Tin"
        case .notUp: return "Not up"
        case .doubleBounce: return "Double bounce"
        case .serveFault: return "Serve fault"
        case .serviceFault: return "Service fault"
        case .doubleFault: return "Double fault"
        case .kitchenFault: return "Kitchen fault"
        case .twoBounceFault: return "Two-bounce fault"
        case .hitWallFirst: return "Hit wall first"
        case .edgeBall: return "Edge ball"
        case .missedSwing: return "Missed swing"
        case .missedShot: return "Missed shot"
        case .hitPlayer: return "Hit player"
        case .letReplay: return "Let (replay)"
        case .stroke: return "Stroke"
        case .noLet: return "No let"
        case .interrupted: return "Interrupted"
        }
    }

    /// The boards' "How did it end?" chips per sport (XxTag / XxNoModelTag).
    static func choices(for sport: RacketSport) -> [RacketRallyEnding] {
        switch sport {
        case .tableTennis: return [.out, .net, .doubleBounce, .serveFault, .letReplay, .edgeBall, .missedSwing, .interrupted]
        case .badminton: return [.landedIn, .out, .net, .serviceFault, .missedShot, .hitPlayer, .letReplay, .interrupted]
        case .tennis: return [.winner, .out, .net, .doubleBounce, .doubleFault, .missedShot, .letReplay, .interrupted]
        case .pickleball: return [.winner, .out, .net, .doubleBounce, .kitchenFault, .twoBounceFault, .serviceFault, .interrupted]
        case .padel: return [.winner, .out, .net, .doubleBounce, .hitWallFirst, .doubleFault, .letReplay, .interrupted]
        case .squash: return [.winner, .tin, .out, .notUp, .serviceFault, .letReplay, .stroke, .noLet]
        }
    }

    /// A let is replayed: the rally is kept as a rally, but no one wins the point.
    var isReplay: Bool { self == .letReplay || self == .interrupted }
}

/// One rally: a time range on a recording (seconds from its start), and its tags.
struct RacketRally: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var startSec: Double
    var endSec: Double
    var winnerRaw: String?
    var endingRaw: String?
    /// Doubles: who made the last shot ("You", "Mia", "Jordan", "Lee"); optional.
    var lastShotBy: String?
    /// "Not a rally" (picking up the ball, knocking): kept so it isn't marked again, never counted.
    var notRally: Bool?
    /// Who marked it: nil / "you"; `"ai:<app>"` when it came from another AI app's reply (prompt 247,
    /// `RacketAISource`). A model's rallies (step 5) will say which model — your tags always win.
    var sourceRaw: String?
    /// Who set its winner / ending: nil = you; `"ai:<app>"` when you accepted another app's answer on Compare. Tagging it
    /// yourself clears it (prompt 247).
    var tagSourceRaw: String?
    /// Shots the other app counted (its "shots" list), shown on Compare ("Yes, 5 shots"). Not used for stats.
    var aiShots: Int?
    // Step 5 (prompt 248): a model's guess (`sourceRaw = "model:<id>@<version>"`).
    /// How sure the model was, 0…1; below `RacketRallyGuessMerge.unsureBelow` it's "unsure".
    var confidence: Double?
    /// The winner the model suggests (from a score tap): shown "· suggested" on the tag sheet, never counted as a tag.
    var guessWinnerRaw: String?
    /// You tagged, checked or fixed this guess: it's yours now and counts in history.
    var confirmed: Bool?
    // Prompt 251 — additive Optionals.
    /// FixRally "What went wrong? Optional" (`RacketFixReason.rawValue`), kept for model feedback.
    var fixReasonsRaw: [String]?
    /// ShotTags / DoublesShots: every shot of the rally, tagged by hand (no shot finding yet).
    var shots: [RacketShot]?
    // Prompt 252 — additive Optionals.
    /// TnServe "How did the serve go?" (`RacketServeOutcome.rawValue`).
    var serveRaw: String?
    /// PdWall "Did the ball bounce first?" (`RacketWallBounce.rawValue`).
    var wallRaw: String?

    init(id: UUID = UUID(), startSec: Double, endSec: Double, winner: RacketRallyWinner? = nil,
         ending: RacketRallyEnding? = nil, lastShotBy: String? = nil, notRally: Bool? = nil) {
        self.id = id
        self.startSec = startSec
        self.endSec = endSec
        self.winnerRaw = winner?.rawValue
        self.endingRaw = ending?.rawValue
        self.lastShotBy = lastShotBy
        self.notRally = notRally
    }

    var winner: RacketRallyWinner? {
        get { winnerRaw.flatMap(RacketRallyWinner.init(rawValue:)) }
        set { winnerRaw = newValue?.rawValue }
    }
    var ending: RacketRallyEnding? {
        get { endingRaw.flatMap(RacketRallyEnding.init(rawValue:)) }
        set { endingRaw = newValue?.rawValue }
    }
    var serve: RacketServeOutcome? { serveRaw.flatMap(RacketServeOutcome.init(rawValue:)) }
    var wall: RacketWallBounce? { wallRaw.flatMap(RacketWallBounce.init(rawValue:)) }
    var durationSec: Double { max(0, endSec - startSec) }
    var isRally: Bool { notRally != true }
    /// Tagged = a winner picked (or a replay — no winner to pick).
    var isTagged: Bool { isRally && (winner != nil || ending?.isReplay == true) }
    /// It, or its tags, came from another AI app (accepted by you on Compare).
    var isFromAI: Bool { RacketAISource.isAI(sourceRaw) || RacketAISource.isAI(tagSourceRaw) }
    /// The app's name when it came from one.
    var aiName: String? { RacketAISource.name(tagSourceRaw) ?? RacketAISource.name(sourceRaw) }
    /// Found by a model.
    var isFromModel: Bool { RacketModelSource.isModel(sourceRaw) }
    /// A model's guess you haven't tagged, checked or fixed yet ("Snappet guess"). Replaced by a re-scan; doesn't
    /// count in history.
    var isGuess: Bool { isFromModel && confirmed != true && !isTagged && notRally != true }
    /// A guess the model wasn't sure of (dashed; "Check N unsure rallies").
    var isUnsure: Bool { isGuess && (confidence ?? 1) < RacketRallyGuessMerge.unsureBelow }
    var guessWinner: RacketRallyWinner? { guessWinnerRaw.flatMap(RacketRallyWinner.init(rawValue:)) }
}

// MARK: - Marking (TtNoModelTimeline: Mark start / Mark end · FixRally)

enum RacketRallyMarking {
    /// A rally shorter than this is a mis-tap.
    static let minRallySec: Double = 0.5

    enum Problem: Error, Equatable, Sendable {
        case noStart
        case tooShort
        case overlaps
    }

    /// Mark end at `t` for a rally started at `start`, inside the part `[lo, hi]`. Ends before the start swap (you can
    /// mark either edge first). Rejected when shorter than `minRallySec` or overlapping another rally.
    static func rally(start: Double?, end t: Double, within lo: Double, _ hi: Double,
                      existing: [RacketRally]) -> Result<RacketRally, Problem> {
        guard let start else { return .failure(.noStart) }
        let a = min(max(lo, min(start, t)), hi), b = min(max(lo, max(start, t)), hi)
        guard b - a >= minRallySec else { return .failure(.tooShort) }
        if overlaps(a, b, existing, except: nil) { return .failure(.overlaps) }
        return .success(RacketRally(startSec: a, endSec: b))
    }

    static func overlaps(_ a: Double, _ b: Double, _ rallies: [RacketRally], except id: UUID?) -> Bool {
        rallies.contains { $0.id != id && $0.startSec < b - 0.01 && $0.endSec > a + 0.01 }
    }

    /// Insert keeping time order.
    static func insert(_ r: RacketRally, into rallies: [RacketRally]) -> [RacketRally] {
        (rallies + [r]).sorted { $0.startSec < $1.startSec }
    }

    /// FixRally: move a rally's edges, clamped to the part and its neighbours; `nil` when it can't fit.
    static func fix(_ rallies: [RacketRally], id: UUID, start: Double, end: Double,
                    within lo: Double, _ hi: Double) -> [RacketRally]? {
        guard let i = rallies.firstIndex(where: { $0.id == id }) else { return nil }
        let a = min(max(lo, start), hi), b = min(max(lo, end), hi)
        guard b - a >= minRallySec, !overlaps(a, b, rallies, except: id) else { return nil }
        var out = rallies
        out[i].startSec = a
        out[i].endSec = b
        // Fixing a guess's edges means you've looked at it (prompt 248).
        if out[i].isFromModel { out[i].confirmed = true }
        return out.sorted { $0.startSec < $1.startSec }
    }

    /// FixRally "Split in two" at the middle (or `t`).
    static func splitInTwo(_ rallies: [RacketRally], id: UUID, at t: Double? = nil) -> [RacketRally] {
        guard let i = rallies.firstIndex(where: { $0.id == id }) else { return rallies }
        let r = rallies[i]
        let mid = t ?? (r.startSec + r.endSec) / 2
        guard mid - r.startSec >= minRallySec, r.endSec - mid >= minRallySec else { return rallies }
        var first = r
        first.endSec = mid
        let second = RacketRally(startSec: mid, endSec: r.endSec)
        var out = rallies
        out.replaceSubrange(i...i, with: [first, second])
        return out
    }

    /// FixRally "Merge with next": the next rally (in time) folds in; this one keeps its tags.
    static func mergeWithNext(_ rallies: [RacketRally], id: UUID) -> [RacketRally] {
        let sorted = rallies.sorted { $0.startSec < $1.startSec }
        guard let i = sorted.firstIndex(where: { $0.id == id }), i + 1 < sorted.count else { return rallies }
        var out = sorted
        out[i].endSec = max(out[i].endSec, out[i + 1].endSec)
        out.remove(at: i + 1)
        return out
    }

    /// The rallies inside `[lo, hi)` (a part), in time order.
    static func inRange(_ rallies: [RacketRally], _ lo: Double, _ hi: Double) -> [RacketRally] {
        rallies.filter { $0.startSec >= lo - 0.01 && $0.startSec < hi }.sorted { $0.startSec < $1.startSec }
    }

    /// "Check N unsure rallies": the next unsure guess after `id`, wrapping round.
    static func nextUnsure(_ rallies: [RacketRally], after id: UUID?) -> RacketRally? {
        let rs = rallies.filter(\.isRally).sorted { $0.startSec < $1.startSec }
        guard !rs.isEmpty else { return nil }
        let start = id.flatMap { cur in rs.firstIndex { $0.id == cur }.map { $0 + 1 } } ?? 0
        for k in 0..<rs.count {
            let r = rs[(start + k) % rs.count]
            if r.isUnsure && r.id != id { return r }
        }
        return nil
    }

    /// The next rally to tag after `id` (or from the start): the first one with no tag, wrapping round.
    static func nextUntagged(_ rallies: [RacketRally], after id: UUID?) -> RacketRally? {
        let rs = rallies.filter(\.isRally)
        guard !rs.isEmpty else { return nil }
        let start = id.flatMap { cur in rs.firstIndex { $0.id == cur }.map { $0 + 1 } } ?? 0
        for k in 0..<rs.count {
            let r = rs[(start + k) % rs.count]
            if !r.isTagged && r.id != id { return r }
        }
        return nil
    }

    /// Apply a tag (TtNoModelTag "Next"): winner, optional ending and last shot. "Not a rally" clears the tags.
    /// `serve` / `wall` (TnServe / PdWall, prompt 252): `.some(nil)` clears, `nil` keeps what's there.
    static func tag(_ rallies: [RacketRally], id: UUID, winner: RacketRallyWinner?, ending: RacketRallyEnding?,
                    lastShotBy: String?, notRally: Bool, serve: RacketServeOutcome?? = nil,
                    wall: RacketWallBounce?? = nil) -> [RacketRally] {
        rallies.map { r in
            guard r.id == id else { return r }
            var q = r
            q.notRally = notRally ? true : nil
            q.winner = notRally ? nil : winner
            q.ending = notRally ? nil : ending
            q.lastShotBy = notRally ? nil : lastShotBy
            if let serve { q.serveRaw = notRally ? nil : serve?.rawValue }
            if let wall { q.wallRaw = notRally ? nil : wall?.rawValue }
            // Tagged by you now, whoever tagged it before (prompt 247).
            q.tagSourceRaw = nil
            // A model's guess you've checked is yours now (prompt 248).
            if q.isFromModel { q.confirmed = true }
            return q
        }
    }
}

// MARK: - From your tags (TtManualSummary · TtTagDone)

struct RacketTagSummary: Equatable, Sendable {
    struct EndingCount: Equatable, Sendable {
        var ending: RacketRallyEnding
        var count: Int
    }

    /// Rallies you marked ("Not a rally" excluded).
    var marked: Int
    /// With a winner (or a replay).
    var tagged: Int
    var longestSec: Double?
    var averageSec: Double?
    var wonUs: Int
    var wonThem: Int
    /// Most common first; ties in the sport's order.
    var endings: [EndingCount]
    /// Rallies (or their tags) accepted from another AI app on Compare (prompt 247). They count like your tags — you
    /// chose them — and the summary says where they came from.
    var fromAI: Int = 0
    /// The apps they came from, in first-seen order.
    var aiNames: [String] = []

    var untagged: Int { max(0, marked - tagged) }

    /// "From your tags, 3 of 5"; "From your tags, 5 of 7 · 2 accepted from ChatGPT".
    var sourceLine: String {
        let base = "From your tags, \(tagged) of \(marked)"
        guard fromAI > 0 else { return base }
        return base + " · \(fromAI) accepted from \(aiNames.count == 1 ? aiNames[0] : "other apps")"
    }

    static func make(_ rallies: [RacketRally], sport: RacketSport) -> RacketTagSummary {
        let rs = rallies.filter(\.isRally)
        let durations = rs.map(\.durationSec).filter { $0 > 0 }
        var counts: [RacketRallyEnding: Int] = [:]
        for r in rs { if let e = r.ending { counts[e, default: 0] += 1 } }
        let order = RacketRallyEnding.choices(for: sport) + RacketRallyEnding.allCases
        let endings = counts.map { EndingCount(ending: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count
                : (order.firstIndex(of: $0.ending) ?? 99) < (order.firstIndex(of: $1.ending) ?? 99)
        }
        return RacketTagSummary(
            marked: rs.count,
            tagged: rs.filter(\.isTagged).count,
            longestSec: durations.max(),
            averageSec: durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count),
            wonUs: rs.filter { $0.winner == .us }.count,
            wonThem: rs.filter { $0.winner == .them }.count,
            endings: endings,
            fromAI: rs.filter(\.isFromAI).count,
            aiNames: rs.compactMap(\.aiName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
    }

    /// "9.4 s".
    static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }

    /// TagDone headline: "3 of 5 checked".
    var checkedLine: String { "\(tagged) of \(marked) checked" }
}

// MARK: - Playback policy (PlayerOriginal: −10 s / +10 s, Rallies only)

enum RacketPlaybackPolicy {
    /// Clamp a seek into the part.
    static func clamp(_ t: Double, _ lo: Double, _ hi: Double) -> Double { min(max(lo, t), hi) }

    /// "Rallies only": where to be at `t`. Inside a rally ⇒ `nil` (keep playing); between rallies ⇒ the next rally's
    /// start; after the last ⇒ `.end` (pause).
    enum Jump: Equatable, Sendable { case to(Double), end }

    static func ralliesOnly(at t: Double, rallies: [RacketRally]) -> Jump? {
        let rs = rallies.filter(\.isRally).sorted { $0.startSec < $1.startSec }
        guard !rs.isEmpty else { return nil }
        if rs.contains(where: { t >= $0.startSec - 0.05 && t < $0.endSec }) { return nil }
        if let next = rs.first(where: { $0.startSec > t }) { return .to(next.startSec) }
        return .end
    }

    /// The rally at `t` and its 1-based number among the part's rallies ("Rally 12").
    static func rally(at t: Double, in rallies: [RacketRally]) -> (number: Int, rally: RacketRally)? {
        let rs = rallies.filter(\.isRally).sorted { $0.startSec < $1.startSec }
        guard let i = rs.firstIndex(where: { t >= $0.startSec && t < $0.endSec }) else { return nil }
        return (i + 1, rs[i])
    }

    /// The running score from your tags up to (and including) rally `number` — the Analyzed view's "7–5".
    static func runningScore(through number: Int, in rallies: [RacketRally]) -> (us: Int, them: Int) {
        let rs = rallies.filter(\.isRally).sorted { $0.startSec < $1.startSec }.prefix(max(0, number))
        return (rs.filter { $0.winner == .us }.count, rs.filter { $0.winner == .them }.count)
    }

    /// The analysed overlay line for a rally: "Rally 12 · You won · Out".
    static func overlayLine(number: Int, rally: RacketRally, sides: (us: String, them: String)) -> String {
        var parts = ["Rally \(number)"]
        if let w = rally.winner { parts.append(w == .us ? "\(sides.us) won" : "\(sides.them) won") }
        if let e = rally.ending { parts.append(e.label) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Tags count in history

/// What your tags add to history and trends (the summary says "These count in your history and trends like any other
/// numbers"): rallies tagged, points won from your tags, the longest rally you marked.
struct RacketTagTotals: Equatable, Sendable {
    var marked = 0
    var tagged = 0
    var wonUs = 0
    var wonThem = 0
    var longestSec: Double?
    /// Of `marked`, how many came (or were tagged) from another AI app and were accepted by you (prompt 247).
    var fromAI = 0

    var pointsWonShare: Double? {
        let n = wonUs + wonThem
        return n > 0 ? Double(wonUs) / Double(n) : nil
    }

    static func of(_ exercises: [SessionExercise]) -> RacketTagTotals {
        var t = RacketTagTotals()
        for ex in exercises where ex.discipline == .racket {
            // A model's guesses count once you've confirmed them (prompt 248): "Estimated from video until you confirm".
            let rs = (ex.racketRecordingLog?.rallies ?? []).filter { $0.isRally && !$0.isGuess }
            t.marked += rs.count
            t.tagged += rs.filter(\.isTagged).count
            t.wonUs += rs.filter { $0.winner == .us }.count
            t.wonThem += rs.filter { $0.winner == .them }.count
            t.fromAI += rs.filter(\.isFromAI).count
            if let m = rs.map(\.durationSec).max() { t.longestSec = max(t.longestSec ?? 0, m) }
        }
        return t
    }
}
