import Foundation

/// The **timeline** of a structured timed exercise — the ordered phases (lead-in → work / rest /
/// between-set rest → done) a `TimedExerciseSpec` unrolls into, plus a pure wall-clock read that maps an
/// elapsed time to "which phase are we in, how much is left, which set/rep". This is the brain behind the
/// Phase-6 `StructuredTimedRunner`, so all the boundary math is unit-tested without a view or a device
/// (the repo's pure-logic-at-a-thin-edge rule, the same shape as `StopwatchTiming`).
///
/// **Plain value type** — no SwiftUI, no SwiftData, no device. **Lives in `Shared/`** (compiled into the
/// phone app, the watchOS companion, and the widget extension — see `project.yml`) so the same unrolled
/// schedule is available wherever a structured timed set runs.
///
/// Only the **structured** modes (`.repeaters` / `.tabata` / `.emom`) produce a meaningful schedule; the
/// simple modes (`.openCountUp` / `.maxHang` / `.countDown`) stay on Phase 5's `StopwatchView` path. For a
/// simple mode this still builds a single work phase so the type is total, but the runner is only wired in
/// for structured specs.
///
/// **EMOM** is modelled as `reps` work phases of 60 s each (one effort at the top of every minute), with
/// no inter-rep rest — the rest *is* the rest of the minute. Repeaters / tabata alternate
/// `workSec` work with `restSec` rest, `reps` times per set, with `restBetweenSetsSec` between sets and no
/// trailing rest after the last rep of the last set. (Quick Session redesign Phase 6, prompt 06.)
struct IntervalSchedule: Equatable, Sendable {

    /// One contiguous stretch of the timeline with a single kind, duration, and label.
    struct Phase: Equatable, Sendable, Identifiable {
        enum Kind: String, Equatable, Sendable {
            /// The 3-2-1 get-ready count before the first rep.
            case leadIn
            /// A work interval (hang / effort) — ember.
            case work
            /// Rest between reps within a set — muted.
            case rest
            /// The longer rest between sets — muted.
            case restBetweenSets
            /// The terminal marker (zero duration) the timeline ends on.
            case done
        }

        /// Stable identity within a schedule (its index in the ordered phase list).
        let id: Int
        let kind: Kind
        /// Length of this phase in seconds (0 for `.done`).
        let durationSec: Int
        /// 1-based set this phase belongs to. For `restBetweenSets` it is the set just finished.
        let setIndex: Int
        /// 1-based rep this phase belongs to (work / rest). 0 for lead-in / between-set / done.
        let repIndex: Int
        /// The big phase label the runner shows ("READY" / "WORK" / "REST" / "DONE").
        let label: String
        /// The next phase's label, for the "next ▸ …" preview chip (nil at the end).
        let nextLabel: String?

        var isWork: Bool { kind == .work }
        var isRest: Bool { kind == .rest || kind == .restBetweenSets }
    }

    /// The spec this schedule unrolled from.
    let spec: TimedExerciseSpec
    /// The ordered phases, lead-in first, terminated by a single `.done` marker.
    let phases: [Phase]

    /// A wall-clock snapshot: where elapsed lands on the timeline.
    struct State: Equatable, Sendable {
        /// The active phase (the `.done` marker once finished).
        let phase: Phase
        /// Seconds left in the active phase (0 once done).
        let remainingInPhase: Int
        /// Seconds left across the whole schedule (0 once done).
        let overallRemaining: Int
        /// 1-based set / rep of the active phase (for the "Set i/n · Rep j/m" counter). 0 when not in a
        /// work/rest phase (lead-in / between-set / done) — the runner shows the set, hides the rep then.
        let setIndex: Int
        let repIndex: Int
        /// `true` once elapsed has run past the final phase.
        let isDone: Bool
    }

    /// 1-based set count and per-set rep count, for the counter denominators.
    var totalSets: Int { max(1, spec.sets) }
    var repsPerSet: Int { max(1, spec.reps) }

    /// The prescribed total seconds — the sum of every phase duration. Equals `spec.totalSeconds` for the
    /// structured modes (asserted in tests); for EMOM (work/rest 0 in the preset) it is `reps * 60` per set.
    var totalSeconds: Int { phases.reduce(0) { $0 + $1.durationSec } }

    init(spec: TimedExerciseSpec) {
        self.spec = spec
        self.phases = IntervalSchedule.build(from: spec)
    }

    // MARK: - Build

    private static func build(from spec: TimedExerciseSpec) -> [Phase] {
        var out: [Phase] = []
        let sets = max(1, spec.sets)
        let reps = max(1, spec.reps)
        let isEmom = spec.mode == .emom
        // EMOM: each rep is a full 60 s window of work, no inter-rep rest. Otherwise use the spec's
        // work / rest. A simple (non-structured) spec falls back to a single work phase of its hold.
        let workSec = isEmom ? 60 : max(0, spec.workSec)
        let restSec = isEmom ? 0 : max(0, spec.restSec)

        if spec.leadInSec > 0 {
            out.append(.init(id: out.count, kind: .leadIn, durationSec: spec.leadInSec,
                             setIndex: 0, repIndex: 0, label: "READY", nextLabel: "WORK"))
        }

        for s in 1...sets {
            for r in 1...reps {
                let isLastRepOfSet = (r == reps)
                let isLastSet = (s == sets)
                // Work phase.
                if workSec > 0 {
                    out.append(.init(id: out.count, kind: .work, durationSec: workSec,
                                     setIndex: s, repIndex: r, label: "WORK", nextLabel: nil))
                }
                // Inter-rep rest (not after the last rep of a set).
                if !isLastRepOfSet, restSec > 0 {
                    out.append(.init(id: out.count, kind: .rest, durationSec: restSec,
                                     setIndex: s, repIndex: r, label: "REST", nextLabel: nil))
                }
                // Between-set rest after the last rep of a non-final set.
                if isLastRepOfSet, !isLastSet, spec.restBetweenSetsSec > 0 {
                    out.append(.init(id: out.count, kind: .restBetweenSets, durationSec: spec.restBetweenSetsSec,
                                     setIndex: s, repIndex: 0, label: "REST", nextLabel: nil))
                }
            }
        }

        // Terminal marker.
        out.append(.init(id: out.count, kind: .done, durationSec: 0,
                         setIndex: 0, repIndex: 0, label: "DONE", nextLabel: nil))

        // Second pass: fill each phase's `nextLabel` from the following phase's label (skip the `.done`
        // marker — there's nothing after it). Built post-hoc so the preview chip always telegraphs the
        // very next thing on the clock without the build loop needing look-ahead.
        var withNext: [Phase] = []
        for (i, p) in out.enumerated() {
            let next = (i + 1 < out.count && out[i + 1].kind != .done) ? out[i + 1].label : nil
            withNext.append(.init(id: p.id, kind: p.kind, durationSec: p.durationSec,
                                  setIndex: p.setIndex, repIndex: p.repIndex,
                                  label: p.label, nextLabel: next))
        }
        return withNext
    }

    // MARK: - Pure wall-clock read

    /// Map an elapsed time (seconds since the runner started) to the active phase and the time left. The
    /// running view is a thin read of this — it never sums ticks, so it can't drift and survives
    /// backgrounding (the `StopwatchTiming` pattern).
    func state(at elapsed: TimeInterval) -> State {
        let total = totalSeconds
        let e = max(0, elapsed)
        let done = phases.last ?? Phase(id: 0, kind: .done, durationSec: 0, setIndex: 0,
                                        repIndex: 0, label: "DONE", nextLabel: nil)

        // Past the end → the done marker.
        if e >= Double(total) {
            return State(phase: done, remainingInPhase: 0, overallRemaining: 0,
                         setIndex: 0, repIndex: 0, isDone: true)
        }

        // Walk the phases accumulating their durations until elapsed lands inside one. The `.done` marker
        // has duration 0 so it is only reached via the `e >= total` branch above.
        var startOfPhase = 0.0
        for phase in phases where phase.durationSec > 0 {
            let endOfPhase = startOfPhase + Double(phase.durationSec)
            if e < endOfPhase {
                let remainingInPhase = Int(ceil(endOfPhase - e))
                let overallRemaining = Int(ceil(Double(total) - e))
                let countsRep = (phase.kind == .work || phase.kind == .rest)
                return State(phase: phase,
                             remainingInPhase: max(0, remainingInPhase),
                             overallRemaining: max(0, overallRemaining),
                             setIndex: phase.setIndex,
                             repIndex: countsRep ? phase.repIndex : 0,
                             isDone: false)
            }
            startOfPhase = endOfPhase
        }

        // Fallthrough (only reachable at exactly `total`): done.
        return State(phase: done, remainingInPhase: 0, overallRemaining: 0,
                     setIndex: 0, repIndex: 0, isDone: true)
    }
}
