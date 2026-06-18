import Foundation

/// Pure, device-free rules for the **remembered rest timer** (Quick Session redesign Phase 7): after
/// completing an attempt/set the player can auto-start a count-down rest in the command bar, and the
/// chosen duration is remembered **per climb-type / per timed-exercise** so the next rest pre-fills to
/// the same length. This type owns only the deterministic, testable parts — the persistence **key** for
/// a given context, the **clamp** that keeps a stored value sane, and the **suggested** default when
/// nothing was remembered yet. The view holds the actual `@AppStorage`-backed dictionary and the live
/// stopwatch; this stays pure so it runs in `SnappetTests` with no simulator (the repo's
/// pure-logic-at-a-thin-edge rule, shipped foundation-first like `StopwatchTiming` / `FreeformSummary`).
enum RestTimerDefaults {

    /// The kind of effort a rest follows — drives both the remembered-duration KEY and the seeded
    /// default. A climb rest is keyed by `ClimbType` (a boulder burn and a lead pitch want different
    /// rests); a timed-exercise rest is keyed by the exercise's `TimedExerciseCategory`; a lifting set
    /// shares one key (per-exercise lifting rests are out of scope this phase — one "lifting" bucket).
    enum Context: Equatable, Sendable {
        case climb(ClimbType)
        case timed(TimedExerciseCategory)
        case lifting

        /// The stable persistence sub-key — combined under one `@AppStorage` namespace so the climbing
        /// and timed buckets never collide. Stable across launches (raw values, not display strings).
        var key: String {
            switch self {
            case .climb(let type):    return "climb.\(type.rawValue)"
            case .timed(let category): return "timed.\(category.rawValue)"
            case .lifting:            return "lifting"
            }
        }

        /// The seeded rest (seconds) when nothing has been remembered for this context yet — a sensible
        /// starting point per discipline: a short shake-out between boulder burns, a longer recovery for
        /// a roped pitch, a hangboard-protocol rest, a standard between-sets lifting rest.
        var suggestedSeconds: Int {
            switch self {
            case .climb(let type):    return type.isRoute ? 240 : 120
            case .timed(let category): return category == .hangboard ? 180 : 60
            case .lifting:            return 120
            }
        }
    }

    /// The shortest / longest rest the timer will arm — a stored or hand-set value is clamped into this
    /// band so a corrupt default or a runaway stepper can never arm a 0 s or hour-long countdown.
    static let minSeconds = 10
    static let maxSeconds = 600

    /// The step the +/- rest steppers move by (15 s granularity reads naturally for a rest).
    static let stepSeconds = 15

    /// Clamp any candidate rest length into `[minSeconds, maxSeconds]`.
    static func clamp(_ seconds: Int) -> Int {
        min(maxSeconds, max(minSeconds, seconds))
    }

    /// The full `@AppStorage` namespace for the remembered-rest dictionary — one key holds the whole
    /// per-context map (JSON), so adding a new context never adds a new defaults key.
    static let storageKey = "freeform.restDefaults.v1"

    /// The remembered rest for a context, decoding the persisted `[contextKey: seconds]` map; falls
    /// back to the context's `suggestedSeconds` when absent, and clamps either way so the armed value
    /// is always in band. Pure: the caller passes the decoded map in (the view reads it from
    /// `@AppStorage`), so this is fully testable without UserDefaults.
    static func remembered(for context: Context, in map: [String: Int]) -> Int {
        clamp(map[context.key] ?? context.suggestedSeconds)
    }

    /// The updated map after remembering `seconds` for a context (clamped). Returns a NEW map so the
    /// caller can write it straight back to `@AppStorage`; never mutates in place.
    static func remembering(_ seconds: Int, for context: Context, in map: [String: Int]) -> [String: Int] {
        var next = map
        next[context.key] = clamp(seconds)
        return next
    }

    /// Encode/decode the per-context map to a JSON string for `@AppStorage` (which can't hold a
    /// dictionary directly). Round-trips losslessly; a malformed string decodes to an empty map so a
    /// corrupt default degrades to the seeded suggestions rather than crashing.
    static func encode(_ map: [String: Int]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    static func decode(_ string: String) -> [String: Int] {
        guard let data = string.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return map
    }
}
