import Foundation

// MARK: - Racket split editor, game groups and timeouts (prompt 258) — pure
//
// A game can be several stretches of one recording joined across **timeouts**: a game group is
// game half, timeout, game half [, timeout, game half …]. The representation is structural: a game part directly after
// a timeout *is* a continuation of the game before that timeout; there is no flag that could disagree with the parts.
// The group's one game link (`setIndex`, an index into `SessionExercise.sets`) sits on its **first** half. While the
// split is being edited, a half that brought its own logged game into a group keeps that game in
// `joinedSetIndexes` (draft only), so turning the timeout back into a break gives it back; Save (`RacketSplitCommit`)
// folds those games into the group's game and renumbers the match's later games.
//
// Invariants (`RacketSplitEditor.validate` reports each, `normalized` repairs each):
// 1. Parts tile [0, duration] in order, each at least `minPartSec` (timeouts included).
// 2. A timeout has a game half directly before and after it (never first / last, never beside a timeout, break,
//    warmup, rest, drill block, unsure or not-play part). A broken timeout becomes a break.
// 3. A continuation has a timeout directly before it — by construction (a continuation is defined as the game after
//    a timeout), so a game with no timeout before it is a plain game with no game link of its own.
// 4. A group has at most one game link, on its first half; no logged game is linked (or joined) twice; only game
//    halves hold joined games.
// 5. All halves of a group share `belongs` (an extra game vs this match).
// 6. A drill recording never holds a timeout (its blocks and rests come from the timers).

/// One game as the player counts it: its halves and the timeouts between them (a plain game has one half).
struct RacketGameGroup: Equatable, Sendable {
    /// Part indexes of the halves, in order.
    var halves: [Int]
    /// Part indexes of the timeouts between them.
    var timeouts: [Int]

    var first: Int { halves[0] }
    var last: Int { halves[halves.count - 1] }
    var isGrouped: Bool { halves.count > 1 }
}

enum RacketGameGroups {
    /// Every game in part order: a game part, then each (timeout, game) pair after it.
    static func groups(_ ps: [RacketVideoPart]) -> [RacketGameGroup] {
        var out: [RacketGameGroup] = []
        var i = 0
        while i < ps.count {
            guard ps[i].kind == .game else { i += 1; continue }
            var g = RacketGameGroup(halves: [i], timeouts: [])
            var j = i
            while j + 2 < ps.count, ps[j + 1].kind == .timeout, ps[j + 2].kind == .game {
                g.timeouts.append(j + 1)
                g.halves.append(j + 2)
                j += 2
            }
            out.append(g)
            i = j + 1
        }
        return out
    }

    static func group(of index: Int, in ps: [RacketVideoPart]) -> RacketGameGroup? {
        groups(ps).first { $0.halves.contains(index) || $0.timeouts.contains(index) }
    }

    /// A game half that continues the game before a timeout ("Game 2, continued").
    static func isContinuation(_ i: Int, in ps: [RacketVideoPart]) -> Bool {
        i >= 2 && i < ps.count && ps[i].kind == .game && ps[i - 1].kind == .timeout && ps[i - 2].kind == .game
    }

    static func continuations(_ ps: [RacketVideoPart]) -> Set<UUID> {
        Set(ps.indices.filter { isContinuation($0, in: ps) }.map { ps[$0].id })
    }

    /// The game's played time: its halves, timeouts left out.
    static func playedSec(_ ps: [RacketVideoPart], _ g: RacketGameGroup) -> Double {
        g.halves.reduce(0) { $0 + ps[$1].durationSec }
    }

    /// The timeouts inside `[lo, hi]`, as stretches the player skips.
    static func skips(_ ps: [RacketVideoPart], from lo: Double, to hi: Double) -> [ClosedRange<Double>] {
        ps.filter { $0.kind == .timeout && $0.startSec >= lo - 0.01 && $0.endSec <= hi + 0.01 && $0.endSec > $0.startSec }
            .map { $0.startSec...$0.endSec }
    }

    /// Every logged game a part points at: its link, then the games it brought into a group.
    static func links(_ p: RacketVideoPart) -> [Int] {
        (p.setIndex.map { [$0] } ?? []) + (p.joinedSetIndexes ?? [])
    }

    static func allLinks(_ ps: [RacketVideoPart]) -> [Int] { ps.flatMap(links) }

    /// A rally belongs to the game unless most of it sits inside a timeout (a rally across a timeout's edge counts
    /// for the half it mostly sits in; a moment-long one by where it starts).
    static func inGame(_ r: RacketRally, skips: [ClosedRange<Double>]) -> Bool {
        guard !skips.isEmpty else { return true }
        let len = r.endSec - r.startSec
        guard len > 0.001 else { return !skips.contains { r.startSec >= $0.lowerBound && r.startSec < $0.upperBound } }
        let inside = skips.reduce(0.0) { acc, s in acc + max(0, min(r.endSec, s.upperBound) - max(r.startSec, s.lowerBound)) }
        return inside <= len / 2
    }
}

extension RacketRecordingLog {
    /// The applied split's timeouts inside `[lo, hi]` (none before a split is applied).
    func timeouts(from lo: Double, to hi: Double) -> [ClosedRange<Double>] {
        guard let s = split, s.appliedAt != nil else { return [] }
        return RacketGameGroups.skips(s.parts, from: lo, to: hi)
    }

    /// The rallies of the stretch `[lo, hi)` — a game group's rallies leave out those inside its timeouts.
    func rallies(_ lo: Double, _ hi: Double) -> [RacketRally] {
        RacketRallyMarking.inRange(allRallies, lo, hi, skipping: timeouts(from: lo, to: hi))
    }

    /// The played-time clock of `[lo, hi]` (recording time with this stretch's timeouts left out).
    func playedTime(_ lo: Double, _ hi: Double) -> RacketPlayedTime {
        RacketPlayedTime(start: lo, end: hi, skips: timeouts(from: lo, to: hi))
    }
}

extension RacketRallyMarking {
    /// `inRange`, leaving out rallies that sit (mostly) inside `skipping` — a game group's timeouts.
    static func inRange(_ rallies: [RacketRally], _ lo: Double, _ hi: Double,
                        skipping: [ClosedRange<Double>]) -> [RacketRally] {
        inRange(rallies, lo, hi).filter { RacketGameGroups.inGame($0, skips: skipping) }
    }
}

// MARK: - Played time ↔ recording time

/// A game group's clock with its timeouts taken out: what the player shows (position, length) and how it skips.
/// A position exactly on a timeout's edge is the same played moment on both sides; played → recording lands
/// **after** the timeout (playing on from there).
struct RacketPlayedTime: Equatable, Sendable {
    let start: Double
    let end: Double
    /// Sorted, clipped to `[start, end]`, merged.
    let skips: [ClosedRange<Double>]

    init(start: Double, end: Double, skips: [ClosedRange<Double>] = []) {
        self.start = start
        self.end = max(start, end)
        var merged: [ClosedRange<Double>] = []
        for s in skips.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let a = max(start, s.lowerBound), b = min(end, s.upperBound)
            guard b > a else { continue }
            if let last = merged.last, a <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, b)
            } else {
                merged.append(a...b)
            }
        }
        self.skips = merged
    }

    var hasSkips: Bool { !skips.isEmpty }
    var skippedSec: Double { skips.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    var playedSec: Double { max(0, end - start - skippedSec) }

    /// Recording time → seconds played since the start (a time inside a timeout reads as its start).
    func played(_ t: Double) -> Double {
        let c = min(max(t, start), end)
        var p = c - start
        for s in skips {
            if c >= s.upperBound { p -= s.upperBound - s.lowerBound } else if c > s.lowerBound { p -= c - s.lowerBound }
        }
        return max(0, p)
    }

    /// Seconds played → recording time (an edge lands after the timeout).
    func recording(_ p: Double) -> Double {
        var t = start + min(max(0, p), playedSec)
        for s in skips {
            if t >= s.lowerBound - 0.0005 { t += s.upperBound - s.lowerBound } else { break }
        }
        return min(t, end)
    }

    /// The timeout holding `t` (its end excluded).
    func skip(at t: Double) -> ClosedRange<Double>? {
        skips.first { t >= $0.lowerBound && t < $0.upperBound - 0.0005 }
    }

    /// Where playback or a seek lands from `t`: inside a timeout, its end (forward) or its start (backward).
    func landing(_ t: Double, forward: Bool = true) -> Double {
        guard let s = skip(at: t) else { return t }
        return forward ? s.upperBound : s.lowerBound
    }

    /// ±`d` seconds of play from `t` (a skip back from just after a timeout lands before it).
    func step(from t: Double, by d: Double) -> Double { recording(played(t) + d) }
}

// MARK: - Editing (TtSplitEdit)

/// Range edits keep the parts **tiling** the recording: sorted, no overlaps, no gaps, clamped to its length, each
/// at least `minPartSec`. Moving one edge moves the neighbour's edge with it. Every operation ends in a list that
/// passes `validate` (given one that did).
enum RacketSplitEditor {
    static let minPartSec: Double = RacketSplitProposal.minPartSec

    enum Issue: Equatable, Sendable {
        case empty
        case outOfRange(index: Int)
        case overlap(index: Int)
        case gap(index: Int)
        case tooShort(index: Int)
        /// Invariant 2: a timeout that isn't between two game halves.
        case misplacedTimeout(index: Int)
        /// Invariants 3–4: a game link on a part that isn't a game's first half, or a joined game on a non-game.
        case misplacedLink(index: Int)
        /// Invariant 4: a logged game linked or joined twice.
        case duplicateLink(index: Int)
        /// Invariant 5: halves of one game that belong differently.
        case mixedBelongs(index: Int)
        /// Invariant 6: a timeout in a drill recording.
        case timeoutInDrill(index: Int)
    }

    /// Problems with a list of parts for a recording of `duration` seconds; `[]` ⇒ valid.
    static func validate(_ parts: [RacketVideoPart], duration: Double, drill: Bool = false) -> [Issue] {
        guard !parts.isEmpty else { return [.empty] }
        var issues: [Issue] = []
        for (i, p) in parts.enumerated() {
            if p.startSec < 0 || p.endSec > duration + 0.001 { issues.append(.outOfRange(index: i)) }
            if parts.count > 1, p.durationSec < minPartSec - 0.001 { issues.append(.tooShort(index: i)) }
            if i > 0 {
                let prev = parts[i - 1].endSec
                if p.startSec < prev - 0.001 { issues.append(.overlap(index: i)) }
                if p.startSec > prev + 0.001 { issues.append(.gap(index: i)) }
            }
            if p.kind == .timeout {
                if drill { issues.append(.timeoutInDrill(index: i)) }
                if i == 0 || i == parts.count - 1 || parts[i - 1].kind != .game || parts[i + 1].kind != .game {
                    issues.append(.misplacedTimeout(index: i))
                }
            }
            if (!p.kind.counts && p.setIndex != nil) || (p.kind != .game && !(p.joinedSetIndexes ?? []).isEmpty) {
                issues.append(.misplacedLink(index: i))
            }
        }
        if parts[0].startSec > 0.001 { issues.append(.gap(index: 0)) }
        if let last = parts.last, last.endSec < duration - 0.001 { issues.append(.gap(index: parts.count)) }
        for g in RacketGameGroups.groups(parts) {
            for h in g.halves.dropFirst() {
                if parts[h].setIndex != nil { issues.append(.misplacedLink(index: h)) }
                if parts[h].belongs != parts[g.first].belongs { issues.append(.mixedBelongs(index: h)) }
            }
        }
        var seen = Set<Int>()
        for (i, p) in parts.enumerated() {
            for l in RacketGameGroups.links(p) {
                if seen.contains(l) { issues.append(.duplicateLink(index: i)) } else { seen.insert(l) }
            }
        }
        return issues
    }

    /// Repair every invariant: sort, clamp to `[0, duration]`, close gaps / overlaps, bring short parts up to
    /// `minPartSec`, then the timeout and link rules (`repairGroups`).
    static func normalized(_ parts: [RacketVideoPart], duration: Double, drill: Bool = false) -> [RacketVideoPart] {
        var ps = parts.sorted { $0.startSec < $1.startSec }
        for i in ps.indices {
            ps[i].startSec = i == 0 ? 0 : ps[i - 1].endSec
            ps[i].endSec = min(duration, max(ps[i].startSec, ps[i].endSec))
        }
        if !ps.isEmpty { ps[ps.count - 1].endSec = duration }
        ps = ps.filter { $0.durationSec > 0 }
        return repairGroups(fixShort(ps), drill: drill)
    }

    /// A part shorter than `minPartSec` takes the time it lacks from a neighbour that can spare it; failing that,
    /// it and a neighbour become one (the one holding a game link survives).
    static func fixShort(_ parts: [RacketVideoPart]) -> [RacketVideoPart] {
        var ps = parts
        var i = 0
        while ps.count > 1, i < ps.count {
            let need = minPartSec - ps[i].durationSec
            if need <= 0.0005 { i += 1; continue }
            if i + 1 < ps.count, ps[i + 1].durationSec - need >= minPartSec {
                ps[i].endSec += need; ps[i + 1].startSec += need; i += 1; continue
            }
            if i > 0, ps[i - 1].durationSec - need >= minPartSec {
                ps[i].startSec -= need; ps[i - 1].endSec -= need; i += 1; continue
            }
            let j = i > 0 ? i - 1 : i + 1
            let linked: (Int) -> Bool = { !RacketGameGroups.links(ps[$0]).isEmpty }
            let (keep, drop) = linked(i) && !linked(j) ? (i, j) : (j, i)
            ps[keep].startSec = min(ps[i].startSec, ps[j].startSec)
            ps[keep].endSec = max(ps[i].endSec, ps[j].endSec)
            if ps[keep].kind == .game, linked(drop) {
                ps[keep].joinedSetIndexes = (ps[keep].joinedSetIndexes ?? []) + RacketGameGroups.links(ps[drop])
            }
            ps.remove(at: drop)
            i = 0
        }
        return ps
    }

    /// Invariants 2–6 on a tiled list: broken timeouts become breaks (rests in a drill), links leave non-games, every
    /// group's link sits on its first half (a continuation's own game is kept as joined), halves share `belongs`, and
    /// no logged game is linked twice.
    static func repairGroups(_ parts: [RacketVideoPart], drill: Bool = false) -> [RacketVideoPart] {
        var ps = parts
        for i in ps.indices where ps[i].kind == .timeout {
            if drill || i == 0 || i == ps.count - 1 || ps[i - 1].kind != .game || ps[i + 1].kind != .game {
                ps[i].kind = drill ? .rest : .breakTime
            }
        }
        for i in ps.indices {
            if !ps[i].kind.counts { ps[i].setIndex = nil }
            if ps[i].kind != .game || ps[i].joinedSetIndexes?.isEmpty == true { ps[i].joinedSetIndexes = nil }
            if ps[i].kind == .timeout { ps[i].belongs = nil }
        }
        var seen = Set<Int>()
        for i in ps.indices {
            if let s = ps[i].setIndex { if seen.contains(s) { ps[i].setIndex = nil } else { seen.insert(s) } }
            if let js = ps[i].joinedSetIndexes {
                let kept = js.filter { seen.insert($0).inserted }
                ps[i].joinedSetIndexes = kept.isEmpty ? nil : kept
            }
        }
        for g in RacketGameGroups.groups(ps) {
            let b = ps[g.first].belongs
            for h in g.halves.dropFirst() {
                ps[h].belongs = b
                if let s = ps[h].setIndex {
                    ps[h].joinedSetIndexes = [s] + (ps[h].joinedSetIndexes ?? [])
                    ps[h].setIndex = nil
                }
            }
            if ps[g.first].setIndex == nil, let h = g.halves.first(where: { !(ps[$0].joinedSetIndexes ?? []).isEmpty }) {
                var js = ps[h].joinedSetIndexes ?? []
                ps[g.first].setIndex = js.removeFirst()
                ps[h].joinedSetIndexes = js.isEmpty ? nil : js
            }
        }
        return ps
    }

    /// The half at `i` is leaving its game (a new kind, or a break taking it over): when it held the group's link,
    /// the link and its joined games move to the group's next half.
    static func handOff(_ ps: inout [RacketVideoPart], from i: Int) {
        guard let g = RacketGameGroups.group(of: i, in: ps), g.isGrouped, g.first == i else { return }
        let next = g.halves[1]
        ps[next].setIndex = ps[i].setIndex
        ps[next].joinedSetIndexes = (ps[i].joinedSetIndexes ?? []) + (ps[next].joinedSetIndexes ?? [])
        ps[i].setIndex = nil
        ps[i].joinedSetIndexes = nil
    }

    /// Move part `id` to `[start, end]`, clamped so it and its neighbours stay at least `minPartSec` (a timeout can
    /// shrink to that but not vanish); the neighbours' touching edges follow. The first part always starts at 0 and
    /// the last always ends at `duration`.
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

    // MARK: Why a choice is off (the one-line reason under a disabled control)

    static let timeoutReason = "A timeout sits between two halves of the same game."
    static let splitTimeoutReason = "A timeout can’t be split. Change it to a break first."
    static let mergeTimeoutReason = "A timeout joins its two halves. To make it one part, use Merge with next on the half before it."
    static let mergeLastReason = "This is the last part. Nothing comes after it."

    /// Why "Timeout" can't be chosen for part `i` (nil when it can): the parts before and after must be game halves
    /// that belong the same way.
    static func timeoutBlock(_ ps: [RacketVideoPart], index i: Int) -> String? {
        guard ps.indices.contains(i) else { return timeoutReason }
        if ps[i].kind == .timeout { return nil }
        guard i > 0, i < ps.count - 1, ps[i - 1].kind == .game, ps[i + 1].kind == .game,
              ps[i - 1].belongs == ps[i + 1].belongs else { return timeoutReason }
        return nil
    }

    static func splitBlock(_ ps: [RacketVideoPart], index i: Int) -> String? {
        ps.indices.contains(i) && ps[i].kind == .timeout ? splitTimeoutReason : nil
    }

    static func mergeBlock(_ ps: [RacketVideoPart], index i: Int) -> String? {
        guard ps.indices.contains(i) else { return mergeLastReason }
        if ps[i].kind == .timeout { return mergeTimeoutReason }
        if i == ps.count - 1 { return mergeLastReason }
        return nil
    }

    /// What "Merge with next" will do when it isn't the plain merge (said under the buttons before it's tapped).
    static func mergeNote(_ ps: [RacketVideoPart], index i: Int, unit: RacketUnit) -> String? {
        guard ps.indices.contains(i), i + 1 < ps.count, ps[i].kind == .game, ps[i + 1].kind == .timeout,
              let g = RacketGameGroups.group(of: i, in: ps) else { return nil }
        let n = g.timeouts.count
        return "Merge with next makes this whole \(unit.noun) one part, \(n == 1 ? "its timeout" : "its \(n) timeouts") included. Nothing is skipped any more."
    }

    // MARK: Operations

    /// "Split here": part `id` becomes two at `t` (both keep its kind). The piece that still touches a timeout stays
    /// in the game group and the group keeps its link; a detached piece is a new game with no link (a plain game
    /// keeps its link on the first piece). Ignored when either piece would be shorter than `minPartSec`, and for a
    /// timeout (`splitBlock`).
    static func split(_ parts: [RacketVideoPart], id: UUID, at t: Double) -> [RacketVideoPart] {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return parts }
        let p = parts[i]
        guard p.kind != .timeout, t - p.startSec >= minPartSec, p.endSec - t >= minPartSec else { return parts }
        var first = p
        first.endSec = t
        var second = RacketVideoPart(kind: p.kind, startSec: t, endSec: p.endSec)
        second.belongs = p.belongs
        if p.kind == .game, let g = RacketGameGroups.group(of: i, in: parts), g.isGrouped, g.first == i {
            // The first half of a group: the second piece is the one touching the timeout, so it carries the link.
            second.setIndex = first.setIndex
            second.joinedSetIndexes = first.joinedSetIndexes
            first.setIndex = nil
            first.joinedSetIndexes = nil
        }
        var ps = parts
        ps.replaceSubrange(i...i, with: [first, second])
        return repairGroups(ps)
    }

    /// "Merge with next": part `id` takes the next part's range (it keeps its own kind and game link; a game with no
    /// link takes the next one's). A game half followed by its own timeout merges its **whole** game — halves and
    /// timeouts — into one plain part (`mergeNote`). Not offered for a timeout or the last part (`mergeBlock`).
    static func mergeWithNext(_ parts: [RacketVideoPart], id: UUID) -> [RacketVideoPart] {
        guard let i = parts.firstIndex(where: { $0.id == id }), mergeBlock(parts, index: i) == nil else { return parts }
        var ps = parts
        if ps[i].kind == .game, ps[i + 1].kind == .timeout, let g = RacketGameGroups.group(of: i, in: ps) {
            var m = ps[g.first]
            m.endSec = ps[g.last].endSec
            var joined = m.joinedSetIndexes ?? []
            for h in g.halves.dropFirst() { joined += RacketGameGroups.links(ps[h]) }
            m.joinedSetIndexes = joined.isEmpty ? nil : joined
            ps.replaceSubrange(g.first...g.last, with: [m])
            return repairGroups(ps)
        }
        if ps[i].kind != .game { handOff(&ps, from: i + 1) }
        let next = ps[i + 1]
        ps[i].endSec = next.endSec
        let holder = ps[i].kind == .game ? (RacketGameGroups.group(of: i, in: ps)?.first ?? i) : i
        if ps[holder].setIndex == nil, ps[holder].kind.counts { ps[holder].setIndex = next.setIndex }
        ps.remove(at: i + 1)
        return repairGroups(ps)
    }

    /// "What is this part?". Timeout only where `timeoutBlock` allows: the halves either side become one game, and a
    /// game this part was becomes part of it too. A game half that leaves its group hands the group's link to the
    /// next half; the timeouts beside it become breaks. An unsure stretch that becomes a game is this match's.
    static func setKind(_ parts: [RacketVideoPart], id: UUID, kind: RacketPartKind) -> [RacketVideoPart] {
        guard let i = parts.firstIndex(where: { $0.id == id }), parts[i].kind != kind else { return parts }
        if kind == .timeout, timeoutBlock(parts, index: i) != nil { return parts }
        var ps = parts
        if ps[i].kind == .game && kind != .game {
            if kind == .timeout {
                // A game between two games: its own logged game joins the game it is now inside.
                let mine = RacketGameGroups.links(ps[i])
                if !mine.isEmpty { ps[i + 1].joinedSetIndexes = mine + (ps[i + 1].joinedSetIndexes ?? []) }
                ps[i].setIndex = nil
                ps[i].joinedSetIndexes = nil
            } else {
                handOff(&ps, from: i)
            }
        }
        ps[i].kind = kind
        if !kind.counts { ps[i].setIndex = nil }
        if kind != .game { ps[i].joinedSetIndexes = nil }
        if kind != .game && kind != .unsure { ps[i].belongs = nil }
        return repairGroups(ps)
    }

    /// "Belongs to": this match makes the stretch a game (every half of its game follows); practice makes it an
    /// unsure stretch, uncounted.
    static func setBelongs(_ parts: [RacketVideoPart], id: UUID, belongs: RacketPartBelongs) -> [RacketVideoPart] {
        guard let i = parts.firstIndex(where: { $0.id == id }) else { return parts }
        var ps = parts
        if belongs == .practice {
            if ps[i].kind == .game { handOff(&ps, from: i) }
            ps[i].belongs = .practice
            ps[i].kind = .unsure
            ps[i].setIndex = nil
            ps[i].joinedSetIndexes = nil
        } else {
            ps[i].belongs = .thisMatch
            ps[i].kind = .game
            if let g = RacketGameGroups.group(of: i, in: ps) { for h in g.halves { ps[h].belongs = .thisMatch } }
        }
        return repairGroups(ps)
    }
}

// MARK: - Joining logged games (the confirm sheet) and saving

/// Joining two halves that each have a logged game makes them one game. With two or more scores the player confirms
/// first ("Game 4 and Game 5 become one game: 6–5 + 5–3 = 11–8"); a game with no score just folds into the other.
enum RacketSplitJoin {
    struct Preview: Equatable, Sendable {
        /// "Game 4 and Game 5 become one game"
        var title: String
        /// "6–5 + 5–3 = 11–8"
        var scoreLine: String
        var needsConfirm: Bool
    }

    /// A score or a suggested one (from a join or from tags), whichever the game has.
    static func score(_ s: SetLog) -> RacketUnitScore? { s.racketScore ?? s.suggestedScore }

    /// What choosing a kind for part `id` will join: nil when it joins no logged games together. `ordinal` names a
    /// logged game ("Game 4") the way the match does.
    static func preview(before: [RacketVideoPart], after: [RacketVideoPart], id: UUID, sets: [SetLog],
                        unit: RacketUnit, ordinal: (Int) -> Int) -> Preview? {
        guard let i = after.firstIndex(where: { $0.id == id }), let g = RacketGameGroups.group(of: i, in: after) else { return nil }
        let links = g.halves.flatMap { RacketGameGroups.links(after[$0]) }.filter { $0 >= 0 && $0 < sets.count }.sorted()
        let beforeLinks = Set(RacketGameGroups.groups(before).compactMap { bg -> [Int]? in
            let ls = bg.halves.flatMap { RacketGameGroups.links(before[$0]) }
            return ls.count > 1 ? nil : ls
        }.flatMap { $0 })
        // Only games that were on their own before and are now in one game together.
        guard links.count > 1, links.contains(where: beforeLinks.contains) else { return nil }
        let noun = unit.noun.capitalized
        let names = links.map { "\(noun) \(ordinal($0))" }
        let title = (names.count == 2 ? "\(names[0]) and \(names[1])" : names.dropLast().joined(separator: ", ") + " and \(names.last ?? "")")
            + " become one \(unit.noun)"
        let scores = links.compactMap { score(sets[$0]) }
        let line: String
        if scores.count >= 2 {
            let f = scores.reduce(0) { $0 + $1.scoreFor }, a = scores.reduce(0) { $0 + $1.scoreAgainst }
            line = scores.map { "\($0.scoreFor)–\($0.scoreAgainst)" }.joined(separator: " + ") + " = \(f)–\(a)"
        } else if let s = scores.first {
            line = "keeps \(s.scoreFor)–\(s.scoreAgainst)"
        } else {
            line = "no score yet"
        }
        return Preview(title: title, scoreLine: line, needsConfirm: scores.count >= 2)
    }

    /// One logged game from several: two or more scores are summed into a suggested score, "Score unconfirmed" until
    /// the player confirms it; a single score is kept as it was; durations add up (played time); it is logged at the
    /// latest end.
    static func merge(_ kept: SetLog, _ others: [SetLog]) -> SetLog {
        var k = kept
        let all = [kept] + others
        let scores = all.compactMap(score)
        if scores.count >= 2 {
            k.scoreFor = nil; k.scoreAgainst = nil; k.tiebreakFor = nil; k.tiebreakAgainst = nil; k.superTiebreak = nil
            k.scoreFromWatch = nil
            k.scoreUnconfirmed = true
            k.suggestedFor = scores.reduce(0) { $0 + $1.scoreFor }
            k.suggestedAgainst = scores.reduce(0) { $0 + $1.scoreAgainst }
        } else if score(kept) == nil, let src = others.first(where: { score($0) != nil }) {
            k.scoreFor = src.scoreFor; k.scoreAgainst = src.scoreAgainst
            k.tiebreakFor = src.tiebreakFor; k.tiebreakAgainst = src.tiebreakAgainst; k.superTiebreak = src.superTiebreak
            k.scoreFromWatch = src.scoreFromWatch
            k.scoreUnconfirmed = src.scoreUnconfirmed
            k.suggestedFor = src.suggestedFor; k.suggestedAgainst = src.suggestedAgainst
        }
        let durations = all.compactMap(\.durationSec)
        k.durationSec = durations.isEmpty ? nil : durations.reduce(0, +)
        k.completedAt = all.compactMap(\.completedAt).max()
        return k
    }

    /// Fold every group's joined games into its game and drop them from the match; later games move up. `remap` maps
    /// every old set index to its new one (a joined game to the game it joined).
    static func commit(parts input: [RacketVideoPart], sets input2: [SetLog]) -> (parts: [RacketVideoPart], sets: [SetLog], remap: [Int: Int]) {
        var ps = input
        var sets = input2
        var absorbed: [Int: Int] = [:]
        for g in RacketGameGroups.groups(ps) {
            // The earliest logged game is the one kept (the others fold into it).
            let links = g.halves.flatMap { RacketGameGroups.links(ps[$0]) }.filter { $0 >= 0 && $0 < sets.count }.sorted()
            for h in g.halves { ps[h].joinedSetIndexes = nil; ps[h].setIndex = nil }
            guard let kept = links.first else { continue }
            ps[g.first].setIndex = kept
            let others = Array(links.dropFirst())
            if !others.isEmpty {
                sets[kept] = merge(sets[kept], others.map { sets[$0] })
                for o in others { absorbed[o] = kept }
            }
        }
        for i in ps.indices { ps[i].joinedSetIndexes = nil }
        let removed = absorbed.keys.sorted()
        for r in removed.reversed() { sets.remove(at: r) }
        func newIndex(_ old: Int) -> Int {
            let target = absorbed[old] ?? old
            return target - removed.filter { $0 < target }.count
        }
        for i in ps.indices { if let s = ps[i].setIndex { ps[i].setIndex = newIndex(s) } }
        var remap: [Int: Int] = [:]
        for old in input2.indices { remap[old] = newIndex(old) }
        return (ps, sets, remap)
    }
}

/// Saving an edited split: repair it, fold joined games, then link every game to its logged game
/// (`RacketSplitAssign.apply`). `remap` maps each old set index to its new one, for anything else that points at a
/// game by index (a photo or clip attached to it).
enum RacketSplitCommit {
    struct Outcome: Equatable, Sendable {
        var parts: [RacketVideoPart]
        var sets: [SetLog]
        var added: Int
        var remap: [Int: Int]
    }

    static func apply(parts: [RacketVideoPart], sets: [SetLog], base: Int, startedAt: Date, duration: Double,
                      rallies: [RacketRally] = []) -> Outcome {
        let ps = RacketSplitEditor.normalized(parts, duration: duration)
        let j = RacketSplitJoin.commit(parts: ps, sets: sets)
        let out = RacketSplitAssign.apply(parts: j.parts, sets: j.sets, base: base, startedAt: startedAt, rallies: rallies)
        // Compose: old → after the join → after the assignment's reordering.
        var after: [Int: Int] = [:]
        for (new, src) in out.sourceIndex.enumerated() { if let src { after[src] = new } }
        var remap: [Int: Int] = [:]
        for (old, mid) in j.remap { if let n = after[mid] { remap[old] = n } }
        return Outcome(parts: out.parts, sets: out.sets, added: out.added, remap: remap)
    }
}

// MARK: - A suggested score (a join, or your tags), unconfirmed

extension SetLog {
    /// A score the app suggests for a game still "Score unconfirmed" (two joined games' sum, or the tags of a game
    /// that came back from a join); the player confirms it in Edit score. It counts for neither side until then.
    var suggestedScore: RacketUnitScore? {
        guard racketScore == nil, let f = suggestedFor, let a = suggestedAgainst else { return nil }
        return RacketUnitScore(scoreFor: f, scoreAgainst: a, tiebreakFor: nil, tiebreakAgainst: nil, superTiebreak: false)
    }
}
