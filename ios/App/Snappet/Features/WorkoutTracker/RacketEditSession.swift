import Foundation

// MARK: - Racket player, Edit mode and Share (prompt 254, issue #448 part 1 "Edit" and "Share")
//
// Boards EditRallies → EditList, ShareSheet, ShareExport: Apple Photos' video Edit mode. Everything in Edit is a working
// copy (`RacketEditSession`): Done commits, Cancel discards, Undo / Redo cover every edit. Pure (Foundation only), so it
// runs in SnappetTests (`RacketEditSessionTests`); `RacketEditViews.swift` renders it.

// MARK: - Looks (EditLooks)

/// The five presets. They change playback and shared copies only: the video in Photos stays as filmed, and rally finding
/// reads the original (#448 decision).
enum RacketLook: String, Codable, CaseIterable, Sendable {
    case original, vivid, warm, cool, bw

    var label: String {
        switch self {
        case .original: return "Original"
        case .vivid: return "Vivid"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .bw: return "B&W"
        }
    }

    /// The filter settings, in Core Image's terms (`CIColorControls` + `CITemperatureAndTint`). Pure numbers, so the
    /// renderer (Services) and the tests read the same thing.
    struct Params: Equatable, Sendable {
        var saturation: Double = 1
        var contrast: Double = 1
        var brightness: Double = 0
        /// Target white point in kelvin for `CITemperatureAndTint` (6500 = no change; lower = warmer).
        var temperature: Double = 6500
    }

    var params: Params {
        switch self {
        case .original: return Params()
        case .vivid: return Params(saturation: 1.35, contrast: 1.08, brightness: 0.01)
        case .warm: return Params(saturation: 1.05, temperature: 4600)
        case .cool: return Params(saturation: 0.98, temperature: 8800)
        case .bw: return Params(saturation: 0, contrast: 1.1)
        }
    }

    var isOriginal: Bool { self == .original }
}

/// "Use for": This video / Whole match / Always.
enum RacketLookScope: String, Codable, CaseIterable, Sendable {
    case thisVideo, wholeMatch, always

    var label: String {
        switch self {
        case .thisVideo: return "This video"
        case .wholeMatch: return "Whole match"
        case .always: return "Always"
        }
    }
}

/// A look chosen for one video (a part of a recording), stored on the recording log (prompt 254, additive).
struct RacketPartLook: Codable, Hashable, Sendable {
    var startSec: Double
    var lookRaw: String
}

enum RacketLookStore {
    /// The UserDefaults key for "Always".
    static let alwaysKey = "racketLookAlways"

    /// The look a part plays with, and where it comes from: the part's own, else the match's, else "Always", else Original.
    static func resolve(partStart: Double, log: RacketRecordingLog?, always: RacketLook?) -> (look: RacketLook, scope: RacketLookScope) {
        if let p = log?.partLooks?.first(where: { abs($0.startSec - partStart) < 0.01 }),
           let l = RacketLook(rawValue: p.lookRaw) { return (l, .thisVideo) }
        if let raw = log?.lookRaw, let l = RacketLook(rawValue: raw) { return (l, .wholeMatch) }
        if let always { return (always, .always) }
        return (.original, .thisVideo)
    }

    /// Save a choice. This video: the part's own entry. Whole match: the recording's look (the parts' own entries go,
    /// so every part shows it). Always: the recording's entries go and the caller stores `look` as the default.
    static func apply(_ look: RacketLook, scope: RacketLookScope, partStart: Double, to log: inout RacketRecordingLog) {
        var parts = (log.partLooks ?? []).filter { abs($0.startSec - partStart) >= 0.01 }
        switch scope {
        case .thisVideo:
            parts.append(RacketPartLook(startSec: partStart, lookRaw: look.rawValue))
        case .wholeMatch:
            parts = []
            log.lookRaw = look.rawValue
        case .always:
            parts = []
            log.lookRaw = nil
        }
        log.partLooks = parts.isEmpty ? nil : parts
    }
}

// MARK: - The working copy

/// What Undo / Redo step through: the part's rallies, the look and any edited scores.
struct RacketEditState: Equatable, Sendable {
    var rallies: [RacketRally]
    var look: RacketLook
    var lookScope: RacketLookScope
    /// Edited game scores by set index (Score tab); saved confirmed on Done.
    var scores: [Int: RacketUnitScore] = [:]
}

/// Edit mode's working copy of one part (a game or block): every edit goes through here, with Undo / Redo, and nothing
/// reaches the session until Done (`state` is then written back). Rallies never overlap.
struct RacketEditSession: Equatable, Sendable {
    static let minRallySec = RacketRallyMarking.minRallySec

    enum Edge: String, Equatable, Sendable { case start, end }

    let lo: Double
    let hi: Double
    let original: RacketEditState
    private(set) var state: RacketEditState
    private var undoStack: [RacketEditState] = []
    private var redoStack: [RacketEditState] = []
    /// A drag in progress (a trim handle): its starting state, pushed once when the drag ends with a change.
    private var liveStart: RacketEditState?

    init(rallies: [RacketRally], lo: Double, hi: Double, look: RacketLook = .original, lookScope: RacketLookScope = .thisVideo,
         scores: [Int: RacketUnitScore] = [:]) {
        self.lo = lo
        self.hi = hi
        let s = RacketEditState(rallies: rallies.sorted { $0.startSec < $1.startSec }, look: look, lookScope: lookScope, scores: scores)
        original = s
        state = s
    }

    var rallies: [RacketRally] { state.rallies }
    /// The rallies shown on the strip and counted ("Not a rally" kept but hidden).
    var visible: [RacketRally] { state.rallies.filter(\.isRally) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func rally(_ id: UUID?) -> RacketRally? { id.flatMap { i in state.rallies.first { $0.id == i } } }

    /// 1-based number among the visible rallies.
    func number(of id: UUID) -> Int? { visible.firstIndex { $0.id == id }.map { $0 + 1 } }

    func rally(at t: Double) -> RacketRally? { visible.first { t >= $0.startSec && t < $0.endSec } }

    // MARK: Undo / Redo

    private mutating func change(_ body: (inout RacketEditState) -> Void) {
        var s = state
        body(&s)
        s.rallies.sort { $0.startSec < $1.startSec }
        guard s != state else { return }
        if liveStart == nil { undoStack.append(state); redoStack = [] }
        state = s
    }

    mutating func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    /// A drag begins: its moves don't each add an Undo step.
    mutating func beginLive() { if liveStart == nil { liveStart = state } }

    /// The drag ended: one Undo step for the whole drag (none if nothing moved).
    mutating func endLive() {
        guard let start = liveStart else { return }
        liveStart = nil
        if start != state { undoStack.append(start); redoStack = [] }
    }

    // MARK: Changes (EditDiscard)

    /// Rallies added, removed or changed since Edit opened.
    var changedRallies: Int {
        let before = Dictionary(original.rallies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(state.rallies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let removed = before.keys.filter { after[$0] == nil }.count
        let addedOrChanged = after.filter { before[$0.key] != $0.value }.count
        return removed + addedOrChanged
    }

    var scoreChanged: Bool { state.scores != original.scores }
    var lookChanged: Bool { state.look != original.look || state.lookScope != original.lookScope }
    var hasChanges: Bool { changedRallies > 0 || scoreChanged || lookChanged }

    /// "You changed 3 rallies", "You changed 1 rally and the score", "You changed the look".
    var discardLine: String {
        var parts: [String] = []
        let n = changedRallies
        if n > 0 { parts.append("\(n) \(n == 1 ? "rally" : "rallies")") }
        if scoreChanged { parts.append("the score") }
        if lookChanged { parts.append("the look") }
        guard !parts.isEmpty else { return "No changes" }
        let joined = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "You changed \(joined)"
    }

    /// "21 rallies · 19 tagged".
    var countLine: String {
        let n = visible.count
        return "\(n) \(n == 1 ? "rally" : "rallies") · \(visible.filter(\.isTagged).count) tagged"
    }

    // MARK: Trim (EditTrim)

    /// Where an edge may go: the part, the neighbouring rally on that side, and the minimum length. A hidden stretch
    /// marked "Not a rally" doesn't stop a handle.
    func limits(_ id: UUID, _ edge: Edge) -> ClosedRange<Double>? {
        guard let r = rally(id) else { return nil }
        let others = visible.filter { $0.id != id }
        switch edge {
        case .start:
            let lower = max(lo, others.filter { $0.endSec <= r.startSec + 0.01 }.map(\.endSec).max() ?? lo)
            return lower...max(lower, r.endSec - Self.minRallySec)
        case .end:
            let upper = min(hi, others.filter { $0.startSec >= r.endSec - 0.01 }.map(\.startSec).min() ?? hi)
            return min(upper, r.startSec + Self.minRallySec)...upper
        }
    }

    /// Move an edge to `t`, stopped at its neighbour and the minimum length; returns where it landed. Inside a drag
    /// (`beginLive`) it adds no Undo step of its own.
    @discardableResult
    mutating func trim(_ id: UUID, _ edge: Edge, to t: Double) -> Double? {
        guard let range = limits(id, edge) else { return nil }
        let v = min(max(t, range.lowerBound), range.upperBound)
        change { s in
            guard let i = s.rallies.firstIndex(where: { $0.id == id }) else { return }
            if edge == .start { s.rallies[i].startSec = v } else { s.rallies[i].endSec = v }
            // Moving a guess's edge means you've looked at it (as FixRally, prompt 248).
            if s.rallies[i].isFromModel { s.rallies[i].confirmed = true }
        }
        return v
    }

    /// −1 s / −0.2 s / +0.2 s / +1 s on the handle last touched.
    @discardableResult
    mutating func nudge(_ id: UUID, _ edge: Edge, by d: Double) -> Double? {
        guard let r = rally(id) else { return nil }
        return trim(id, edge, to: (edge == .start ? r.startSec : r.endSec) + d)
    }

    // MARK: Rallies tab

    /// + Rally's finished mark (see `RacketEditMark.finish`): added and returned (to select it for tagging).
    @discardableResult
    mutating func add(_ range: ClosedRange<Double>) -> UUID {
        let r = RacketRally(startSec: range.lowerBound, endSec: range.upperBound)
        change { s in
            // A stretch marked "Not a rally" under the new one gives way to it.
            s.rallies.removeAll { !$0.isRally && $0.startSec < r.endSec - 0.01 && $0.endSec > r.startSec + 0.01 }
            s.rallies.append(r)
        }
        return r.id
    }

    /// Split at the playhead: only inside a rally, leaving both halves at least the minimum. The first half keeps the
    /// tags. Returns the rally split, or nil.
    func splittable(at t: Double) -> RacketRally? {
        guard let r = rally(at: t), t - r.startSec >= Self.minRallySec, r.endSec - t >= Self.minRallySec else { return nil }
        return r
    }

    @discardableResult
    mutating func split(at t: Double) -> Bool {
        guard let r = splittable(at: t) else { return false }
        change { $0.rallies = RacketRallyMarking.splitInTwo($0.rallies, id: r.id, at: t) }
        return true
    }

    /// The next rally in time (Merge next).
    func next(after id: UUID) -> RacketRally? {
        guard let r = rally(id) else { return nil }
        return visible.first { $0.startSec >= r.endSec - 0.01 && $0.id != id }
    }

    /// Merge next: the next rally folds into this one (this one keeps its tags). Anything marked "Not a rally" between
    /// them goes too, so rallies never overlap.
    @discardableResult
    mutating func mergeNext(_ id: UUID) -> Bool {
        guard let r = rally(id), let n = next(after: id) else { return false }
        change { s in
            s.rallies.removeAll { $0.id == n.id || (!$0.isRally && $0.startSec >= r.endSec - 0.01 && $0.endSec <= n.endSec + 0.01) }
            if let i = s.rallies.firstIndex(where: { $0.id == id }) { s.rallies[i].endSec = max(r.endSec, n.endSec) }
        }
        return true
    }

    mutating func notRally(_ id: UUID) {
        change { $0.rallies = RacketRallyMarking.tag($0.rallies, id: id, winner: nil, ending: nil, lastShotBy: nil, notRally: true) }
    }

    /// The tag inspector: winner, ending, last shot, serve, wall — the same rules as the tag sheet (`RacketRallyMarking.tag`).
    mutating func setTags(_ id: UUID, winner: RacketRallyWinner?, ending: RacketRallyEnding?, lastShotBy: String?,
                          serve: RacketServeOutcome?? = nil, wall: RacketWallBounce?? = nil) {
        change { $0.rallies = RacketRallyMarking.tag($0.rallies, id: id, winner: winner, ending: ending, lastShotBy: lastShotBy,
                                                     notRally: false, serve: serve, wall: wall) }
    }

    /// Tap a winner chip: picks it, or clears it when it's already picked.
    mutating func toggleWinner(_ id: UUID, _ w: RacketRallyWinner) {
        guard let r = rally(id) else { return }
        setTags(id, winner: r.winner == w ? nil : w, ending: r.ending, lastShotBy: r.lastShotBy)
    }

    mutating func toggleEnding(_ id: UUID, _ e: RacketRallyEnding) {
        guard let r = rally(id) else { return }
        let ending: RacketRallyEnding? = r.ending == e ? nil : e
        // A replay (let) has no winner, as on the tag sheet's let sheet.
        setTags(id, winner: ending?.isReplay == true ? nil : r.winner, ending: ending, lastShotBy: r.lastShotBy)
    }

    mutating func setLastShot(_ id: UUID, _ who: String?) {
        guard let r = rally(id) else { return }
        setTags(id, winner: r.winner, ending: r.ending, lastShotBy: who)
    }

    mutating func setShots(_ id: UUID, _ shots: [RacketShot]) {
        change { s in
            guard let i = s.rallies.firstIndex(where: { $0.id == id }) else { return }
            s.rallies[i].shots = RacketShotTagging.stored(shots)
        }
    }

    /// Find rallies finished: the scan's guesses replace earlier guesses you haven't confirmed; a guess that overlaps
    /// anything else (yours, or one you've confirmed) is dropped — yours are never replaced. Returns how many were added.
    @discardableResult
    mutating func mergeFound(_ guesses: [RacketRally]) -> Int {
        var added = 0
        let lo = lo, hi = hi
        change { s in
            s.rallies.removeAll(where: \.isGuess)
            for g in guesses.sorted(by: { $0.startSec < $1.startSec }) {
                let a = max(lo, g.startSec), b = min(hi, g.endSec)
                guard b - a >= Self.minRallySec, !RacketRallyMarking.overlaps(a, b, s.rallies, except: nil) else { continue }
                var q = g
                q.startSec = a
                q.endSec = b
                s.rallies.append(q)
                added += 1
            }
        }
        return added
    }

    // MARK: Looks and Score tabs

    mutating func setLook(_ look: RacketLook) { change { $0.look = look } }
    mutating func setLookScope(_ scope: RacketLookScope) { change { $0.lookScope = scope } }
    mutating func setScore(_ index: Int, _ score: RacketUnitScore) { change { $0.scores[index] = score } }
}

// MARK: - + Rally (EditMarking)

enum RacketEditMark {
    enum Problem: Error, Equatable, Sendable {
        /// The playhead is inside a rally already.
        case insideRally
        /// What's left between the neighbours is shorter than a rally.
        case tooShort

        var message: String {
            switch self {
            case .insideRally: return "There’s a rally here already. Move to a gap, then tap + Rally."
            case .tooShort: return "Too short for a rally. Let it play a little longer, then end it."
            }
        }
    }

    /// Can a mark start at `t`? Not inside an existing rally.
    static func canStart(at t: Double, rallies: [RacketRally]) -> Problem? {
        rallies.contains { t >= $0.startSec && t < $0.endSec - 0.01 } ? .insideRally : nil
    }

    /// End a mark started at `start` with the playhead at `end`. Decision (prompt 254): a mark that runs into a rally is
    /// **clamped** to the gap it started in (it ends where the next rally starts, or starts where the last one ended), and
    /// `clamped` says so; it's refused only when it started inside a rally or what's left is shorter than a rally.
    static func finish(start: Double, end: Double, rallies: [RacketRally], lo: Double, hi: Double)
        -> Result<(range: ClosedRange<Double>, clamped: Bool), Problem> {
        if let p = canStart(at: start, rallies: rallies) { return .failure(p) }
        let gapLo = max(lo, rallies.filter { $0.endSec <= start + 0.01 }.map(\.endSec).max() ?? lo)
        let gapHi = min(hi, rallies.filter { $0.startSec >= start - 0.01 }.map(\.startSec).min() ?? hi)
        let a0 = min(start, end), b0 = max(start, end)
        let a = max(a0, gapLo), b = min(b0, gapHi)
        guard b - a >= RacketEditSession.minRallySec else { return .failure(.tooShort) }
        return .success((a...b, a != a0 || b != b0))
    }

    /// "Marking · 3.2 s".
    static func line(start: Double, now: Double) -> String { "Marking · " + RacketPlayerText.seconds(abs(now - start)) }
}

// MARK: - The time ruler and the strip's zoom

enum RacketEditRuler {
    static let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800]

    /// The smallest step whose labels sit at least `minSpacing` points apart.
    static func step(pointsPerSec: Double, minSpacing: Double = 64) -> Double {
        steps.first { $0 * pointsPerSec >= minSpacing } ?? steps.last!
    }

    /// Label times (multiples of `step`) within `[a, b]`.
    static func ticks(from a: Double, to b: Double, step: Double) -> [Double] {
        guard step > 0, b >= a else { return [] }
        var t = (a / step).rounded(.up) * step
        var out: [Double] = []
        while t <= b + 0.0001 { out.append(t); t += step }
        return out
    }
}

enum RacketEditZoom {
    /// EditRallies: about 20 s across the strip.
    static func initial(visibleWidth: Double) -> Double { visibleWidth / 20 }

    /// Pinch: from the whole part across the strip, to about 1.5 s across it.
    static func clamp(_ pps: Double, visibleWidth: Double, duration: Double) -> Double {
        let lower = visibleWidth / max(1, duration)
        let upper = max(lower, visibleWidth / 1.5)
        return min(upper, max(lower, pps))
    }

    /// EditTrim "the handle clicks at each second": crossing a whole second between two drag positions.
    static func crossedSecond(from a: Double, to b: Double) -> Bool { a.rounded(.down) != b.rounded(.down) }

    /// The frame step (‹ ›): one frame at 30 fps.
    static let frameSec: Double = 1.0 / 30
}

// MARK: - Rally list (EditList)

enum RacketEditListFilter: String, CaseIterable, Sendable {
    case all, won, lost, untagged

    var label: String {
        switch self {
        case .all: return "All"
        case .won: return "Won"
        case .lost: return "Lost"
        case .untagged: return "Untagged"
        }
    }

    func matches(_ r: RacketRally) -> Bool {
        switch self {
        case .all: return true
        case .won: return r.winner == .us
        case .lost: return r.winner == .them
        case .untagged: return !r.isTagged
        }
    }

    /// "All 21", "Won 12".
    func chip(_ rallies: [RacketRally]) -> String { "\(label) \(rallies.filter(matches).count)" }
}

enum RacketEditList {
    struct Row: Equatable, Identifiable, Sendable {
        var id: UUID
        var number: Int
        /// "08:11 · 6.2 s".
        var detail: String
        /// "You won", "Alex won", "Untagged", "Suggested".
        var result: String
        var untagged: Bool
        var startSec: Double
    }

    static func rows(_ visible: [RacketRally], filter: RacketEditListFilter, partStart: Double,
                     sides: (us: String, them: String)) -> [Row] {
        visible.enumerated().compactMap { k, r in
            guard filter.matches(r) else { return nil }
            let result: String
            switch r.winner {
            case .us: result = "\(sides.us) won"
            case .them: result = "\(sides.them) won"
            case nil: result = r.isGuess ? "Suggested" : r.isTagged ? "Replayed" : "Untagged"
            }
            return Row(id: r.id, number: k + 1,
                       detail: "\(RacketPlayerText.clock(r.startSec - partStart)) · \(RacketPlayerText.seconds(r.durationSec))",
                       result: result, untagged: !r.isTagged, startSec: r.startSec)
        }
    }

    /// Next untagged after the playhead, wrapping round.
    static func nextUntagged(_ visible: [RacketRally], after t: Double) -> RacketRally? {
        let untagged = visible.filter { !$0.isTagged }
        return untagged.first { $0.startSec > t + 0.05 } ?? untagged.first
    }
}

// MARK: - Score tab (EditScore)

extension RacketEditScoreCopy {
    /// "From your tags: You 12, Alex 9. Done marks the score confirmed."
    static func fromTags(_ rallies: [RacketRally], sides: (us: String, them: String)) -> String {
        let us = rallies.filter { $0.isRally && $0.winner == .us }.count
        let them = rallies.filter { $0.isRally && $0.winner == .them }.count
        return "From your tags: \(sides.us) \(us), \(sides.them) \(them). Done marks the score confirmed."
    }
}

// MARK: - Share (ShareSheet · ShareExport)

enum RacketShareWhich: String, CaseIterable, Sendable {
    case rally, ralliesOnly, whole

    var label: String {
        switch self {
        case .rally: return "This rally"
        case .ralliesOnly: return "Rallies only"
        case .whole: return "Whole game"
        }
    }
}

/// What a share makes: the recording ranges joined end to end, the length after the speed, an estimated size, and the
/// labels drawn into it. Pure (`RacketShareTests`); `RacketVideoLibrary.export` follows it.
struct RacketSharePlan: Equatable, Sendable {
    struct Label: Equatable, Sendable {
        /// On the output's clock.
        var start: Double
        var end: Double
        var text: String
    }

    var which: RacketShareWhich
    var ranges: [ClosedRange<Double>]
    var rallyCount: Int
    /// The playback speed the copy keeps (1 when "Keep the speed" is off).
    var speed: Double
    var sourceSec: Double
    var outputSec: Double
    var estimatedMB: Double
    var labels: [Label]

    /// Megabytes per minute of a shared copy (the export re-encodes near the recording's own rate).
    static func mbPerMinute(quality: RacketRecordingQuality?) -> Double { quality == .uhd4k ? 170 : 60 }

    /// nil when there's nothing to share (This rally with the playhead outside every rally, Rallies only with none).
    static func make(_ which: RacketShareWhich, rallies: [RacketRally], position: Double, partStart: Double, partEnd: Double,
                     rate: Float, keepSpeed: Bool, labels: Bool, sides: (us: String, them: String),
                     quality: RacketRecordingQuality?) -> RacketSharePlan? {
        let rs = RacketPlayerRallies(rallies)
        let ranges: [ClosedRange<Double>]
        let count: Int
        switch which {
        case .rally:
            guard let i = rs.index(at: position) ?? rs.lastStarted(at: position) else { return nil }
            ranges = [rs.rallies[i].startSec...rs.rallies[i].endSec]
            count = 1
        case .ralliesOnly:
            guard !rs.isEmpty else { return nil }
            ranges = RacketKeepRallies.ranges(rs.rallies, duration: partEnd)
                .map { max(partStart, $0.lowerBound)...min(partEnd, $0.upperBound) }
                .filter { $0.upperBound > $0.lowerBound }
            count = rs.count
        case .whole:
            guard partEnd > partStart else { return nil }
            ranges = [partStart...partEnd]
            count = rs.count
        }
        let speed = keepSpeed && rate > 0 ? Double(rate) : 1
        let source = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        let output = source / speed
        var out = RacketSharePlan(which: which, ranges: ranges, rallyCount: count, speed: speed, sourceSec: source,
                                  outputSec: output, estimatedMB: output / 60 * mbPerMinute(quality: quality), labels: [])
        if labels { out.labels = Self.labels(rs, ranges: ranges, speed: speed, sides: sides) }
        return out
    }

    /// "Rally 12 · You won · 7 – 5" over each rally in the copy, on the copy's clock (after the speed).
    static func labels(_ rs: RacketPlayerRallies, ranges: [ClosedRange<Double>], speed: Double,
                       sides: (us: String, them: String)) -> [Label] {
        var out: [Label] = []
        var cursor = 0.0
        for range in ranges {
            for (k, r) in rs.rallies.enumerated() where r.startSec < range.upperBound && r.endSec > range.lowerBound {
                let a = max(r.startSec, range.lowerBound) - range.lowerBound
                let b = min(r.endSec, range.upperBound) - range.lowerBound
                var text = "Rally \(k + 1) · \(RacketPlayerCopy.result(r, sides: sides))"
                if let s = rs.runningScore(at: r.startSec) { text += " · " + RacketPlayerText.score(s.us, s.them) }
                out.append(Label(start: (cursor + a) / speed, end: (cursor + b) / speed, text: text))
            }
            cursor += range.upperBound - range.lowerBound
        }
        return out
    }

    /// "12 rallies · 1:38", "Rally 12 · 0:06", "Whole game · 18:32".
    func summary(rallyNumber: Int? = nil) -> String {
        let length = RacketVideoTime.clock(outputSec)
        switch which {
        case .rally: return "Rally \(rallyNumber ?? 1) · \(length)"
        case .ralliesOnly: return "\(rallyCount) \(rallyCount == 1 ? "rally" : "rallies") · \(length)"
        case .whole: return "Whole game · \(length)"
        }
    }

    /// "about 96 MB".
    var sizeLine: String {
        estimatedMB >= 1000 ? String(format: "about %.1f GB", estimatedMB / 1000) : "about \(max(1, Int(estimatedMB.rounded()))) MB"
    }

    /// The Keep the speed subtitle: "0.5× · off shares at normal speed" / "0.5× · on, the copy plays at 0.5×" /
    /// "Playing at 1×".
    static func speedLine(rate: Float, keep: Bool) -> String {
        guard rate != 1 else { return "Playing at 1×" }
        let s = RacketPlayerText.speed(rate)
        return keep ? "\(s) · on, the copy plays at \(s)" : "\(s) · off shares at normal speed"
    }

    /// ShareExport: "Preparing 12 rallies · 64%".
    func progressLine(_ fraction: Double) -> String {
        let what: String
        switch which {
        case .rally: what = "this rally"
        case .ralliesOnly: what = "\(rallyCount) \(rallyCount == 1 ? "rally" : "rallies")"
        case .whole: what = "the whole game"
        }
        return "Preparing \(what) · \(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

extension RacketPlayerText {
    /// "08:14.2" — Edit's playhead, to a tenth.
    static func tenths(_ sec: Double) -> String {
        let t = max(0, sec)
        let whole = t.rounded(.down)
        let tenth = min(9, Int(((t - whole) * 10).rounded(.down)))
        return "\(clock(whole)).\(tenth)"
    }
}

extension RacketShotTagging {
    /// Edit's "+ Shot at playhead": the next shot (sides alternate, as "+ Add a shot"), placed at `t` and kept in time
    /// order with the other shots that have a time.
    static func adding(to shots: [RacketShot], at t: Double, firstSide: RacketRallyWinner = .us) -> [RacketShot] {
        var added = adding(to: shots, firstSide: firstSide)
        added[added.count - 1].atSec = t
        let new = added[added.count - 1]
        var out = Array(added.dropLast())
        let i = out.firstIndex { ($0.atSec ?? -.infinity) > t } ?? out.count
        out.insert(new, at: i)
        return out
    }
}
