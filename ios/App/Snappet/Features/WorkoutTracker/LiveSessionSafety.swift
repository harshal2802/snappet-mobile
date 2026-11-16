import Foundation

// MARK: - The live session never loses work silently (prompt 263) — pure
//
// Six rules from the workout state-machine review, each a pure function the live player / the gym tracker's finish
// path call, and each tested in `LiveSessionSafetyTests`. No SwiftUI / UIKit / Photos here.
//
// | Finding | Rule | Function |
// |---|---|---|
// | F5 | Remove match / drill / exercise / climb asks, unless the exercise holds nothing (no sets, media or recording) | `LiveRemoval.prompt` |
// | F2 | Finish discards silently only when nothing is worth keeping; otherwise it asks (Save session / Discard / Cancel) | `LiveFinish.decide` |
// | F2 | The Finish intent / link never deletes something worth keeping: it saves (an intent can't show a dialog) | `LiveFinish.intentSaves` |
// | F4 | The Finish intent / link while a racket cover is open finishes nothing; the cover says why | `LiveFinish.refusal` |
// | F3 | Deleting a racket game in the history drawer goes through `RacketMatchEditor`; a game / block with video stays | `RacketLiveDrawer` |
// | F1 | A second recording on an entry that has one is blocked; a drill continues its own log; a recorded log is never replaced | `RacketRecordingGuard` |
// | F14 | A recording left open by a crash is closed at its last saved part (never a live one) | `RacketRecordingRecovery` |

// MARK: F5 — remove from the live player

/// The confirmation for removing one exercise from the live session.
struct LiveRemovalPrompt: Equatable, Sendable {
    /// "Remove this match?"
    var title: String
    /// "Remove this match" (the destructive button).
    var confirm: String
    /// What goes and what stays.
    var message: String
}

enum LiveRemoval {
    /// "this match" / "this drill" / the exercise's name — the finished session detail's words (`SessionDetailView`).
    static func noun(_ ex: SessionExercise, name: String) -> String {
        ex.isRacketMatch ? "this match" : ex.isRacketDrill ? "this drill" : name
    }

    /// nil ⇒ remove at once: the exercise has no sets, no photos or videos and no recording, so nothing is lost.
    /// `mediaCount`: this session's photos / videos assigned to the exercise.
    static func prompt(for ex: SessionExercise, name: String, mediaCount: Int) -> LiveRemovalPrompt? {
        let recorded = ex.racketRecordingLog != nil
        guard !ex.sets.isEmpty || mediaCount > 0 || recorded else { return nil }
        let n = noun(ex, name: name)
        let efforts = QuickSessionPager.effortNoun(for: ex) + "s"
        let message: String
        if recorded {
            // `removeExercise` drops the entity with its `racketRecordingLog` (split, rallies, tags, marks) and unties
            // its media rows to General; nothing touches the Photos library.
            let what = ex.isRacketDrill ? "block marks, rallies and tags" : "split, rallies and tags"
            message = "Its \(efforts) are deleted from this session, with its recording’s \(what). "
                + "The video stays in your Photos library, and its clips stay in this session, under General."
        } else {
            message = "Its \(efforts) are deleted from this session. Its photos and videos stay, under General."
        }
        return LiveRemovalPrompt(title: "Remove \(n)?", confirm: "Remove \(n)", message: message)
    }
}

// MARK: F2 / F4 — finish

/// A racket cover open over the live player (`RacketLiveCovers`).
enum LiveCoverKind: String, Sendable {
    /// Record everything (a match).
    case recording
    /// A drill's cover, in any recording mode.
    case drill
    /// Game by game / score without video.
    case game
}

/// Why the Finish intent / link finished nothing.
struct FinishRefusal: Equatable, Sendable {
    var title: String
    var message: String
}

enum LiveFinish {
    enum Decision: Equatable, Sendable {
        /// At least one completed set: the completion summary (Done / View detail / Keep going / Discard).
        case summary
        /// Nothing worth keeping: discard without asking.
        case discard
        /// Something worth keeping but no completed set: ask, saying what Discard would delete.
        case ask(lost: String)
    }

    static let askTitle = "Finish this session?"

    /// `mediaCount`: every photo / video row of this session (`SessionMedia.sessionID`), assigned or not.
    static func decide(exercises: [SessionExercise], completedSets: Int, mediaCount: Int) -> Decision {
        if completedSets > 0 { return .summary }
        let sets = exercises.reduce(0) { $0 + $1.sets.count }
        let recordings = exercises.filter { $0.racketRecordingLog != nil }.count
        if sets == 0, recordings == 0, mediaCount == 0 { return .discard }
        return .ask(lost: lostLine(sets: sets, recordings: recordings, media: mediaCount))
    }

    /// "Discard deletes 1 recording with its split, rallies and tags and 2 photos and videos from this session. Videos
    /// stay in your Photos library." (`SessionCascade` deletes the rows, never a Photos asset.)
    static func lostLine(sets: Int, recordings: Int, media: Int) -> String {
        var items: [String] = []
        if sets > 0 { items.append(sets == 1 ? "1 logged set" : "\(sets) logged sets") }
        if recordings > 0 {
            items.append(recordings == 1 ? "1 recording with its split, rallies and tags"
                                         : "\(recordings) recordings with their splits, rallies and tags")
        }
        if media > 0 { items.append(media == 1 ? "1 photo or video" : "\(media) photos and videos") }
        let list: String
        switch items.count {
        case 0: list = "this session"
        case 1: list = items[0]
        default: list = items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
        let tail = recordings > 0 || media > 0 ? " Videos stay in your Photos library." : ""
        return "Discard deletes \(list) from this session.\(tail)"
    }

    /// The Finish intent / link: save unless there is nothing worth keeping (no dialog can be shown from an intent).
    static func intentSaves(_ decision: Decision) -> Bool { decision != .discard }

    /// The Finish intent / link while a racket cover is open: refuse (the cover stays, its recording keeps going).
    static func refusal(openCover: LiveCoverKind?) -> FinishRefusal? {
        guard let openCover else { return nil }
        let title = "Session not finished"
        switch openCover {
        case .recording, .drill:
            return FinishRefusal(title: title,
                                 message: "This screen is still recording. Stop it here first, then finish the session. Nothing was deleted.")
        case .game:
            return FinishRefusal(title: title,
                                 message: "This match is still open. End it here first, then finish the session. Nothing was deleted.")
        }
    }
}

// MARK: F1 — one recording per entry

enum RacketRecordingGuard {
    static let matchReason = "This match already has a recording. A second one isn’t supported yet."
    static let drillReason = "This drill already has a recording. A second one isn’t supported yet."

    /// Something was recorded: a run (capture started) or a saved part.
    static func hasRecorded(_ log: RacketRecordingLog?) -> Bool {
        guard let log else { return false }
        return !log.runs.isEmpty || !log.assets.isEmpty
    }

    static func reason(for ex: SessionExercise) -> String { ex.isRacketDrill ? drillReason : matchReason }

    /// "Record everything" on a match (its page, or the game cover's Everything): nil ⇒ allowed (no log, or a log
    /// where nothing was recorded, which a new recording may replace).
    static func recordEverythingBlock(_ ex: SessionExercise) -> String? {
        hasRecorded(ex.racketRecordingLog) ? reason(for: ex) : nil
    }

    /// Game by game on a match: nil ⇒ allowed (no log, nothing recorded, or its own game-by-game log, which it
    /// continues). A recorded record-everything log can't take game-by-game video: that would start a second log,
    /// which `mayReplace` refuses, and the new game's video would end up tied to nothing.
    static func gameByGameBlock(_ ex: SessionExercise) -> String? {
        guard let log = ex.racketRecordingLog, hasRecorded(log), !log.isGameByGame else { return nil }
        return reason(for: ex)
    }

    enum DrillStart: Equatable, Sendable {
        /// A new log (none yet, nothing recorded in it, or not filming).
        case fresh
        /// Continue the drill's log (same recording mode): new blocks add runs, parts and marks to it.
        case continueLog
        case blocked(String)
    }

    /// Start / Continue drill in `recording` mode.
    static func drillStart(_ ex: SessionExercise, recording: RacketRecordingMode) -> DrillStart {
        guard recording != .off, let old = ex.racketRecordingLog else { return .fresh }
        if logMode(old) == recording { return .continueLog }
        return hasRecorded(old) ? .blocked(drillReason) : .fresh
    }

    /// The mode a log was recorded in (`modeRaw` nil ⇒ everything, the only mode with a log before prompt 249).
    static func logMode(_ log: RacketRecordingLog) -> RacketRecordingMode {
        log.modeRaw.flatMap(RacketRecordingMode.init(rawValue:)) ?? .everything
    }

    /// `saveRacketRecordingLog`: a recorded log is never replaced by a different recording (another `startedAt`).
    static func mayReplace(_ old: RacketRecordingLog?, with new: RacketRecordingLog) -> Bool {
        guard let old else { return true }
        return old.startedAt == new.startedAt || !hasRecorded(old)
    }
}

// MARK: F14 — a recording left open by a crash

enum RacketRecordingRecovery {
    /// Marks that are time ranges (a moment / new game / point is a single time with no end, by design).
    static let rangeKinds: Set<RacketRecordingLog.MarkKind> = [.block, .rest, .game, .interval]

    /// The log with every open run closed at the end of the last part saved during it (nothing after that was saved),
    /// open range marks closed there too, and, for a record-everything log, `endedAt` set. nil ⇒ nothing to change.
    /// A game-by-game / block-by-block log keeps `endedAt` nil: its cover continues it and reads `endedAt` as "now"
    /// for its split. Call only for an entry with no live recording (`RacketLiveCovers`).
    static func recovered(_ log: RacketRecordingLog) -> RacketRecordingLog? {
        var l = log
        var changed = false
        for i in l.runs.indices where l.runs[i].endSec == nil {
            let lo = l.runs[i].startSec
            let hi = i + 1 < l.runs.count ? l.runs[i + 1].startSec : Double.infinity
            let saved = l.assets.filter { $0.startSec >= lo - 0.5 && $0.startSec < hi }
                .map { $0.startSec + ($0.durationSec ?? 0) }.max() ?? lo
            l.runs[i].endSec = min(hi, max(lo, saved))
            changed = true
        }
        let everything = RacketRecordingGuard.logMode(l) == .everything
        let unended = everything && l.endedAt == nil && !l.runs.isEmpty
        guard changed || unended else { return nil }
        let end = l.savedUpToSec
        for k in l.marks.indices where l.marks[k].endSec == nil {
            guard let kind = l.marks[k].kind, rangeKinds.contains(kind) else { continue }
            l.marks[k].endSec = max(l.marks[k].startSec, end)
        }
        if everything, l.endedAt == nil { l.endedAt = l.startedAt.addingTimeInterval(end) }
        return l
    }

    /// Every entry's recording recovered, except those in `live` (a cover is open on them: recording right now).
    /// nil ⇒ nothing changed.
    static func recoverAll(_ exercises: [SessionExercise], live: Set<UUID>) -> [SessionExercise]? {
        var out = exercises
        var changed = false
        for i in out.indices where !live.contains(out[i].id) {
            guard let log = out[i].racketRecordingLog, let fixed = recovered(log) else { continue }
            out[i].racketRecordingLog = fixed
            changed = true
        }
        return changed ? out : nil
    }
}

// MARK: F3 — the history drawer's delete on a racket entity

enum RacketLiveDrawer {
    static let matchVideoReason = "Has video. Remove it from Edit match after the session."
    static let drillVideoReason = "Has video, so it stays with its recording."

    /// Why this game / block can't be swiped away (nil ⇒ it can). Not a racket entity ⇒ nil (the plain delete).
    static func deleteBlock(_ ex: SessionExercise, index i: Int) -> String? {
        guard ex.discipline == .racket, ex.sets.indices.contains(i) else { return nil }
        if ex.isRacketMatch {
            // Edit match's rule: removing a game with video needs a choice about its video, which the drawer can't ask.
            let d = RacketMatchEditor.draft(from: ex)
            guard let g = d.games.first(where: { $0.source == i }) else { return nil }
            return RacketMatchEditor.removeNeedsChoice(d, game: g.id) ? matchVideoReason : nil
        }
        guard let log = ex.racketRecordingLog, i >= log.baseIndex else { return nil }
        let rel = i - log.baseIndex
        return log.marks.contains { ($0.kind == .block || $0.kind == .rest) && $0.index == rel } ? drillVideoReason : nil
    }

    struct Removal: Equatable {
        var sets: [SetLog]
        var log: RacketRecordingLog?
        /// Old game / block index → new index; the removed one is absent (its photos / clips stay on the entity).
        var remap: [Int: Int]
    }

    /// Remove game / block `i` with every stored index kept right. nil ⇒ not a racket entity, or blocked.
    static func remove(_ ex: SessionExercise, at i: Int) -> Removal? {
        guard ex.discipline == .racket, ex.sets.indices.contains(i), deleteBlock(ex, index: i) == nil else { return nil }
        if ex.isRacketMatch {
            let d = RacketMatchEditor.draft(from: ex)
            guard let g = d.games.first(where: { $0.source == i }) else { return nil }
            if d.games.count == 1 {
                // The only game, no video: a live match may go back to no games (Edit match keeps one on a finished
                // session; here the next game is logged on this page). Nothing else can point at it: a split link
                // or a game mark would be video.
                var log = ex.racketRecordingLog
                if var l = log, l.baseSetIndex != nil { l.baseSetIndex = 0; log = l }
                return Removal(sets: [], log: log, remap: [:])
            }
            let out = RacketMatchEditor.remove(d, game: g.id)
            guard out.games.count == d.games.count - 1 else { return nil }
            let c = RacketMatchEditor.commit(out, log: ex.racketRecordingLog)
            return Removal(sets: c.sets, log: c.log, remap: c.remap)
        }
        var sets = ex.sets
        sets.remove(at: i)
        var log = ex.racketRecordingLog
        if var l = log {
            if i < l.baseIndex {
                l.baseSetIndex = l.baseIndex - 1
            } else {
                // Block / rest marks count blocks from the recording's base: later ones move up one.
                let rel = i - l.baseIndex
                for k in l.marks.indices where l.marks[k].kind == .block || l.marks[k].kind == .rest {
                    if let x = l.marks[k].index, x > rel { l.marks[k].index = x - 1 }
                }
            }
            log = l
        }
        var remap: [Int: Int] = [:]
        for old in ex.sets.indices where old != i { remap[old] = old < i ? old : old - 1 }
        return Removal(sets: sets, log: log, remap: remap)
    }
}
