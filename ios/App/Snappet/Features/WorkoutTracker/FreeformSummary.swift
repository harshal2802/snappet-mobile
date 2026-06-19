import Foundation

/// Pure, device-free derivations for the **freeform** session player's faster-entry and completion
/// surfaces (issue #158, workstreams B & D): the value-labelled "Repeat" label, the post-workout
/// summary stats (with a dominant-kind headline — Volume / Sends / Hold-time), and the milestone
/// decision behind the completion celebration. No SwiftUI, no SwiftData, no device — it composes the
/// already-pure `SetMeasure`, `WorkoutMath`, and `KilterMilestones`, so the freeform views stay thin
/// and every derivation is unit-tested in `SnappetTests` with no simulator (the repo's
/// pure-logic-at-a-thin-edge rule; shipped "no callers yet" first like `StopwatchTiming`).
enum FreeformSummary {

    // MARK: - Repeat label (workstream B)

    /// The value-labelled one-tap "Repeat" action label, e.g. "Repeat 8 × 60 kg" / "Repeat 0:45" /
    /// "Repeat V4 · Sent". Composes the one set-summary funnel (`SetMeasure.summary`) so the label
    /// reads exactly like the set it duplicates. (The action itself is unchanged — `SetMeasure.duplicate`.)
    static func repeatLabel(for set: SetLog, kind: SetKind, unit: WeightUnit) -> String {
        "Repeat \(SetMeasure.summary(set, kind: kind, unit: unit))"
    }

    // MARK: - Completion stats (workstream D)

    /// Which discipline a session is "about" — drives the headline stat on the completion screen.
    /// (`lifting`/`climbing`/`timed` keep their names for back-compat with the done-screen; `running`/
    /// `dance`/`other` are the Workout-Type Parity additions.)
    enum Dominant: String, Equatable, Sendable {
        case lifting, climbing, timed, running, dance, other, none
    }

    /// One value+label cell for the completion summary (mirrors the guided done-screen `stat(_:_:)`).
    struct Stat: Equatable, Sendable {
        var value: String
        var label: String
    }

    /// The three completion-summary cells: Duration · Sets · a dominant-kind headline
    /// (Volume for a lifting session, Sends for climbing, Hold-time for timed).
    struct Stats: Equatable, Sendable {
        var duration: Stat
        var sets: Stat
        var headline: Stat
        var dominant: Dominant
    }

    /// The session's dominant discipline = the `WorkoutDiscipline` with the most **completed** efforts.
    /// Ties resolve in a fixed, deterministic order (lifting → climbing → running → timed → dance →
    /// other). `.none` when nothing is logged. Counting by `discipline` (not `kind`) is regression-safe:
    /// a legacy `.repsWeight`/`.climbAttempt`/`.duration` entity derives to strength/climb/timed and maps
    /// back to the same `.lifting`/`.climbing`/`.timed` result as before.
    static func dominant(for session: WorkoutSession) -> Dominant {
        var counts: [WorkoutDiscipline: Int] = [:]
        for ex in session.exercises {
            for set in ex.sets where set.completedAt != nil {
                counts[ex.discipline, default: 0] += 1
            }
        }
        let order: [(WorkoutDiscipline, Dominant)] = [
            (.strength, .lifting), (.climb, .climbing), (.run, .running),
            (.timed, .timed), (.dance, .dance), (.other, .other),
        ]
        // First discipline in `order` with a strictly-greater count wins → deterministic ties in the
        // documented order; `.none` when nothing is logged (best.count stays 0).
        var best: (dom: Dominant, count: Int) = (.none, 0)
        for (disc, dom) in order {
            let c = counts[disc] ?? 0
            if c > best.count { best = (dom, c) }
        }
        return best.dom
    }

    /// Completion-summary stats for any session, with the third stat adapting to the dominant kind:
    /// **Volume** (Σ weight×reps, lifting), **Sends** (flash/sent climbs), or **Hold-time** (Σ duration).
    /// Reuses `WorkoutMath.sessionVolumeKg`/`formatVolume`, `SetMeasure.isSend`, and
    /// `SetMeasure.formatDuration` so there's one definition of each figure.
    static func stats(for session: WorkoutSession, unit: WeightUnit) -> Stats {
        let dom = dominant(for: session)
        let durationText = "\(max(1, Int(session.duration / 60)))m"

        let headline: Stat
        switch dom {
        case .lifting:
            let kg = WorkoutMath.sessionVolumeKg(session)
            headline = Stat(value: WorkoutMath.formatVolume(kg: kg, unit: unit), label: "Volume")
        case .climbing:
            headline = Stat(value: "\(sendCount(session))", label: "Sends")
        case .timed:
            headline = Stat(value: SetMeasure.formatDuration(holdTimeSeconds(session)), label: "Hold time")
        case .running:
            // Distance defaults to km here; a later phase threads the user's sticky `DistanceUnit`.
            headline = Stat(value: SetMeasure.formatDistance(totalDistanceMeters(session), unit: .km),
                            label: "Distance")
        case .dance:
            headline = Stat(value: SetMeasure.formatDuration(activeSeconds(session, discipline: .dance)),
                            label: "Active")
        case .other:
            headline = Stat(value: SetMeasure.formatDuration(activeSeconds(session, discipline: .other)),
                            label: "Active")
        case .none:
            headline = Stat(value: "—", label: "—")
        }

        return Stats(
            duration: Stat(value: durationText, label: "Duration"),
            sets: Stat(value: "\(session.completedSetCount)", label: "Sets"),
            headline: headline,
            dominant: dom)
    }

    /// Completed climb sends (flash/sent) across the session — the climbing headline figure.
    static func sendCount(_ session: WorkoutSession) -> Int {
        var n = 0
        for ex in session.exercises where ex.kind == .climbAttempt {
            for set in ex.sets where set.completedAt != nil && SetMeasure.isSend(set) { n += 1 }
        }
        return n
    }

    /// Total hold-time (Σ `durationSec`) across completed timed sets — the timed headline figure.
    static func holdTimeSeconds(_ session: WorkoutSession) -> Double {
        var total = 0.0
        for ex in session.exercises where ex.kind == .duration {
            for set in ex.sets where set.completedAt != nil { total += set.durationSec ?? 0 }
        }
        return total
    }

    /// Total distance (Σ `distanceMeters`) across completed running efforts — the running headline figure.
    static func totalDistanceMeters(_ session: WorkoutSession) -> Double {
        var total = 0.0
        for ex in session.exercises where ex.discipline == .run {
            for set in ex.sets where set.completedAt != nil { total += set.distanceMeters ?? 0 }
        }
        return total
    }

    /// Total active time (Σ `durationSec`) across completed efforts, optionally scoped to one discipline.
    /// The dance/other headline scopes to its own discipline so a mixed session (e.g. dance + a run leg)
    /// doesn't fold another discipline's time into the headline.
    static func activeSeconds(_ session: WorkoutSession, discipline: WorkoutDiscipline? = nil) -> Double {
        var total = 0.0
        for ex in session.exercises where discipline == nil || ex.discipline == discipline {
            for set in ex.sets where set.completedAt != nil { total += set.durationSec ?? 0 }
        }
        return total
    }

    // MARK: - Milestone (workstream D)

    /// A celebration-worthy achievement reached **this session**, derived against prior history.
    enum Milestone: Equatable, Sendable {
        /// A weighted personal record for an exercise (best `weight × reps` beats all prior history).
        case personalRecord(exerciseId: String, bestKg: Double, reps: Int)
        /// The first-ever send of a climbing grade (no prior send at that grade in history).
        case firstSend(grade: String)
    }

    /// The milestones a session achieved, composing `WorkoutMath.topSet` (PR) and
    /// `KilterMilestones.isFirstSend` (first send of a grade). `history` MUST be the user's prior
    /// **completed** sessions, NOT including the live session being summarised (the live session has
    /// `completedAt == nil`, so it's naturally excluded). Returns every milestone reached (possibly
    /// several); empty ⇒ no celebration. Only **weighted** PRs are celebrated — a bodyweight "best"
    /// (`bestKg == 0`) is a quieter moment and is intentionally skipped.
    static func milestones(for session: WorkoutSession, history: [WorkoutSession]) -> [Milestone] {
        var out: [Milestone] = []

        // Personal records — one per exercise id, weighted only. Uses topWeightedSet (not topSet) on
        // BOTH sides so a high-rep bodyweight set can't mask the session's weighted PR, nor zero-out the
        // prior weighted baseline (topSet ranks bodyweight as 1×reps but reports bestKg == 0).
        var seen = Set<String>()
        for ex in session.exercises where ex.kind == .repsWeight {
            let id = ex.exerciseId
            guard seen.insert(id).inserted else { continue }
            guard let best = WorkoutMath.topWeightedSet(history: [session], exerciseId: id) else { continue }
            let prior = WorkoutMath.topWeightedSet(history: history, exerciseId: id)
            let thisScore = best.bestKg * Double(best.bestReps)
            let priorScore = prior.map { $0.bestKg * Double($0.bestReps) } ?? 0
            if thisScore > priorScore {
                out.append(.personalRecord(exerciseId: id, bestKg: best.bestKg, reps: best.bestReps))
            }
        }

        // First send of a grade — one per grade.
        var firstSendGrades = Set<String>()
        for ex in session.exercises where ex.kind == .climbAttempt {
            for set in ex.sets where set.completedAt != nil {
                guard SetMeasure.isSend(set),
                      let grade = set.climbGradeLabel, !grade.isEmpty,
                      !firstSendGrades.contains(grade),
                      let status = set.climbStatusRaw.flatMap(KilterAscentStatus.init(rawValue:)) else { continue }
                let prior = priorSendCount(history: history, grade: grade)
                if KilterMilestones.isFirstSend(status: status, priorSendCountAtGrade: prior) {
                    firstSendGrades.insert(grade)
                    out.append(.firstSend(grade: grade))
                }
            }
        }

        return out
    }

    /// A short celebratory headline for a milestone, e.g. "New PR!" / "First V4 send!".
    static func milestoneHeadline(_ milestone: Milestone) -> String {
        switch milestone {
        case .personalRecord:          return "New PR!"
        case .firstSend(let grade):    return "First \(grade) send!"
        }
    }

    /// Completed sends at a grade across prior history — the `priorSendCountAtGrade` for the
    /// first-send decision.
    private static func priorSendCount(history: [WorkoutSession], grade: String) -> Int {
        var n = 0
        for session in history {
            for ex in session.exercises where ex.kind == .climbAttempt {
                for set in ex.sets where set.completedAt != nil && set.climbGradeLabel == grade && SetMeasure.isSend(set) {
                    n += 1
                }
            }
        }
        return n
    }
}
