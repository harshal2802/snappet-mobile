import Foundation

// MARK: - Edit a logged match later (prompt 260) — pure
//
// "Edit match" opens one draft of a logged match: its games, its recording's applied split (as links from video to
// games) and its details. Every operation works on the draft; Cancel drops it, Save validates, repairs and commits it
// in one write (`RacketMatchSave`). A game in the draft has a stable id, so nothing that points at a game by its
// position (`RacketRecordingLog.baseSetIndex`, a split part's `setIndex`, a game-by-game `game` mark's `index`, a
// photo or clip's `SessionMedia.assignedSetIndex`) can drift: positions are only computed again on commit, from the
// ids. No Photos / AVFoundation / UIKit / SwiftUI here; the sheet is `RacketMatchEditViews.swift`, the tests
// `RacketMatchEditorTests`.
//
// Transition table (each row is a function below and a unit test; "blocked" rows return the one-line reason the
// sheet shows under the disabled control):
//
// | Operation | Precondition | Result |
// |---|---|---|
// | Score | any game | the score, confirmed (no longer "from Watch" / "Score unconfirmed"; a suggestion is cleared) |
// | Confirm score | a Watch tally or a suggested score | it becomes the confirmed score |
// | Confirm score | already confirmed, or nothing to confirm | blocked: `confirmBlock` |
// | Score unknown | any game | "Score unconfirmed": no score, counts for neither side |
// | Remove game | the match's only game | blocked: "This is the match’s only game. To remove it, use Remove match." |
// | Remove game | no video | it goes; later games move up |
// | Remove game | has video, no choice yet | nothing changes; the sheet asks |
// | Remove game | has video, "Keep as an extra game" | its video becomes "Rallies, no score" (not counted); its timeouts breaks |
// | Remove game | has video, "Mark as not play" | its video (halves and timeouts) becomes "Not play" |
// | Add game | position 0…count | a new game there, no video, "Score unconfirmed" unless a score is given |
// | Move earlier / later | at the edge | blocked: "Already the first game." / "Already the last game." |
// | Move earlier / later | it and the neighbour both have video | blocked: `videoOrderReason` |
// | Move earlier / later | otherwise | the two games swap |
// | Link video | the game has video | blocked: "Unlink its video first." |
// | Link video | the part is linked to another game | blocked: "Another game uses this video." |
// | Link video | the games would be out of video order | blocked: `linkOrderReason` |
// | Link video | otherwise (an unlinked game part or a "Rallies, no score" stretch) | linked; the part is a game; the game's time is the video's |
// | Unlink video | no video | blocked: "This game has no video." |
// | Unlink video | has video | its video becomes "Rallies, no score" (not counted, can be linked again); the game stays, no video |
// | Match details | always | opponent(s), partner, event, round, best of, points; a quiet note when the games no longer fit |
// | Move to another match | has video | blocked: "A game with video stays with its recording. Unlink its video first." |
// | Move to another match | the only game | blocked: the only-game reason |
// | Move to another match | no other match | blocked: "There’s no other match in this session." |
// | Move to another match | otherwise | it leaves this match; Save puts it in the other match by its time |
// | Cancel | any | the draft is dropped; nothing was written |
// | Save | any | `normalized`, then `validate` must be empty, then one commit |
//
// Invariants (`validate` reports each, `normalized` repairs each):
// 1. Every link (split part → game, game mark → game) points at a game in the draft; no game is linked twice.
// 2. Only a game group's first half holds a link; every game group has one (an unlinked one becomes "Rallies, no
//    score", never deleted); the parts pass `RacketSplitEditor.validate`.
// 3. Games with video are in the order of their video.
// 4. `base` (games logged before the recording) is within 0…count and never after a game with video.
// 5. A game's length fits its video: one longer than its video's span (+ `RacketSplitAssign.toleranceSec`) takes
//    the video's played time (`RacketGameDuration`).
// 6. A game moving to another match has no video; scores are not negative.

/// What happens to the video of a game that is removed.
enum RacketRemovedVideo: String, CaseIterable, Sendable {
    /// "Keep as an extra game (not counted in the match)": the stretch becomes "Rallies, no score".
    case extra
    /// "Mark as not play".
    case notPlay

    var label: String {
        switch self {
        case .extra: return "Keep as an extra game (not counted in the match)"
        case .notPlay: return "Mark as not play"
        }
    }
}

/// One logged match being edited.
struct RacketMatchDraft: Equatable {
    struct Game: Equatable, Identifiable {
        var id = UUID()
        var set: SetLog
        /// Its index when the editor opened; `nil` ⇒ added in this edit.
        var source: Int?
    }

    /// A game leaving for another match of the session.
    struct Outgoing: Equatable {
        var game: Game
        var to: UUID
    }

    var games: [Game]
    /// How many games were logged before the recording began (`RacketRecordingLog.baseSetIndex`).
    var base: Int
    /// The recording's applied split. In the draft every `setIndex` / `joinedSetIndexes` is nil: links live in `links`.
    var parts: [RacketVideoPart]
    /// Part id (a game group's first half) → game id.
    var links: [UUID: UUID]
    /// Index into the recording's marks (a game-by-game `game` mark) → game id.
    var markLinks: [Int: UUID]
    /// Where each of those marks starts on the recording (read only).
    var markStarts: [Int: Double] = [:]
    var hasRecording: Bool
    /// The recording's length on its own timeline (for validating the split).
    var duration: Double
    /// The recording's start: a linked game is logged at its video's end.
    var startedAt: Date?
    /// The recording's rallies (read only: counted when a removal would stop them counting).
    var rallies: [RacketRally]
    var details: RacketMatchParams
    var outgoing: [Outgoing] = []

    func index(of id: UUID) -> Int? { games.firstIndex { $0.id == id } }

    /// The first half of the game group linked to this game.
    func videoPart(of id: UUID) -> UUID? {
        links.filter { $0.value == id }.map(\.key).sorted { a, b in
            (parts.firstIndex { $0.id == a } ?? 0) < (parts.firstIndex { $0.id == b } ?? 0)
        }.first
    }

    func hasVideo(_ id: UUID) -> Bool { videoPart(of: id) != nil || markLinks.values.contains(id) }

    /// Where this game's video starts on the recording (its split part, else its game mark); nil ⇒ no video.
    func videoStart(of id: UUID) -> Double? {
        if let r = videoRange(of: id) { return r.lo }
        return markLinks.filter { $0.value == id }.compactMap { markStarts[$0.key] }.min()
    }

    /// The video's range on the recording (its group's first start → last end) and its timeouts.
    func videoRange(of id: UUID) -> (lo: Double, hi: Double, skips: [ClosedRange<Double>], played: Double)? {
        if let pid = videoPart(of: id), let i = parts.firstIndex(where: { $0.id == pid }),
           let g = RacketGameGroups.group(of: i, in: parts) {
            let lo = parts[g.first].startSec, hi = parts[g.last].endSec
            return (lo, hi, RacketGameGroups.skips(parts, from: lo, to: hi), RacketGameGroups.playedSec(parts, g))
        }
        return nil
    }
}

enum RacketMatchEditor {
    static let onlyGameReason = "This is the match’s only game. To remove it, use Remove match."
    static let firstReason = "Already the first game."
    static let lastReason = "Already the last game."
    static let videoOrderReason = "Both games have video, so they keep the order of their video. Change the split to fix the video."
    static let hasVideoLinkReason = "Unlink its video first."
    static let partTakenReason = "Another game uses this video."
    static let linkOrderReason = "This video would put the games out of order. Move the game first."
    static let noVideoReason = "This game has no video."
    static let moveVideoReason = "A game with video stays with its recording. Unlink its video first."
    static let noOtherMatchReason = "There’s no other match in this session."

    // MARK: Load

    /// The draft for `ex`, repaired (`normalized`) so it starts valid.
    static func draft(from ex: SessionExercise) -> RacketMatchDraft {
        let games = ex.sets.enumerated().map { RacketMatchDraft.Game(set: $1, source: $0) }
        let log = ex.racketRecordingLog
        var parts: [RacketVideoPart] = []
        var links: [UUID: UUID] = [:]
        if let split = log?.split, split.appliedAt != nil {
            parts = split.parts
            for i in parts.indices {
                // A saved split holds no joined games (Save folds them); a stray one is dropped as a link only.
                if let l = parts[i].setIndex, games.indices.contains(l) { links[parts[i].id] = games[l].id }
                parts[i].setIndex = nil
                parts[i].joinedSetIndexes = nil
            }
        }
        var markLinks: [Int: UUID] = [:]
        var markStarts: [Int: Double] = [:]
        for (k, m) in (log?.marks ?? []).enumerated() where m.kind == .game {
            markStarts[k] = m.startSec
            if let i = m.index, games.indices.contains(i) { markLinks[k] = games[i].id }
        }
        let duration = max(log?.timelineSec ?? 0, parts.last?.endSec ?? 0)
        let d = RacketMatchDraft(games: games, base: min(log?.baseIndex ?? 0, games.count), parts: parts, links: links,
                                 markLinks: markLinks, markStarts: markStarts, hasRecording: log != nil, duration: duration,
                                 startedAt: log?.startedAt, rallies: log?.allRallies ?? [],
                                 details: RacketMatchParams(from: ex))
        return normalized(d)
    }

    // MARK: 1. Score

    static func setScore(_ d: RacketMatchDraft, game id: UUID, _ score: RacketUnitScore) -> RacketMatchDraft {
        guard let i = d.index(of: id) else { return d }
        var out = d
        var log = SetLog()
        log.scoreFor = max(0, score.scoreFor)
        log.scoreAgainst = max(0, score.scoreAgainst)
        log.tiebreakFor = score.tiebreakFor.map { max(0, $0) }
        log.tiebreakAgainst = score.tiebreakAgainst.map { max(0, $0) }
        log.superTiebreak = score.superTiebreak ? true : nil
        RacketScoreEdit.apply(log, to: &out.games[i].set)
        return out
    }

    /// Why "Confirm score" is off for this game (nil when it can confirm).
    static func confirmBlock(_ d: RacketMatchDraft, game id: UUID) -> String? {
        guard let i = d.index(of: id) else { return "" }
        let s = d.games[i].set
        if s.scoreFromWatch == true, s.racketScore != nil { return nil }
        if s.suggestedScore != nil { return nil }
        if s.racketScore != nil { return "This score is already confirmed." }
        return "No score to confirm yet. Enter it above."
    }

    /// A Watch tally or a suggested score becomes the confirmed score.
    static func confirm(_ d: RacketMatchDraft, game id: UUID) -> RacketMatchDraft {
        guard let i = d.index(of: id), confirmBlock(d, game: id) == nil else { return d }
        let s = d.games[i].set
        if let score = s.racketScore ?? s.suggestedScore { return setScore(d, game: id, score) }
        return d
    }

    /// "Score unknown": back to "Score unconfirmed".
    static func markUnknown(_ d: RacketMatchDraft, game id: UUID) -> RacketMatchDraft {
        guard let i = d.index(of: id) else { return d }
        var out = d
        var s = out.games[i].set
        s.scoreFor = nil; s.scoreAgainst = nil; s.tiebreakFor = nil; s.tiebreakAgainst = nil; s.superTiebreak = nil
        s.scoreFromWatch = nil; s.suggestedFor = nil; s.suggestedAgainst = nil
        s.scoreUnconfirmed = true
        out.games[i].set = s
        return out
    }

    // MARK: 2. Remove a game

    static func removeBlock(_ d: RacketMatchDraft, game id: UUID) -> String? {
        guard d.index(of: id) != nil else { return "" }
        return d.games.count <= 1 ? onlyGameReason : nil
    }

    /// Removing this game needs the "what happens to its video" choice.
    static func removeNeedsChoice(_ d: RacketMatchDraft, game id: UUID) -> Bool { d.hasVideo(id) }

    /// The rallies in this game's video that stop counting toward the match if it is removed (they stay in the
    /// recording at their times): all marked rallies, and how many of them are tagged.
    static func ralliesInVideo(_ d: RacketMatchDraft, game id: UUID) -> (marked: Int, tagged: Int) {
        guard let r = d.videoRange(of: id) else { return (0, 0) }
        let rs = RacketRallyMarking.inRange(d.rallies, r.lo, r.hi, skipping: r.skips).filter(\.isRally)
        return (rs.count, rs.filter(\.isTagged).count)
    }

    /// The sheet's line: "2 tagged rallies stop counting toward this match. They stay in the recording at their times."
    static func ralliesLine(_ d: RacketMatchDraft, game id: UUID) -> String {
        let n = ralliesInVideo(d, game: id)
        guard n.marked > 0 else { return "Its video stays in the recording. Nothing is deleted." }
        let what = n.tagged > 0 ? "\(n.tagged) tagged \(n.tagged == 1 ? "rally" : "rallies")"
                                : "\(n.marked) marked \(n.marked == 1 ? "rally" : "rallies")"
        return "\(what) stop counting toward this match. They stay in the recording at their times, and its video is never deleted."
    }

    /// Remove a game. A game with video needs `video` (the sheet's choice); without it nothing changes.
    static func remove(_ d: RacketMatchDraft, game id: UUID, video: RacketRemovedVideo? = nil) -> RacketMatchDraft {
        guard let i = d.index(of: id), removeBlock(d, game: id) == nil else { return d }
        if d.hasVideo(id), video == nil { return d }
        var out = d
        if let video { out = releaseVideo(out, game: id, as: video == .extra ? .unsure : .notPlay) }
        out.games.remove(at: i)
        if i < out.base { out.base -= 1 }
        return normalized(out)
    }

    /// The game's video stops being a game: its halves become `kind` (timeouts become breaks, or not play with it),
    /// its links go. Times never change.
    private static func releaseVideo(_ d: RacketMatchDraft, game id: UUID, as kind: RacketPartKind) -> RacketMatchDraft {
        var out = d
        while let pid = out.videoPart(of: id), let i = out.parts.firstIndex(where: { $0.id == pid }) {
            out.links[pid] = nil
            guard let g = RacketGameGroups.group(of: i, in: out.parts) else { continue }
            for h in g.halves { out.parts[h].kind = kind; out.parts[h].belongs = nil }
            for t in g.timeouts { out.parts[t].kind = kind == .notPlay ? .notPlay : .breakTime }
        }
        for (k, v) in out.markLinks where v == id { out.markLinks[k] = nil }
        out.parts = RacketSplitEditor.repairGroups(out.parts)
        return out
    }

    // MARK: 3. Add a game

    /// A new game at `position` (0 = first), no video. With no score it is "Score unconfirmed". It is logged between
    /// its neighbours' times (so heart rate and clips never take a neighbour's window).
    static func add(_ d: RacketMatchDraft, at position: Int, score: RacketUnitScore? = nil, fallback: Date) -> RacketMatchDraft {
        let p = min(max(0, position), d.games.count)
        var out = d
        var s = SetLog()
        let prev = p > 0 ? d.games[p - 1].set.completedAt : nil
        let next = p < d.games.count ? d.games[p].set.completedAt : nil
        switch (prev, next) {
        case let (a?, b?): s.completedAt = a.addingTimeInterval(min(1, max(0, b.timeIntervalSince(a)) / 2))
        case let (a?, nil): s.completedAt = a.addingTimeInterval(1)
        case let (nil, b?): s.completedAt = b.addingTimeInterval(-1)
        default: s.completedAt = fallback
        }
        s.scoreUnconfirmed = true
        out.games.insert(.init(set: s, source: nil), at: p)
        // It sides with the game before it: at or before the boundary it is a game logged before the recording.
        if p <= out.base { out.base += 1 }
        if let score { out = setScore(out, game: out.games[p].id, score) }
        return normalized(out)
    }

    // MARK: 4. Move a game

    static func moveBlock(_ d: RacketMatchDraft, game id: UUID, by delta: Int) -> String? {
        guard let i = d.index(of: id) else { return "" }
        let j = i + (delta < 0 ? -1 : 1)
        if j < 0 { return firstReason }
        if j >= d.games.count { return lastReason }
        if d.hasVideo(id) && d.hasVideo(d.games[j].id) { return videoOrderReason }
        return nil
    }

    /// One place earlier (`delta < 0`) or later. The boundary `base` stays where it is (a game moving across it
    /// changes side), except that a game with video is always on the recording's side.
    static func move(_ d: RacketMatchDraft, game id: UUID, by delta: Int) -> RacketMatchDraft {
        guard let i = d.index(of: id), moveBlock(d, game: id, by: delta) == nil else { return d }
        var out = d
        out.games.swapAt(i, i + (delta < 0 ? -1 : 1))
        return normalized(out)
    }

    // MARK: 5. Link / unlink video

    /// The parts a game could be linked to: an unlinked game group's first half, or a "Rallies, no score" stretch.
    static func linkCandidates(_ d: RacketMatchDraft) -> [UUID] {
        var out: [UUID] = []
        for (i, p) in d.parts.enumerated() {
            if p.kind == .unsure { out.append(p.id); continue }
            if p.kind == .game, !RacketGameGroups.isContinuation(i, in: d.parts), d.links[p.id] == nil { out.append(p.id) }
        }
        return out
    }

    static func linkBlock(_ d: RacketMatchDraft, game id: UUID, part pid: UUID) -> String? {
        guard let gi = d.index(of: id), let pi = d.parts.firstIndex(where: { $0.id == pid }) else { return "" }
        if d.hasVideo(id) { return hasVideoLinkReason }
        if d.links[pid] != nil { return partTakenReason }
        guard linkCandidates(d).contains(pid) else { return partTakenReason }
        // Every other game with video keeps its side: earlier games' video before this part, later games' after.
        let start = d.parts[pi].startSec
        for (k, g) in d.games.enumerated() where k != gi {
            guard let lo = d.videoStart(of: g.id) else { continue }
            if k < gi && lo > start { return linkOrderReason }
            if k > gi && lo < start { return linkOrderReason }
        }
        return nil
    }

    /// Link a game with no video to a part. The part becomes a game; the game is logged at the end of its video and
    /// takes the video's played time.
    static func link(_ d: RacketMatchDraft, game id: UUID, part pid: UUID) -> RacketMatchDraft {
        guard let gi = d.index(of: id), let pi = d.parts.firstIndex(where: { $0.id == pid }),
              linkBlock(d, game: id, part: pid) == nil else { return d }
        var out = d
        out.parts[pi].kind = .game
        if out.parts[pi].belongs == .practice { out.parts[pi].belongs = nil }
        out.links[pid] = id
        out.parts = RacketSplitEditor.repairGroups(out.parts)
        if let r = out.videoRange(of: id) {
            out.games[gi].set.durationSec = r.played
            if let t0 = out.startedAt { out.games[gi].set.completedAt = t0.addingTimeInterval(r.hi) }
        }
        return normalized(out)
    }

    static func unlinkBlock(_ d: RacketMatchDraft, game id: UUID) -> String? {
        d.videoPart(of: id) == nil && !d.markLinks.values.contains(id) ? noVideoReason : nil
    }

    /// Unlink: the game stays (no video); its video becomes "Rallies, no score" — not counted, and it can be linked
    /// again. (Not a new "Score unconfirmed" game: unlinking never adds a game the player didn't ask for.)
    static func unlink(_ d: RacketMatchDraft, game id: UUID) -> RacketMatchDraft {
        guard unlinkBlock(d, game: id) == nil else { return d }
        return normalized(releaseVideo(d, game: id, as: .unsure))
    }

    // MARK: 6. Match details

    /// A quiet note when the games no longer fit the format (best of): nothing is ever removed for it.
    static func fitNote(_ d: RacketMatchDraft) -> String? {
        guard let n = d.details.bestOf, n > 0 else { return nil }
        let noun = d.details.sport.unit.noun
        let count = d.games.count
        if count > n {
            return "\(count) \(noun)s logged, more than best of \(n) allows. Nothing is removed."
        }
        let need = n / 2 + 1
        var won = 0, lost = 0
        for (k, g) in d.games.enumerated() {
            if let w = g.set.racketScore?.won { if w { won += 1 } else { lost += 1 } }
            if (won >= need || lost >= need), k < count - 1 {
                return "Best of \(n) is decided after \(noun) \(k + 1). The \(noun)s after it still show."
            }
        }
        return nil
    }

    // MARK: 7. Move a game to another match

    static func moveToMatchBlock(_ d: RacketMatchDraft, game id: UUID, otherMatches: Int) -> String? {
        guard d.index(of: id) != nil else { return "" }
        if d.hasVideo(id) { return moveVideoReason }
        if d.games.count <= 1 { return onlyGameReason }
        if otherMatches == 0 { return noOtherMatchReason }
        return nil
    }

    static func moveToMatch(_ d: RacketMatchDraft, game id: UUID, to target: UUID, otherMatches: Int) -> RacketMatchDraft {
        guard let i = d.index(of: id), moveToMatchBlock(d, game: id, otherMatches: otherMatches) == nil else { return d }
        var out = d
        out.outgoing.append(.init(game: out.games.remove(at: i), to: target))
        if i < out.base { out.base -= 1 }
        return normalized(out)
    }

    /// Where a game arriving from another match goes: after the last game logged at or before it.
    static func arrivalPosition(_ d: RacketMatchDraft, _ s: SetLog) -> Int {
        guard let at = s.completedAt else { return d.games.count }
        return (d.games.lastIndex { ($0.set.completedAt ?? .distantPast) <= at }).map { $0 + 1 } ?? 0
    }

    /// Take a game in from another match (it has no video). Games before the recording stay before it.
    static func receive(_ d: RacketMatchDraft, _ s: SetLog) -> RacketMatchDraft {
        var out = d
        let p = arrivalPosition(d, s)
        out.games.insert(.init(set: s, source: nil), at: p)
        if p <= out.base { out.base += 1 }
        return normalized(out)
    }

    // MARK: Validate + repair

    enum Issue: Equatable, Sendable {
        case danglingLink
        case linkedTwice
        case misplacedLink
        case unlinkedGame
        case split([RacketSplitEditor.Issue])
        case videoOrder
        case baseOutOfRange
        case videoBeforeBase
        case durationLongerThanVideo(game: Int)
        case outgoingWithVideo
        case negativeScore(game: Int)
    }

    /// The split's own rules this editor keeps (timeouts, links, belongs). Its time rules (tiling, lengths) are the
    /// split editor's: the match editor never moves a part's edges, and a game-by-game split has gaps on purpose.
    static func linkIssues(_ parts: [RacketVideoPart], duration: Double) -> [RacketSplitEditor.Issue] {
        RacketSplitEditor.validate(parts, duration: duration).filter { issue in
            switch issue {
            case .outOfRange, .overlap, .gap, .tooShort, .empty: return false
            default: return true
            }
        }
    }

    /// The parts with links written as `setIndex` (game positions), for `RacketSplitEditor`.
    static func encoded(_ d: RacketMatchDraft) -> [RacketVideoPart] {
        d.parts.map { p in
            var q = p
            q.setIndex = d.links[p.id].flatMap { d.index(of: $0) }
            q.joinedSetIndexes = nil
            return q
        }
    }

    static func validate(_ d: RacketMatchDraft) -> [Issue] {
        var issues: [Issue] = []
        let ids = Set(d.games.map(\.id))
        let partIDs = Set(d.parts.map(\.id))
        if d.links.contains(where: { !ids.contains($0.value) || !partIDs.contains($0.key) })
            || d.markLinks.values.contains(where: { !ids.contains($0) }) { issues.append(.danglingLink) }
        let linked = Array(d.links.values)
        if linked.count != Set(linked).count { issues.append(.linkedTwice) }
        let groups = RacketGameGroups.groups(d.parts)
        let firsts = Set(groups.map { d.parts[$0.first].id })
        if d.links.keys.contains(where: { !firsts.contains($0) }) { issues.append(.misplacedLink) }
        if groups.contains(where: { d.links[d.parts[$0.first].id] == nil }) { issues.append(.unlinkedGame) }
        if !d.parts.isEmpty {
            let s = linkIssues(encoded(d), duration: d.duration)
            if !s.isEmpty { issues.append(.split(s)) }
        }
        let starts = d.games.compactMap { d.videoStart(of: $0.id) }
        if starts != starts.sorted() { issues.append(.videoOrder) }
        if d.base < 0 || d.base > d.games.count { issues.append(.baseOutOfRange) }
        if let first = d.games.indices.first(where: { d.hasVideo(d.games[$0].id) }), first < d.base {
            issues.append(.videoBeforeBase)
        }
        for (k, g) in d.games.enumerated() {
            if let r = d.videoRange(of: g.id), RacketGameDuration.fitted(g.set.durationSec, span: r.hi - r.lo, played: r.played) != g.set.durationSec {
                issues.append(.durationLongerThanVideo(game: k))
            }
            let s = g.set
            if [s.scoreFor, s.scoreAgainst, s.tiebreakFor, s.tiebreakAgainst].contains(where: { ($0 ?? 0) < 0 }) {
                issues.append(.negativeScore(game: k))
            }
        }
        if d.outgoing.contains(where: { d.hasVideo($0.game.id) }) { issues.append(.outgoingWithVideo) }
        return issues
    }

    /// Repair every invariant without losing a game, a score or any video: dangling / doubled / misplaced links go
    /// (the game stays, with no video); an unlinked game group becomes "Rallies, no score"; the split's own rules are
    /// repaired; games with video are put back in video order (games without video keep their places); `base` is
    /// clamped; a game longer than its video takes the video's played time; negative scores become 0.
    static func normalized(_ input: RacketMatchDraft) -> RacketMatchDraft {
        var d = input
        // A game with video never leaves for another match: it comes back (checked before any link is dropped).
        let back = d.outgoing.filter { d.hasVideo($0.game.id) }
        if !back.isEmpty {
            let snapshot = d
            d.outgoing.removeAll { snapshot.hasVideo($0.game.id) }
            d.games.append(contentsOf: back.map(\.game))
        }
        let ids = Set(d.games.map(\.id))
        // Links.
        d.markLinks = d.markLinks.filter { ids.contains($0.value) }
        if !d.parts.isEmpty {
            var enc = encoded(d)
            // The editor never moves a part's edges (a game-by-game split has gaps between games on purpose).
            if !linkIssues(enc, duration: d.duration).isEmpty { enc = RacketSplitEditor.repairGroups(enc) }
            var links: [UUID: UUID] = [:]
            for p in enc { if let l = p.setIndex, d.games.indices.contains(l) { links[p.id] = d.games[l].id } }
            d.parts = enc.map { var q = $0; q.setIndex = nil; q.joinedSetIndexes = nil; return q }
            // One link per game (the earliest video keeps it), only on first halves.
            let groups = RacketGameGroups.groups(d.parts)
            var seen = Set<UUID>()
            var kept: [UUID: UUID] = [:]
            for g in groups {
                let pid = d.parts[g.first].id
                if let gid = links[pid], seen.insert(gid).inserted { kept[pid] = gid }
            }
            d.links = kept
            // A game group nobody is linked to stops counting (its video stays).
            for g in groups where d.links[d.parts[g.first].id] == nil {
                for h in g.halves { d.parts[h].kind = .unsure; d.parts[h].belongs = nil }
                for t in g.timeouts { d.parts[t].kind = .breakTime }
            }
            d.parts = RacketSplitEditor.repairGroups(d.parts)
        } else {
            d.links = [:]
        }
        // Video order: the games with video, sorted by their video, back into the same slots.
        let slots = d.games.indices.filter { d.hasVideo(d.games[$0].id) }
        let sorted = slots.map { d.games[$0] }.enumerated().sorted { a, b in
            let x = d.videoStart(of: a.element.id) ?? .infinity, y = d.videoStart(of: b.element.id) ?? .infinity
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
        for (slot, g) in zip(slots, sorted) { d.games[slot] = g }
        // Base.
        d.base = min(max(0, d.base), d.games.count)
        if let first = slots.first { d.base = min(d.base, first) }
        // Lengths and scores.
        for k in d.games.indices {
            if let r = d.videoRange(of: d.games[k].id) {
                d.games[k].set.durationSec = RacketGameDuration.fitted(d.games[k].set.durationSec, span: r.hi - r.lo, played: r.played)
            }
            if let v = d.games[k].set.scoreFor, v < 0 { d.games[k].set.scoreFor = 0 }
            if let v = d.games[k].set.scoreAgainst, v < 0 { d.games[k].set.scoreAgainst = 0 }
            if let v = d.games[k].set.tiebreakFor, v < 0 { d.games[k].set.tiebreakFor = 0 }
            if let v = d.games[k].set.tiebreakAgainst, v < 0 { d.games[k].set.tiebreakAgainst = 0 }
        }
        return d
    }

    // MARK: Commit

    struct Commit: Equatable {
        var sets: [SetLog]
        var log: RacketRecordingLog?
        /// Old game index → new index; a removed or moved-out game is absent.
        var remap: [Int: Int]
        /// Old index of each game that moved out, and where to.
        var movedOut: [(source: Int, to: UUID, set: SetLog)]

        static func == (a: Commit, b: Commit) -> Bool {
            a.sets == b.sets && a.log == b.log && a.remap == b.remap
                && a.movedOut.map(\.source) == b.movedOut.map(\.source) && a.movedOut.map(\.to) == b.movedOut.map(\.to)
        }
    }

    /// The edited games, and the recording with every index written again from the game ids. Only `split.parts`'
    /// kinds and links, the game marks' indexes and `baseSetIndex` change; times, rallies, assets, derived videos,
    /// AI records and scans are never touched.
    static func commit(_ input: RacketMatchDraft, log original: RacketRecordingLog?) -> Commit {
        let d = normalized(input)
        let position = Dictionary(uniqueKeysWithValues: d.games.enumerated().map { ($1.id, $0) })
        var log = original
        if var l = log {
            if var split = l.split, split.appliedAt != nil {
                split.parts = d.parts.map { p in
                    var q = p
                    q.setIndex = d.links[p.id].flatMap { position[$0] }
                    q.joinedSetIndexes = nil
                    return q
                }
                l.split = split
            }
            for k in l.marks.indices where l.marks[k].kind == .game {
                l.marks[k].index = d.markLinks[k].flatMap { position[$0] }
            }
            if l.baseSetIndex != nil || d.base != 0 { l.baseSetIndex = d.base }
            log = l
        }
        var remap: [Int: Int] = [:]
        for (k, g) in d.games.enumerated() { if let s = g.source { remap[s] = k } }
        let moved = d.outgoing.compactMap { o in o.game.source.map { (source: $0, to: o.to, set: o.game.set) } }
        return Commit(sets: d.games.map(\.set), log: log, remap: remap, movedOut: moved)
    }
}

// MARK: - A game's length vs its video (the stop-sheet game)

/// The rule every place that links a logged game to its video uses (`RacketSplitAssign.apply`, the match editor):
/// a game keeps its own length when it fits inside its video's span (plus `RacketSplitAssign.toleranceSec`) — a Watch
/// game timed on the wrist, from its first point to its last, is often shorter than the video, and that real length
/// is kept. A length the video can't hold (the game logged from the stop sheet carries the whole recording) is
/// replaced by the video's played time (timeouts left out). A game with no length keeps none.
enum RacketGameDuration {
    static func fitted(_ duration: Double?, span: Double, played: Double) -> Double? {
        guard let duration else { return nil }
        return duration > span + RacketSplitAssign.toleranceSec ? played : duration
    }
}

// MARK: - Saving the edit across the session

/// Save: the edited match, any match that received a game, and how every photo / clip attached to a game by index
/// moves with it. Pure: the sheet writes the result to SwiftData.
enum RacketMatchSave {
    struct MediaMove: Equatable, Sendable {
        var exerciseID: UUID
        var setIndex: Int?
    }

    struct Outcome {
        var exercises: [SessionExercise]
        /// Where a photo / clip attached to (exercise, game index) goes. Media of an untouched match is not listed.
        /// A removed game's media stays on its match with no game (never deleted).
        var media: [UUID: (Int) -> MediaMove]
    }

    /// Apply `draft` (of the match `id`) to the session's exercises.
    static func apply(_ draft: RacketMatchDraft, to exercises: [SessionExercise], match id: UUID) -> Outcome? {
        guard let mi = exercises.firstIndex(where: { $0.id == id }) else { return nil }
        let d = RacketMatchEditor.normalized(draft)
        guard RacketMatchEditor.validate(d).isEmpty else { return nil }
        var out = exercises
        let c = RacketMatchEditor.commit(d, log: out[mi].racketRecordingLog)
        out[mi].sets = c.sets
        out[mi].racketRecordingLog = c.log
        d.details.apply(to: &out[mi])
        _ = RacketStats.applyMatchIdentity(&out[mi])
        var media: [UUID: (Int) -> MediaMove] = [:]
        // Games arriving in other matches, one target at a time (each target is itself an edit: its later games move).
        var arrived: [Int: MediaMove] = [:]
        for target in Set(c.movedOut.map(\.to)) {
            guard let ti = out.firstIndex(where: { $0.id == target }), out[ti].isRacketMatch else { continue }
            var td = RacketMatchEditor.draft(from: out[ti])
            var incoming: [(source: Int, gameID: UUID)] = []
            for m in c.movedOut where m.to == target {
                let before = Set(td.games.map(\.id))
                td = RacketMatchEditor.receive(td, m.set)
                if let g = td.games.first(where: { !before.contains($0.id) }) { incoming.append((m.source, g.id)) }
            }
            td = RacketMatchEditor.normalized(td)
            let tc = RacketMatchEditor.commit(td, log: out[ti].racketRecordingLog)
            out[ti].sets = tc.sets
            out[ti].racketRecordingLog = tc.log
            let tRemap = tc.remap
            media[target] = { old in MediaMove(exerciseID: target, setIndex: tRemap[old]) }
            for (src, gid) in incoming { arrived[src] = MediaMove(exerciseID: target, setIndex: td.games.firstIndex { $0.id == gid }) }
        }
        let remap = c.remap
        media[id] = { old in arrived[old] ?? MediaMove(exerciseID: id, setIndex: remap[old]) }
        return Outcome(exercises: out, media: media)
    }
}
