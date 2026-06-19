import Foundation

/// Pure, device-free planner logic for the Gym Tracker's smart-planning surface (workout-redesign E7):
///
/// 1. **The "Today" readiness verb** — REST / EASY / TRAIN / PUSH on the Pulse Pro performance ramp, plus a
///    plain-language *why*. A Whoop/Fitbod-style "are you ready to train?" read from training cadence,
///    days-since-last-session, and an optional recovery fraction. The verb is **advisory** — the suggestion
///    is always an editable draft the user can ignore (the locked decision: never forced).
/// 2. **The Plan → routine bridge** — turns a pure `WorkoutRecommender.Plan` into `[RoutineExercise]` so the
///    same draft can be **started** as a session (`RoutineSessionBuilder` consumes the routine) or **saved**
///    as a reusable routine. The E5/E6/E7 contract: a plan emits a `[RoutineExercise]`.
///
/// No SwiftData / no UI here, so it's unit-tested in `SnappetTests` with synthetic inputs exactly like
/// `KilterPlanProgress` and `WorkoutRecommender`. The view (`WorkoutPlanView`) does the I/O.
enum WorkoutPlanLogic {

    /// The four readiness verbs, declared rest → push (the performance-ramp order). `accentRamp` names where
    /// each sits on the Pulse Pro performance ramp (leaf → amber → tomato) so the view tints consistently.
    enum Readiness: String, Sendable, Equatable, CaseIterable {
        /// Trained recently / under-recovered → take a rest day (or just mobility).
        case rest
        /// Lightly recovered, or right after a hard day → an easy / recovery session.
        case easy
        /// Recovered and on cadence → a normal training day.
        case train
        /// Well-rested, overdue, fully recovered → go hard.
        case push

        var headline: String {
            switch self {
            case .rest:  return "REST"
            case .easy:  return "EASY"
            case .train: return "TRAIN"
            case .push:  return "PUSH"
            }
        }

        /// Position on the performance ramp, 0 (leaf/calm) → 1 (tomato/hard) — the view maps this to the
        /// `leaf → amber → tomato` ramp colour.
        var rampPosition: Double {
            switch self {
            case .rest:  return 0.0
            case .easy:  return 0.33
            case .train: return 0.66
            case .push:  return 1.0
            }
        }

        var systemImage: String {
            switch self {
            case .rest:  return "moon.zzz.fill"
            case .easy:  return "leaf.fill"
            case .train: return "figure.strengthtraining.traditional"
            case .push:  return "bolt.fill"
            }
        }

        /// The recommender strategy this verb leads the draft with (the suggestion follows the verb, but the
        /// user can override the strategy — the draft is editable). REST still offers a recovery draft.
        var suggestedStrategy: WorkoutRecommender.Strategy {
            switch self {
            case .rest, .easy: return .recovery
            case .train:       return .balanced
            case .push:        return .strength
            }
        }
    }

    /// A "Today" read: the verb, a plain-language *why*, and the focus muscles the plan biased toward.
    struct Today: Sendable, Equatable {
        var readiness: Readiness
        /// Plain-language explanation ("3 days since your last session — you're rested"). Always set.
        var why: String
        /// The muscles the plan targets (freshest), for the body-map / "Legs + back are freshest" line.
        var focusMuscles: [Muscle]
    }

    /// Compute today's readiness verb + why from the device-free signals. `daysSinceLastSession` is `nil` on
    /// a fresh install (never trained) → defaults to TRAIN (a gentle "let's start"). `recoveryFraction` is
    /// the optional `RecoveryReadiness.fraction` (1 = fully recovered toward rest); `nil` ⇒ ignored, the
    /// heuristic leans on cadence alone (recovery is a *sharpener*, never required — the same posture as
    /// the AI sharpener and `RecoveryReadiness` itself).
    static func today(signal: WorkoutHistoryStats,
                      daysSinceLastSession: Int?,
                      recoveryFraction: Double? = nil) -> Today {
        let focus = WorkoutRecommender.focusMuscles(signal: signal, count: 3)

        // Cadence-relative readiness: compare days-since-last against the user's own median gap. Trained
        // today / yesterday with a short cadence → ease off; overdue vs cadence → push.
        let cadence = signal.medianGapDays ?? 2
        guard let days = daysSinceLastSession else {
            // Never trained — encourage a normal first session, not a "push".
            return Today(readiness: .train,
                         why: "Welcome — here's a balanced first session to ease in.",
                         focusMuscles: focus)
        }

        var verb: Readiness
        var why: String
        switch days {
        case 0:
            verb = .rest
            why = "You already trained today — rest or keep it light."
        case _ where days < max(1, cadence):
            verb = .easy
            why = "Only \(days) day\(days == 1 ? "" : "s") since your last session — go easy today."
        case _ where days <= cadence + 1:
            verb = .train
            why = "\(days) day\(days == 1 ? "" : "s") rested — you're on cadence to train."
        default:
            verb = .push
            why = "\(days) days since your last session — you're well rested. Go hard."
        }

        // The recovery sharpener nudges the verb one step when it strongly disagrees with cadence: a low
        // recovery fraction caps an otherwise-PUSH at TRAIN (and TRAIN → EASY); a high one lifts EASY → TRAIN.
        if let rf = recoveryFraction {
            if rf < 0.4 {
                if verb == .push  { verb = .train; why += " (Heart rate says you're not fully recovered.)" }
                else if verb == .train { verb = .easy; why += " (Heart rate says ease off.)" }
            } else if rf >= 0.75, verb == .easy {
                verb = .train; why += " (Heart rate says you've recovered well.)"
            }
        }

        return Today(readiness: verb, why: why, focusMuscles: focus)
    }

    // MARK: - Plan → routine bridge

    /// Turn a recommender `Plan` into ordered `[RoutineExercise]` — the startable/saveable form. Each pick
    /// becomes a strength `RoutineExercise` carrying its (strategy-tuned) sets·reps·rest; the goal label is
    /// folded into the display name so the started session / saved routine reads "Main · Bench Press".
    /// `nameFor` resolves an exerciseId → a human name at the I/O edge (the `@MainActor` resolver), defaulting
    /// to the candidate's own name. Pure → unit-tested.
    static func routineExercises(from plan: WorkoutRecommender.Plan,
                                 nameFor: (String) -> String = { $0 }) -> [RoutineExercise] {
        plan.picks.map { pick in
            RoutineExercise(
                exerciseId: pick.candidate.id,
                sets: pick.sets,
                reps: pick.reps,
                restSeconds: pick.restSeconds,
                weightUnit: nil,
                displayName: nameFor(pick.candidate.id),
                discipline: .strength)
        }
    }

    /// A default routine name for a saved plan (the editor lets the user rename). Folds the verb + a date so
    /// "PUSH · Jun 19" reads naturally in the routines list.
    static func defaultRoutineName(readiness: Readiness, date: Date,
                                   calendar: Calendar = .current) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        return "\(readiness.headline.capitalized) · \(day)"
    }
}
