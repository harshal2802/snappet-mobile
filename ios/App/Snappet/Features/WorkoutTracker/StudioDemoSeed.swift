import Foundation
import SwiftData

/// Test-only demo seed for the **Live Workout Capture + Video Studio** walkthrough.
///
/// Seeds, on first launch, a single **completed** `WorkoutSession` carrying a realistic
/// synthetic `hrSeries` (warm-up → work intervals → cool-down, ~120–175 bpm over ~30 min,
/// one `HRPoint` every few seconds). This is **data only** — no Photos / video needed — so the
/// B2 enriched summary's HR chart + avg/max/min + time-in-zone bar actually RENDER on the
/// simulator (which has no live HR source and would otherwise persist an empty `hrSeries`,
/// hiding the whole HR section). The B1 tagged-media gallery / B3 clip editor / B4 highlight
/// reel still need real video and stay device-only — the seed showcases the **HR summary**
/// plus the live player / timers / source-picker UI.
///
/// **Strictly test-arg-guarded with ZERO production impact**: it only runs when the process was
/// launched with `-uiTestSeedStudioDemo` (a sibling to `-uiTestFreshStore`, which it implies —
/// the caller passes the seed arg and `SnappetApp` always builds a fresh in-memory store for it,
/// so a normal/production launch never reaches this code). Idempotent: it no-ops if the demo
/// session already exists (keyed on a fixed `routineID`).
enum StudioDemoSeed {
    /// The launch argument that enables the seed.
    static let argument = "-uiTestSeedStudioDemo"

    /// A fixed routine id so the seeded session is idempotent (re-running the seed no-ops) and
    /// so the walkthrough can recognise *the* demo session unambiguously.
    static let routineID = UUID(uuidString: "5712D0DE-5712-0DEC-A57E-1234DEA00001")!

    /// The routine/session name the walkthrough screenshots as the headline summary. Distinct
    /// from the bundled starter names so the History row is unambiguous.
    static let routineName = "Studio Demo — Full Body"

    /// Seed the demo session if the launch arg is present and it isn't already there. Called from
    /// `SnappetApp.init()` against the fresh in-memory container, before any UI appears.
    @MainActor
    static func seedIfRequested(into context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let rid = routineID
        let existing = try? context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.routineID == rid }))
        guard (existing?.isEmpty ?? true) else { return }

        // A ~30-minute session that finished a little while ago.
        let duration: TimeInterval = 30 * 60
        let startedAt = Date(timeIntervalSinceNow: -(duration + 5 * 60))
        let completedAt = startedAt.addingTimeInterval(duration)

        let session = WorkoutSession(
            routineID: rid,
            routineName: routineName,
            startedAt: startedAt,
            completedAt: completedAt,
            exercises: demoExercises(),
            hrSeries: syntheticHRSeries(durationSec: duration, sampleEverySec: 3))
        context.insert(session)

        // A matching usage record so the Home dashboard / History stats look real.
        context.insert(UsageRecord(
            module: WorkoutTrackerModule.id, action: "session",
            summary: "Completed \(routineName)", metric: duration / 60,
            timestamp: completedAt))

        try? context.save()
    }

    // MARK: - Synthetic data

    /// A few logged exercises with completed sets, so the summary's per-exercise sections and the
    /// volume/sets stats render. Uses bundled exercise ids (see `exercises.json` / `StarterRoutines`).
    @MainActor
    private static func demoExercises() -> [SessionExercise] {
        func completed(reps: Int?, weight: Double?) -> SetLog {
            SetLog(actualReps: reps, actualWeight: weight, weightUnit: .kg, completedAt: .now)
        }
        return [
            SessionExercise(
                exerciseId: "Bodyweight_Squat", targetSets: 3, targetReps: "12",
                targetRestSeconds: 60, targetWeightUnit: .kg,
                sets: [completed(reps: 12, weight: nil), completed(reps: 12, weight: nil),
                       completed(reps: 10, weight: nil)]),
            SessionExercise(
                exerciseId: "Dumbbell_Bicep_Curl", targetSets: 3, targetReps: "10",
                targetRestSeconds: 60, targetWeight: 12, targetWeightUnit: .kg,
                sets: [completed(reps: 10, weight: 12), completed(reps: 10, weight: 12),
                       completed(reps: 8, weight: 14)]),
            SessionExercise(
                exerciseId: "Plank", targetSets: 3, targetReps: "30s",
                targetRestSeconds: 45, targetWeightUnit: .kg,
                sets: [completed(reps: nil, weight: nil), completed(reps: nil, weight: nil),
                       completed(reps: nil, weight: nil)]),
        ]
    }

    /// A deterministic, realistic HR curve over the session: a warm-up ramp, several work
    /// intervals with recovery dips, then a cool-down. ~120–175 bpm. `t` is seconds from
    /// `startedAt` (engine convention — same timeline as `HRSample.t`). No randomness, so the
    /// chart/stats render identically on every run.
    static func syntheticHRSeries(durationSec: TimeInterval, sampleEverySec: Double) -> [HRPoint] {
        guard durationSec > 0, sampleEverySec > 0 else { return [] }
        var points: [HRPoint] = []
        var t: Double = 0
        while t <= durationSec {
            points.append(HRPoint(t: t, bpm: bpm(atFraction: t / durationSec)))
            t += sampleEverySec
        }
        return points
    }

    /// The HR model over a normalized session position `f` ∈ [0, 1]:
    /// warm-up (0–0.2): 120 → 150 ramp; intervals (0.2–0.8): 150 baseline with five ~+22 bpm
    /// surges peaking near 175 and recovery dips toward 140; cool-down (0.8–1): 150 → 122 ramp.
    private static func bpm(atFraction f: Double) -> Double {
        let value: Double
        switch f {
        case ..<0.2:
            value = 120 + (f / 0.2) * 30                      // 120 → 150 warm-up
        case ..<0.8:
            let p = (f - 0.2) / 0.6                           // 0…1 across the work block
            let surge = sin(p * .pi * 5)                      // five work/recovery oscillations
            value = 150 + surge * 22                          // ~128 … ~172
        default:
            let p = (f - 0.8) / 0.2                           // 0…1 across the cool-down
            value = 150 - p * 28                              // 150 → 122 cool-down
        }
        return (value).rounded()
    }
}
