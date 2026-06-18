import Foundation

/// The **structure** of a timed exercise — how its work / rest / reps / sets are arranged on the clock.
///
/// This is a **plain value type** (no SwiftUI, no SwiftData, no device): the timed analogue of a climb's
/// grade, captured once in the pick-or-create sheet and carried by the `.duration` `SessionExercise` and
/// the persisted `TimedExerciseCatalog`. The pure `totalSeconds` / `summary` derivations + the protocol
/// presets are unit-tested in `SnappetTests` (`TimedExerciseSpecTests`) with no simulator.
///
/// **Lives in `Shared/`** (compiled into the phone app, the watchOS companion, and the widget extension
/// — see `project.yml`) so the same spec round-trips wherever a timed set is logged or shown, with one
/// source of truth for the structure math.
///
/// **Presets only PRE-FILL** (`.repeaters7x3x6`, `.maxHang10`, `.tabata`, `.emom`) — a `TimedExerciseSpec`
/// a user then edits is NEVER snapped back to a preset (the Tindeq antipattern). They are convenience
/// factories, not a closed set the spec must belong to.
///
/// Phase 5 wires the simple modes (`.openCountUp` / `.maxHang` / `.countDown`) into the existing
/// `StopwatchView` timer path; the **structured** interval runner for `.repeaters` / `.tabata` / `.emom`
/// is Phase 6 (this spec already carries the parameters that runner will read).
struct TimedExerciseSpec: Codable, Sendable, Hashable {

    /// How the clock is arranged. The first three drive the simple count-up / count-down `StopwatchView`;
    /// the last three carry interval parameters for the Phase-6 structured runner.
    enum Mode: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Free count-up — time an open-ended hold/effort, no target (the legacy "Timed exercise" behavior).
        case openCountUp
        /// A single max-effort hang/hold counted down from `workSec` (e.g. a 7 s or 10 s max hang).
        case maxHang
        /// Count down from `workSec` to zero (a plank / wall-sit hold for a fixed target).
        case countDown
        /// Hangboard repeaters: `reps` of `workSec` on / `restSec` off, repeated for `sets` (e.g. 7:3 × 6).
        case repeaters
        /// Tabata intervals: `reps` of `workSec` on / `restSec` off (classically 20:10 × 8).
        case tabata
        /// EMOM (every-minute-on-the-minute): one effort at the top of each minute for `reps` minutes.
        case emom

        var id: String { rawValue }

        /// Short label for the structure picker / chips.
        var label: String {
            switch self {
            case .openCountUp: return "Count up"
            case .maxHang:     return "Max hang"
            case .countDown:   return "Count down"
            case .repeaters:   return "Repeaters"
            case .tabata:      return "Tabata"
            case .emom:        return "EMOM"
            }
        }

        /// Whether the mode is a simple single-clock effort (Phase 5's `StopwatchView` path) as opposed to
        /// a structured multi-interval protocol (the Phase-6 runner).
        var isStructured: Bool {
            switch self {
            case .openCountUp, .maxHang, .countDown: return false
            case .repeaters, .tabata, .emom:         return true
            }
        }
    }

    /// The structure.
    var mode: Mode
    /// Seconds of work per rep / the single-hold target. `0` for an open count-up (no target).
    var workSec: Int
    /// Seconds of rest between reps within a set.
    var restSec: Int
    /// Reps (work intervals) per set.
    var reps: Int
    /// Number of sets.
    var sets: Int
    /// Seconds of rest between sets (after a set's last rep).
    var restBetweenSetsSec: Int
    /// Lead-in countdown before the first rep starts (so you can get on the wall). Default 3.
    var leadInSec: Int

    init(mode: Mode, workSec: Int = 0, restSec: Int = 0, reps: Int = 1, sets: Int = 1,
         restBetweenSetsSec: Int = 0, leadInSec: Int = 3) {
        self.mode = mode
        self.workSec = max(0, workSec)
        self.restSec = max(0, restSec)
        self.reps = max(1, reps)
        self.sets = max(1, sets)
        self.restBetweenSetsSec = max(0, restBetweenSetsSec)
        self.leadInSec = max(0, leadInSec)
    }

    // MARK: - Pure derivations

    /// Total prescribed seconds the structure runs for (lead-in + all work + all rest, between-set rest
    /// only *between* sets — not after the last). An open count-up has no prescribed total → `nil`.
    var totalSeconds: Int? {
        if mode == .openCountUp { return nil }
        // Per set: reps work intervals, with (reps − 1) inter-rep rests between them.
        let workPerSet = reps * workSec
        let restPerSet = max(0, reps - 1) * restSec
        let perSet = workPerSet + restPerSet
        // Between-set rest applies (sets − 1) times.
        let betweenSets = max(0, sets - 1) * restBetweenSetsSec
        return leadInSec + sets * perSet + betweenSets
    }

    /// A one-line human summary of the structure: "7:3 × 6 · 3 sets" / "10s" / "count up".
    var summary: String {
        switch mode {
        case .openCountUp:
            return "Count up"
        case .maxHang, .countDown:
            // A single fixed hold — show its target. (maxHang of 0 is degenerate → fall back to count up.)
            return workSec > 0 ? "\(workSec)s hold" : "Count up"
        case .repeaters, .tabata:
            // work:rest × reps, plus the set count when there's more than one.
            var s = "\(workSec):\(restSec) × \(reps)"
            if sets > 1 { s += " · \(sets) sets" }
            return s
        case .emom:
            return "EMOM × \(reps)\(sets > 1 ? " · \(sets) sets" : "")"
        }
    }

    // MARK: - Protocol presets (PRE-FILL ONLY — never snap a user value back to these)

    /// Hangboard repeaters, 7 s on / 3 s off × 6, six sets — the classic max-strength protocol.
    static var repeaters7x3x6: TimedExerciseSpec {
        TimedExerciseSpec(mode: .repeaters, workSec: 7, restSec: 3, reps: 6, sets: 6,
                          restBetweenSetsSec: 180)
    }

    /// A single 10 s max hang.
    static var maxHang10: TimedExerciseSpec {
        TimedExerciseSpec(mode: .maxHang, workSec: 10, reps: 1, sets: 1)
    }

    /// A single 7 s max hang.
    static var maxHang7: TimedExerciseSpec {
        TimedExerciseSpec(mode: .maxHang, workSec: 7, reps: 1, sets: 1)
    }

    /// Tabata, 20 s on / 10 s off × 8.
    static var tabata: TimedExerciseSpec {
        TimedExerciseSpec(mode: .tabata, workSec: 20, restSec: 10, reps: 8, sets: 1)
    }

    /// EMOM, 10 rounds (one effort every minute).
    static var emom: TimedExerciseSpec {
        TimedExerciseSpec(mode: .emom, workSec: 0, restSec: 0, reps: 10, sets: 1)
    }

    /// A fixed hold for `seconds` counted down (plank / wall-sit).
    static func hold(_ seconds: Int) -> TimedExerciseSpec {
        TimedExerciseSpec(mode: .countDown, workSec: seconds, reps: 1, sets: 1)
    }
}
