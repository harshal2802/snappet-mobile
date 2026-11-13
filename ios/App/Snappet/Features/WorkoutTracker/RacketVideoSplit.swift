import Foundation

// MARK: - Racket video split (prompt 246, issue #438 step 3) — pure
//
// A whole-match recording becomes games, breaks and so on as **time ranges on the original** (non-destructive: no
// new video is made until the user deletes the original, and that delete is confirmed). This file holds the parts,
// the proposal from the step-1 / step-2 marks, range editing, the part ↔ game assignment, the mapping from a
// recording-time range to the Photos parts that hold it, and the space numbers for "Delete the long original" and
// "Keep rallies only". Foundation only — Photos / AVFoundation live in `Services/RacketVideoLibrary.swift`; tested in
// `RacketVideoSplitTests` with no device.
//
// Boards: TtSplitPrompt, TtSplitReview, TtSplitEdit, TtSplitAssign, TtSplitDone, TtDeleteOriginal, TtKeepRallies,
// TtOriginalMissing, FindRallies / TtNoModelVideos (Your videos), TtDrillVideos.

// MARK: - Parts

/// What a stretch of a recording is. Only games and drill blocks count toward stats.
enum RacketPartKind: String, Codable, CaseIterable, Sendable {
    case warmup, game, breakTime, drillBlock, rest, notPlay
    /// Rallies with no score: "an extra game or practice?" until the player says which.
    case unsure

    func label(unit: RacketUnit) -> String {
        switch self {
        case .warmup: return "Warmup"
        case .game: return unit.noun.capitalized
        case .breakTime: return "Break"
        case .drillBlock: return "Drill block"
        case .rest: return "Rest"
        case .notPlay: return "Not play"
        case .unsure: return "Rallies, no score"
        }
    }

    /// Counted in stats and history (TtSplitReview "Matched"); the rest are "Not counted" (or "Unsure").
    var counts: Bool { self == .game || self == .drillBlock }

    /// The choices on "What is this part?" (TtSplitEdit).
    static let editChoices: [RacketPartKind] = [.warmup, .game, .breakTime, .drillBlock, .rest, .notPlay]
}

/// Where an unsure stretch belongs (TtSplitEdit "Belongs to").
enum RacketPartBelongs: String, Codable, CaseIterable, Sendable {
    case thisMatch, practice

    func label(unit: RacketUnit) -> String {
        self == .thisMatch ? "Extra \(unit.noun), this match" : "Practice"
    }
}

/// One part of a recording: a time range on it (seconds from the recording's start).
struct RacketVideoPart: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var kindRaw: String
    var startSec: Double
    var endSec: Double
    /// The game / set (match) or block (drill) this part is the video of — an index into `SessionExercise.sets`.
    var setIndex: Int?
    /// `RacketPartBelongs.rawValue` — "Extra game, this match" turns an unsure stretch into a game of this match.
    var belongsRaw: String?

    init(id: UUID = UUID(), kind: RacketPartKind, startSec: Double, endSec: Double, setIndex: Int? = nil,
         belongs: RacketPartBelongs? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.startSec = startSec
        self.endSec = endSec
        self.setIndex = setIndex
        self.belongsRaw = belongs?.rawValue
    }

    var kind: RacketPartKind {
        get { RacketPartKind(rawValue: kindRaw) ?? .notPlay }
        set { kindRaw = newValue.rawValue }
    }
    var belongs: RacketPartBelongs? {
        get { belongsRaw.flatMap(RacketPartBelongs.init(rawValue:)) }
        set { belongsRaw = newValue?.rawValue }
    }
    var durationSec: Double { max(0, endSec - startSec) }
    /// An extra game the player added from an unsure stretch (TtSplitAssign "Extra game").
    var isExtra: Bool { kind == .game && belongs == .thisMatch }

    func contains(_ t: Double) -> Bool { t >= startSec && t < endSec }
}

/// The applied split of one recording.
struct RacketSplit: Codable, Hashable, Sendable {
    var parts: [RacketVideoPart]
    var appliedAt: Date?

    /// The parts that are games / extra games / drill blocks, in order.
    var countedParts: [RacketVideoPart] { parts.filter { $0.kind.counts } }
}

/// A new Photos video made from a recording (one per part when the original is deleted, or one per kept rally
/// stretch). Its times are on the recording's timeline; the asset itself starts at 0.
struct RacketDerivedVideo: Codable, Hashable, Sendable {
    var localIdentifier: String
    var startSec: Double
    var endSec: Double
}

// MARK: - Recording timeline

extension RacketRecordingLog {
    /// How long the recording runs on its own timeline (gaps between runs included): to its end, else the last run /
    /// part / mark.
    var timelineSec: Double {
        var t = endedAt.map(offset) ?? 0
        t = max(t, runs.compactMap(\.endSec).max() ?? 0)
        t = max(t, assets.map { $0.startSec + ($0.durationSec ?? 0) }.max() ?? 0)
        t = max(t, marks.map { $0.endSec ?? $0.startSec }.max() ?? 0)
        return t
    }

    var baseIndex: Int { max(0, baseSetIndex ?? 0) }
    var quality: RacketRecordingQuality { qualityRaw.flatMap(RacketRecordingQuality.init(rawValue:)) ?? .hd1080 }
    var allRallies: [RacketRally] { rallies ?? [] }
    var isSplit: Bool { split?.appliedAt != nil }
}

// MARK: - Proposal (TtSplitReview: "Found from your Watch taps and new-game marks … and pauses")

/// Proposes the parts of a whole-match recording from what was marked while it recorded: "New game starts" (phone or
/// Watch — a game finished on the Watch adds one), "Break starts", and the first point of each game tapped on the
/// Watch. No model yet (rally activity is step 5), so the rules are simple and every part can be fixed by hand:
/// - a new-game mark starts a game, a break mark starts a break;
/// - a first point on the Watch means play began a little before it (`leadSec`): a stretch of more than `idleSec`
///   with no point before it is a warmup (at the start) or a break (between games);
/// - a break that runs to the end of the recording is "Not play" (packing up);
/// - games beyond what the format allows are "Rallies, no score" (unsure: an extra game or practice?);
/// - with no marks at all, the whole recording is one game.
enum RacketSplitProposal {
    /// Play starts about this long before the first point is tapped (a serve and a rally).
    static let leadSec: Double = 15
    /// No point for longer than this at the start of a game stretch ⇒ that stretch began as a warmup / break.
    static let idleSec: Double = 90
    /// Parts shorter than this fold into their neighbour.
    static let minPartSec: Double = 5

    private enum Event { case newGame, breakStart, firstPoint }

    static func propose(log: RacketRecordingLog, format: RacketFormat) -> [RacketVideoPart] {
        let total = log.timelineSec
        guard total > 0 else { return [] }
        let events: [(Double, Event)] = log.marks.compactMap { m in
            switch m.kind {
            case .newGame: return (m.startSec, .newGame)
            case .breakStart: return (m.startSec, .breakStart)
            case .firstPoint: return (m.startSec, .firstPoint)
            default: return nil
            }
        }
        .filter { $0.0 > 0 && $0.0 < total }
        .sorted { $0.0 < $1.0 }

        // Walk the marks. `pending` is the first stretch before anything is known.
        enum Open { case pending, game(scored: Bool), breakTime }
        var parts: [RacketVideoPart] = []
        var curStart = 0.0
        var cur: Open = .pending

        func close(at t: Double, as kind: RacketPartKind) {
            guard t > curStart else { return }
            parts.append(RacketVideoPart(kind: kind, startSec: curStart, endSec: t))
            curStart = t
        }
        func kindOf(_ o: Open) -> RacketPartKind {
            switch o {
            case .pending, .game: return .game
            case .breakTime: return .breakTime
            }
        }

        for (t, e) in events {
            switch e {
            case .newGame:
                // A game stretch with no point that ends in another new game within `idleSec` was the break between
                // them (a Watch game end marks a new game; "New game starts" then marks the real start).
                if case .game(scored: false) = cur, !parts.isEmpty, t - curStart < idleSec {
                    close(at: t, as: .breakTime)
                } else {
                    close(at: t, as: kindOf(cur))
                }
                cur = .game(scored: false)
            case .breakStart:
                if case .breakTime = cur { continue }   // already on a break
                close(at: t, as: kindOf(cur))
                cur = .breakTime
            case .firstPoint:
                let playFrom = max(curStart, t - leadSec)
                switch cur {
                case .pending:
                    // A long quiet start is a warmup.
                    if t - curStart > idleSec { close(at: playFrom, as: .warmup) }
                    cur = .game(scored: true)
                case .game(let scored):
                    // A game stretch that began at the last game's end: the quiet time before the first point was a break.
                    if !scored, t - curStart > idleSec { close(at: playFrom, as: .breakTime) }
                    cur = .game(scored: true)
                case .breakTime:
                    close(at: playFrom, as: .breakTime)
                    cur = .game(scored: true)
                }
            }
        }
        // The last stretch: a break that runs to the end is packing up.
        if case .breakTime = cur { close(at: total, as: .notPlay) } else { close(at: total, as: kindOf(cur)) }

        var out = foldShort(parts)
        // Games beyond the format's room are unsure ("an extra game or practice?").
        if let bestOf = format.bestOf {
            let room = max(0, bestOf - log.baseIndex)
            var n = 0
            for i in out.indices where out[i].kind == .game {
                n += 1
                if n > room { out[i].kind = .unsure }
            }
        }
        return out
    }

    /// A drill recorded with everything: its blocks and rests come straight from the timers (nothing to split by
    /// hand, review5 M1). Before block 1 is the camera set-up (warmup), after the last block "not play". Block `i`
    /// is the video of `sets[baseSetIndex + i]`.
    static func drillParts(log: RacketRecordingLog) -> [RacketVideoPart] {
        let total = log.timelineSec
        let blocks = log.marks.filter { $0.kind == .block }.sorted { $0.startSec < $1.startSec }
        guard total > 0, !blocks.isEmpty else { return [] }
        var parts: [RacketVideoPart] = []
        var t = 0.0
        for (k, b) in blocks.enumerated() {
            let start = min(max(t, b.startSec), total)
            if start > t {
                parts.append(RacketVideoPart(kind: k == 0 ? .warmup : .rest, startSec: t, endSec: start))
            }
            let end = min(total, max(start, b.endSec ?? total))
            if end > start {
                parts.append(RacketVideoPart(kind: .drillBlock, startSec: start, endSec: end,
                                             setIndex: log.baseIndex + (b.index ?? k)))
            }
            t = end
        }
        if total > t { parts.append(RacketVideoPart(kind: .notPlay, startSec: t, endSec: total)) }
        return parts
    }

    /// Short non-game stretches fold into the part before them (the first one into the next). A game is never folded:
    /// every "New game starts" stays a game, as step 1 counted them.
    static func foldShort(_ parts: [RacketVideoPart]) -> [RacketVideoPart] {
        var out: [RacketVideoPart] = []
        for p in parts {
            if p.durationSec < minPartSec, p.kind != .game, var last = out.popLast() {
                last.endSec = p.endSec
                out.append(last)
            } else if let last = out.last, last.kind == p.kind, last.kind != .game {
                // Two breaks in a row are one break.
                out[out.count - 1].endSec = p.endSec
            } else {
                out.append(p)
            }
        }
        if out.count > 1, out[0].durationSec < minPartSec, out[0].kind != .game {
            out[1].startSec = out[0].startSec
            out.removeFirst()
        }
        return out
    }

    /// "Looks like 3 games and one more stretch of play, with breaks in between." (TtSplitPrompt)
    static func promptLine(_ parts: [RacketVideoPart], unit: RacketUnit) -> String {
        let games = parts.filter { $0.kind == .game }.count
        let unsure = parts.filter { $0.kind == .unsure }.count
        let breaks = parts.filter { $0.kind == .breakTime || $0.kind == .warmup }.count
        var s = games == 0 ? "No \(unit.noun)s marked yet" : "Looks like \(games) \(games == 1 ? unit.noun : "\(unit.noun)s")"
        if unsure > 0 { s += " and \(unsure == 1 ? "one more stretch" : "\(unsure) more stretches") of play" }
        if breaks > 0 { s += ", with breaks in between" }
        return s + "."
    }
}

// MARK: - Editing (TtSplitEdit)

/// Range edits keep the parts **tiling** the recording: sorted, no overlaps, no gaps, clamped to its length, each
/// at least `minPartSec`. Moving one edge moves the neighbour's edge with it.
enum RacketSplitEditor {
    static let minPartSec: Double = RacketSplitProposal.minPartSec

    enum Issue: Equatable, Sendable {
        case empty
        case outOfRange(index: Int)
        case overlap(index: Int)
        case gap(index: Int)
        case tooShort(index: Int)
    }

    /// Problems with a list of parts for a recording of `duration` seconds; `[]` ⇒ valid.
    static func validate(_ parts: [RacketVideoPart], duration: Double) -> [Issue] {
        guard !parts.isEmpty else { return [.empty] }
        var issues: [Issue] = []
        for (i, p) in parts.enumerated() {
            if p.startSec < 0 || p.endSec > duration + 0.001 { issues.append(.outOfRange(index: i)) }
            if p.durationSec < minPartSec - 0.001 { issues.append(.tooShort(index: i)) }
            if i > 0 {
                let prev = parts[i - 1].endSec
                if p.startSec < prev - 0.001 { issues.append(.overlap(index: i)) }
                if p.startSec > prev + 0.001 { issues.append(.gap(index: i)) }
            }
        }
        if parts[0].startSec > 0.001 { issues.append(.gap(index: 0)) }
        if let last = parts.last, last.endSec < duration - 0.001 { issues.append(.gap(index: parts.count)) }
        return issues
    }

    /// Sort, clamp to `[0, duration]`, and close gaps / overlaps (each part starts where the one before ends).
    static func normalized(_ parts: [RacketVideoPart], duration: Double) -> [RacketVideoPart] {
        var ps = parts.sorted { $0.startSec < $1.startSec }
        for i in ps.indices {
            ps[i].startSec = i == 0 ? 0 : ps[i - 1].endSec
            ps[i].endSec = min(duration, max(ps[i].startSec, ps[i].endSec))
        }
        if !ps.isEmpty { ps[ps.count - 1].endSec = duration }
        return ps.filter { $0.durationSec > 0 }
    }

    /// Move part `id` to `[start, end]`, clamped so it and its neighbours stay at least `minPartSec`; the neighbours'
    /// touching edges follow. The first part always starts at 0 and the last always ends at `duration`.
    static func setBounds(_ parts: [RacketVideoPart], id: UUID, start: Double, end: Double,
                          duration: Double) -> [RacketVideoPart] {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return parts }
        var ps = parts
        let lo = i > 0 ? ps[i - 1].startSec + minPartSec : 0
        let hi = i < ps.count - 1 ? ps[i + 1].endSec - minPartSec : duration
        var s = i > 0 ? min(max(start, lo), hi - minPartSec) : 0
        var e = i < ps.count - 1 ? max(min(end, hi), s + minPartSec) : duration
        s = max(0, s); e = min(duration, e)
        ps[i].startSec = s
        ps[i].endSec = e
        if i > 0 { ps[i - 1].endSec = s }
        if i < ps.count - 1 { ps[i + 1].startSec = e }
        return ps
    }

    /// "Split here": part `id` becomes two at `t` (both keep its kind; the second has no game link). Ignored when
    /// either half would be shorter than `minPartSec`.
    static func split(_ parts: [RacketVideoPart], id: UUID, at t: Double) -> [RacketVideoPart] {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return parts }
        let p = parts[i]
        guard t - p.startSec >= minPartSec, p.endSec - t >= minPartSec else { return parts }
        var first = p
        first.endSec = t
        var second = RacketVideoPart(kind: p.kind, startSec: t, endSec: p.endSec)
        second.belongs = p.belongs
        var ps = parts
        ps.replaceSubrange(i...i, with: [first, second])
        return ps
    }

    /// "Merge with next": part `id` takes the next part's range (it keeps its own kind and game link).
    static func mergeWithNext(_ parts: [RacketVideoPart], id: UUID) -> [RacketVideoPart] {
        guard let i = parts.firstIndex(where: { $0.id == id }), i < parts.count - 1 else { return parts }
        var ps = parts
        ps[i].endSec = ps[i + 1].endSec
        if ps[i].setIndex == nil { ps[i].setIndex = ps[i + 1].setIndex }
        ps.remove(at: i + 1)
        return ps
    }

    /// "What is this part?" / "Belongs to". An unsure stretch that belongs to this match becomes an extra game;
    /// "Practice" keeps it unsure and uncounted.
    static func setKind(_ parts: [RacketVideoPart], id: UUID, kind: RacketPartKind) -> [RacketVideoPart] {
        parts.map { p in
            guard p.id == id else { return p }
            var q = p
            q.kind = kind
            if !kind.counts { q.setIndex = nil }
            if kind != .game && kind != .unsure { q.belongs = nil }
            return q
        }
    }

    static func setBelongs(_ parts: [RacketVideoPart], id: UUID, belongs: RacketPartBelongs) -> [RacketVideoPart] {
        parts.map { p in
            guard p.id == id else { return p }
            var q = p
            q.belongs = belongs
            q.kind = belongs == .thisMatch ? .game : .unsure
            if belongs == .practice { q.setIndex = nil }
            return q
        }
    }
}

// MARK: - Part ↔ game (TtSplitAssign) and Apply

/// Links each game part to its logged game, and makes the games the recording has but the match doesn't yet. A
/// game scored on the Watch was logged when it ended (its `completedAt` falls at the end of its part), so it goes to
/// that part; the recording's other games follow in order; a game part with no game gets a new one logged as "Score
/// unconfirmed" (prompt 244's one state — counts for neither side until confirmed, review5 M5).
enum RacketSplitAssign {
    /// A Watch game is logged up to this long after its part ends.
    static let toleranceSec: Double = 20

    struct Outcome: Equatable, Sendable {
        var parts: [RacketVideoPart]
        var sets: [SetLog]
        /// How many "Score unconfirmed" games were added.
        var added: Int
    }

    static func apply(parts input: [RacketVideoPart], sets: [SetLog], base: Int, startedAt: Date) -> Outcome {
        var parts = input
        for i in parts.indices { parts[i].setIndex = nil }
        let gameIdx = parts.indices.filter { parts[$0].kind == .game }
        let base = min(max(0, base), sets.count)
        let own = Array(sets[base...])
        var setFor: [Int: Int] = [:]           // part index → index into `own`
        var used = Set<Int>()

        // 1. By time: a game whose completedAt falls in (or just after) a game part.
        for (k, s) in own.enumerated() {
            guard let at = s.completedAt else { continue }
            let t = at.timeIntervalSince(startedAt)
            if let pi = gameIdx.first(where: { setFor[$0] == nil && t >= parts[$0].startSec
                                               && t <= parts[$0].endSec + toleranceSec }) {
                setFor[pi] = k
                used.insert(k)
            }
        }
        // 2. In order: the recording's other games fill the remaining parts, never before a part already matched
        //    to a later game.
        var free = own.indices.filter { !used.contains($0) }
        for pi in gameIdx where setFor[pi] == nil {
            guard let k = free.first else { break }
            let laterMatched = setFor.contains { $0.key > pi && $0.value < k }
            if laterMatched { continue }
            setFor[pi] = k
            free.removeFirst()
            used.insert(k)
        }

        // 3. Rebuild the recording's games in part order: matched games, then new "Score unconfirmed" ones, then any
        //    of its games no part claimed (kept, in their order).
        var rebuilt: [(part: Int?, set: SetLog)] = []
        var added = 0
        for pi in gameIdx {
            if let k = setFor[pi] {
                rebuilt.append((pi, own[k]))
            } else {
                var s = SetLog()
                s.scoreUnconfirmed = true
                s.completedAt = startedAt.addingTimeInterval(parts[pi].endSec)
                s.durationSec = parts[pi].durationSec
                rebuilt.append((pi, s))
                added += 1
            }
        }
        for k in own.indices where !used.contains(k) { rebuilt.append((nil, own[k])) }

        var out = Array(sets[..<base])
        for (offset, r) in rebuilt.enumerated() {
            out.append(r.set)
            if let pi = r.part { parts[pi].setIndex = base + offset }
        }
        return Outcome(parts: parts, sets: out, added: added)
    }

    /// One row of TtSplitAssign / TtSplitDone: "Game 1 · 11–9", "Game 3 · no score", "Extra game".
    static func title(_ part: RacketVideoPart, ordinal: Int, sets: [SetLog], unit: RacketUnit) -> String {
        let noun = unit.noun.capitalized
        if part.isExtra { return "Extra \(unit.noun)" }
        if part.kind == .drillBlock { return "Block \(ordinal)" }
        guard part.kind == .game else { return part.kind.label(unit: unit) }
        let state = part.setIndex.flatMap { $0 < sets.count ? sets[$0].racketScoreState : nil }
        switch state {
        case .confirmed(let s), .fromWatch(let s): return "\(noun) \(ordinal) · \(s.label)"
        case .unconfirmed, nil: return "\(noun) \(ordinal) · no score"
        }
    }

    /// "Game 3 has video but no score" — the first game part whose game has no score yet.
    static func missingScore(parts: [RacketVideoPart], sets: [SetLog], unit: RacketUnit) -> (part: RacketVideoPart, line: String)? {
        var n = 0
        for p in parts where p.kind == .game {
            n += 1
            let state = p.setIndex.flatMap { $0 < sets.count ? sets[$0].racketScoreState : nil }
            if state == nil || state == .unconfirmed {
                let name = p.isExtra ? "The extra \(unit.noun)" : "\(unit.noun.capitalized) \(n)"
                return (p, "\(name) has video but no score")
            }
        }
        return nil
    }
}

// MARK: - Saving a score from these screens (Edit score, "Enter the score")

/// The in-place score edit the match page does (`FreeformPlayerView.saveRacketUnit`), for screens that edit the
/// session directly: the score lands on the game, which is then confirmed (no longer "Score unconfirmed" or "from
/// Watch" — one state everywhere, review5 M5).
enum RacketScoreEdit {
    static func apply(_ log: SetLog, to set: inout SetLog) {
        set.scoreFor = log.scoreFor
        set.scoreAgainst = log.scoreAgainst
        set.tiebreakFor = log.tiebreakFor
        set.tiebreakAgainst = log.tiebreakAgainst
        set.superTiebreak = log.superTiebreak
        set.scoreUnconfirmed = nil
        set.scoreFromWatch = nil
        if set.completedAt == nil { set.completedAt = log.completedAt ?? .now }
    }
}

// MARK: - Review lines (TtSplitReview)

enum RacketSplitReview {
    enum Status: String, Sendable { case matched = "Matched", notCounted = "Not counted", unsure = "Unsure" }

    static func status(_ p: RacketVideoPart) -> Status {
        if p.kind.counts { return .matched }
        if p.kind == .unsure && p.belongs == nil { return .unsure }
        return .notCounted
    }

    /// The part's name in the review list: "Game 2", "Warmup", "Extra game".
    static func name(_ p: RacketVideoPart, ordinal: Int?, unit: RacketUnit) -> String {
        if p.isExtra { return "Extra \(unit.noun)" }
        switch p.kind {
        case .game: return "\(unit.noun.capitalized) \(ordinal ?? 1)"
        case .drillBlock: return "Block \(ordinal ?? 1)"
        default: return p.kind.label(unit: unit)
        }
    }

    /// "6:10–24:40 · 11–9 from Watch", "· no score logged", "· not counted", "· an extra game or practice?",
    /// "· packing up, not counted".
    static func detail(_ p: RacketVideoPart, sets: [SetLog], unit: RacketUnit, isLast: Bool) -> String {
        let range = RacketVideoTime.range(p.startSec, p.endSec)
        switch p.kind {
        case .game, .drillBlock:
            let state = p.setIndex.flatMap { $0 < sets.count ? sets[$0].racketScoreState : nil }
            if p.kind == .drillBlock { return range }
            switch state {
            case .some(.unconfirmed), .none: return "\(range) · no score logged"
            case .some(let s): return "\(range) · \(s.label)"
            }
        case .unsure:
            return p.belongs == .practice ? "\(range) · practice, not counted" : "\(range) · an extra \(unit.noun) or practice?"
        case .notPlay:
            return isLast ? "\(range) · packing up, not counted" : "\(range) · not counted"
        default:
            return "\(range) · not counted"
        }
    }

    /// Ordinal per counted kind (Game 1, 2, 3 … / Block 1, 2 …), extra games excluded.
    static func ordinals(_ parts: [RacketVideoPart]) -> [UUID: Int] {
        var games = 0, blocks = 0
        var out: [UUID: Int] = [:]
        for p in parts {
            if p.kind == .game && !p.isExtra { games += 1; out[p.id] = games }
            if p.kind == .drillBlock { blocks += 1; out[p.id] = blocks }
        }
        return out
    }
}

// MARK: - Times

enum RacketVideoTime {
    /// "6:10", "1:06:30" — a position on a recording.
    static func clock(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    /// "6:10–24:40".
    static func range(_ a: Double, _ b: Double) -> String { "\(clock(a))–\(clock(b))" }

    /// "1 h 3 min", "18 min", "45 s".
    static func length(_ sec: Double) -> String {
        let s = Int(max(0, sec).rounded())
        if s < 60 { return "\(s) s" }
        let m = Int((Double(s) / 60).rounded())   // the boards round: 62:50 ⇒ "1 h 3 min"
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// "2:41.4" — a rally edge to a tenth of a second.
    static func precise(_ sec: Double) -> String {
        let t = max(0, sec)
        let whole = Int(t)
        let tenth = Int(((t - Double(whole)) * 10).rounded(.down))
        return "\(clock(Double(whole))).\(tenth)"
    }
}

// MARK: - Recording time → Photos parts

/// One stretch of Photos video that plays a piece of a recording-time range.
struct RacketVideoSegment: Equatable, Sendable {
    var localIdentifier: String
    /// Seconds into that Photos video.
    var assetStart: Double
    var assetEnd: Double
    /// Where it sits on the recording's timeline.
    var timelineStart: Double
    var durationSec: Double { max(0, assetEnd - assetStart) }
}

enum RacketVideoMap {
    struct Source: Equatable, Sendable {
        var localIdentifier: String
        /// On the recording's timeline.
        var startSec: Double
        var endSec: Double
    }

    /// The Photos videos that hold this recording: the 10-minute originals (a part's length, or until the next part
    /// starts / its run ends), or — once the original is deleted — the videos made from it.
    static func sources(_ log: RacketRecordingLog) -> [Source] {
        if log.originalDeleted == true {
            return (log.derived ?? []).map { Source(localIdentifier: $0.localIdentifier, startSec: $0.startSec, endSec: $0.endSec) }
                .sorted { $0.startSec < $1.startSec }
        }
        let assets = log.assets.sorted { $0.startSec < $1.startSec }
        return assets.enumerated().map { k, a in
            let end: Double
            if let d = a.durationSec, d > 0 {
                end = a.startSec + d
            } else {
                let nextStart = k + 1 < assets.count ? assets[k + 1].startSec : .infinity
                let runEnd = log.runs.first { $0.startSec <= a.startSec + 0.5 && ($0.endSec ?? .infinity) > a.startSec }?.endSec
                end = min(nextStart, runEnd ?? log.timelineSec)
            }
            return Source(localIdentifier: a.localIdentifier, startSec: a.startSec, endSec: max(a.startSec, end))
        }
    }

    /// The pieces of Photos video that play `[start, end)` of the recording, in order. Gaps (an interruption, or a
    /// stretch no derived video kept) have no piece; the player fills them with nothing.
    static func segments(start: Double, end: Double, sources: [Source]) -> [RacketVideoSegment] {
        guard end > start else { return [] }
        return sources.compactMap { s in
            let a = max(start, s.startSec), b = min(end, s.endSec)
            guard b - a > 0.01 else { return nil }
            return RacketVideoSegment(localIdentifier: s.localIdentifier, assetStart: a - s.startSec,
                                      assetEnd: b - s.startSec, timelineStart: a)
        }
    }

    static func segments(start: Double, end: Double, log: RacketRecordingLog) -> [RacketVideoSegment] {
        segments(start: start, end: end, sources: sources(log))
    }

    /// Every Photos id the recording's playback needs right now.
    static func neededIdentifiers(_ log: RacketRecordingLog) -> [String] { sources(log).map(\.localIdentifier) }
}

// MARK: - Original missing (TtOriginalMissing)

enum RacketOriginalCheck {
    enum State: Equatable, Sendable {
        /// Every Photos video it needs is there.
        case available
        /// Nothing was saved (the simulator's stand-in camera) — the timeline still works.
        case noVideo
        /// Some or all of it is gone from the phone (deleted, edited away, or in iCloud only).
        case missing(count: Int)
    }

    static func state(needed: [String], found: Set<String>) -> State {
        guard !needed.isEmpty else { return .noVideo }
        let missing = needed.filter { !found.contains($0) }.count
        return missing == 0 ? .available : .missing(count: missing)
    }
}

// MARK: - Space (TtDeleteOriginal · TtKeepRallies)

enum RacketVideoSpace {
    /// Bytes per second of a recording at its quality (the step-1 estimate: HEVC, 30 fps).
    static func bytesPerSecond(_ quality: RacketRecordingQuality) -> Double {
        RacketBitrate.bytesPerSecond(RacketCaptureConfig(quality: quality))
    }

    /// "about 8.6 GB", "about 600 MB".
    static func size(_ bytes: Double) -> String {
        let gb = bytes / 1e9
        if gb >= 1 { return gb >= 10 ? "about \(Int(gb.rounded())) GB" : String(format: "about %.1f GB", gb) }
        return "about \(max(1, Int((bytes / 1e6 / 10).rounded()) * 10)) MB"
    }

    /// TtDeleteOriginal: the parts that are saved as their own videos (everything but warmup, breaks, rests and
    /// "not play" — and practice), how long they are, and the space they need.
    struct DeletePlan: Equatable, Sendable {
        var parts: [RacketVideoPart]
        var keepSec: Double
        var neededBytes: Double
        var originals: Int
        var canDelete: Bool { !parts.isEmpty && originals > 0 }
        func fits(freeBytes: Int64?) -> Bool { freeBytes.map { Double($0) > neededBytes } ?? true }
    }

    static func keptOnDelete(_ p: RacketVideoPart) -> Bool {
        p.kind.counts || (p.kind == .unsure && p.belongs != .practice)
    }

    static func deletePlan(log: RacketRecordingLog) -> DeletePlan {
        let parts = (log.split?.parts ?? []).filter(keptOnDelete)
        let keep = parts.reduce(0) { $0 + $1.durationSec }
        return DeletePlan(parts: parts, keepSec: keep, neededBytes: keep * bytesPerSecond(log.quality),
                          originals: log.originalDeleted == true ? 0 : log.assets.count)
    }

    /// "4 · 1 h 3 min".
    static func partsLine(_ plan: DeletePlan) -> String { "\(plan.parts.count) · \(RacketVideoTime.length(plan.keepSec))" }
}

/// "Keep rallies only" (TtKeepRallies): every rally you marked across the session's recordings — matches **and
/// drills** (review5) — becomes its own Photos video; only then are the full videos offered for deletion.
enum RacketKeepRallies {
    /// A little either side of each rally, so a serve and the last bounce aren't cut.
    static let padSec: Double = 1
    /// Rallies closer than this are kept as one video.
    static let joinGapSec: Double = 2

    /// The stretches to keep on one recording: marked rallies (not "Not a rally"), padded, merged when they touch or
    /// sit closer than `joinGapSec`, clamped to `[0, duration]`.
    static func ranges(_ rallies: [RacketRally], duration: Double) -> [ClosedRange<Double>] {
        let spans = rallies.filter(\.isRally)
            .map { (max(0, $0.startSec - padSec), min(duration, $0.endSec + padSec)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var out: [ClosedRange<Double>] = []
        for (a, b) in spans {
            if let last = out.last, a - last.upperBound <= joinGapSec {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, b)
            } else {
                out.append(a...b)
            }
        }
        return out
    }

    struct Plan: Equatable, Sendable {
        /// Full Photos videos today (the record-everything originals still on the phone).
        var fullVideos: Int
        var rallies: Int
        var keepSec: Double
        var freedBytes: Double
        var matchRallies: Int
        var drillRallies: Int
        var canKeep: Bool { rallies > 0 && fullVideos > 0 }
    }

    static func plan(_ exercises: [SessionExercise]) -> Plan {
        var plan = Plan(fullVideos: 0, rallies: 0, keepSec: 0, freedBytes: 0, matchRallies: 0, drillRallies: 0)
        for ex in exercises where ex.discipline == .racket {
            guard let log = ex.racketRecordingLog, log.originalDeleted != true, !log.assets.isEmpty else { continue }
            let n = log.allRallies.filter(\.isRally).count
            let keep = ranges(log.allRallies, duration: log.timelineSec).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
            let full = RacketVideoMap.sources(log).reduce(0) { $0 + ($1.endSec - $1.startSec) }
            plan.fullVideos += log.assets.count
            plan.rallies += n
            plan.keepSec += keep
            plan.freedBytes += max(0, full - keep) * RacketVideoSpace.bytesPerSecond(log.quality)
            if ex.isRacketDrill { plan.drillRallies += n } else { plan.matchRallies += n }
        }
        return plan
    }

    /// "21 · about 9 min".
    static func ralliesLine(_ plan: Plan) -> String {
        let m = plan.keepSec / 60
        let len = m < 1 ? "under a minute" : "about \(Int(m.rounded())) min"
        return "\(plan.rallies) · \(len)"
    }

    /// "16 from matches, 5 from drills" — shown when drills add rallies (review5: the drill's rallies count too).
    static func sourceLine(_ plan: Plan) -> String? {
        guard plan.drillRallies > 0 else { return nil }
        return "\(plan.matchRallies) from matches, \(plan.drillRallies) from drills"
    }
}

// MARK: - Your videos (FindRallies / TtNoModelVideos / TtDrillVideos)

// `RacketRallyFinding` (the seam step 3 left here) now reads the capability registry: `RacketModelHooks.swift`.

/// One row of Your videos / Drill videos.
struct RacketVideoRow: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A part of a split recording, or a drill block.
        case part(UUID)
        /// A recording not split yet (or kept as one video).
        case whole
    }
    var id: String
    var exerciseID: UUID
    var kind: Kind
    var title: String
    /// "11–9 · 18:32", "5:00", "1:14:10 · not split yet".
    var line: String
    /// "Unconfirmed" / "from Watch" (one score state, review5 M5); nil when confirmed or no score.
    var scoreChip: String?
    /// "5 marked by you" / "Not marked yet".
    var tagLine: String
    var setIndex: Int?
    var startSec: Double
    var endSec: Double
    var rallies: Int
}

enum RacketVideoRows {
    static func rows(for ex: SessionExercise) -> [RacketVideoRow] {
        guard let log = ex.racketRecordingLog else { return [] }
        let unit = ex.racketFormat.sport.unit
        let rallies = log.allRallies
        func tagLine(_ a: Double, _ b: Double) -> (String, Int) {
            let inPart = rallies.filter { $0.isRally && $0.startSec >= a - 0.01 && $0.startSec < b }
            // Prompt 247: say what came from another AI app (accepted on Compare).
            let ai = inPart.filter(\.isFromAI)
            if !ai.isEmpty {
                let names = ai.compactMap(\.aiName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                return ("\(inPart.count) marked · \(ai.count) from \(names.count == 1 ? names[0] : "other apps")", inPart.count)
            }
            return (inPart.isEmpty ? "Not marked yet" : "\(inPart.count) marked by you", inPart.count)
        }
        let parts: [RacketVideoPart]
        if ex.isRacketDrill {
            parts = RacketSplitProposal.drillParts(log: log).filter { $0.kind == .drillBlock }
        } else if let split = log.split, split.appliedAt != nil {
            parts = split.countedParts
        } else {
            let total = log.timelineSec
            let (t, n) = tagLine(0, total + 1)
            return [RacketVideoRow(id: "\(ex.id)-whole", exerciseID: ex.id, kind: .whole, title: "Whole recording",
                                   line: "\(RacketVideoTime.clock(total)) · \(log.keptAsOne == true ? "kept as one video" : "not split yet")",
                                   scoreChip: nil, tagLine: t, setIndex: nil, startSec: 0, endSec: total, rallies: n)]
        }
        let ordinals = RacketSplitReview.ordinals(parts)
        return parts.map { p in
            let state = p.setIndex.flatMap { $0 < ex.sets.count ? ex.sets[$0].racketScoreState : nil }
            var line = RacketVideoTime.clock(p.durationSec)
            var chip: String?
            switch state {
            case .confirmed(let s): line = "\(s.label) · \(line)"
            case .fromWatch(let s): line = "\(s.label) · \(line)"; chip = "From Watch"
            case .unconfirmed: chip = "Unconfirmed"
            case nil: break
            }
            let (t, n) = tagLine(p.startSec, p.endSec)
            return RacketVideoRow(id: p.id.uuidString, exerciseID: ex.id, kind: .part(p.id),
                                  title: RacketSplitReview.name(p, ordinal: ordinals[p.id], unit: unit),
                                  line: line, scoreChip: chip, tagLine: t, setIndex: p.setIndex,
                                  startSec: p.startSec, endSec: p.endSec, rallies: n)
        }
    }

    /// "3 blocks · 3 clips · none scanned" (TtDrillVideos header).
    static func drillHeader(_ ex: SessionExercise) -> String {
        let n = rows(for: ex).count
        let marked = rows(for: ex).filter { $0.rallies > 0 }.count
        return "\(n) \(n == 1 ? "block" : "blocks") · 1 recording · \(marked) marked by you"
    }

    /// The recap line: "4 videos · 21 rallies tagged" (TtSessionRecap); a drill "3 blocks · 3 videos" (prompt 252).
    /// `nil` with no recording.
    static func recapLine(_ ex: SessionExercise) -> String? {
        guard let log = ex.racketRecordingLog else { return nil }
        if ex.isRacketDrill {
            let blocks = max(ex.completedSetCount, rows(for: ex).count)
            let videos = rows(for: ex).count
            return "\(blocks) \(blocks == 1 ? "block" : "blocks") · \(videos) \(videos == 1 ? "video" : "videos")"
        }
        let videos = ex.isRacketDrill ? rows(for: ex).count : (log.isSplit ? (log.split?.countedParts.count ?? 0) : 1)
        let tagged = log.allRallies.filter(\.isTagged).count
        let marked = log.allRallies.filter(\.isRally).count
        let noun = ex.isRacketDrill ? (videos == 1 ? "block" : "blocks") : (videos == 1 ? "video" : "videos")
        var s = "\(videos) \(noun)"
        if tagged > 0 { s += " · \(tagged) \(tagged == 1 ? "rally" : "rallies") tagged" }
        else if marked > 0 { s += " · \(marked) marked" }
        return s
    }
}
