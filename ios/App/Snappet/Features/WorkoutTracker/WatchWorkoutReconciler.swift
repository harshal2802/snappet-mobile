import Foundation

// MARK: - Apple Watch workouts → Clips: pure reconciliation (watch-workouts-clips, PR1)
//
// The app never controls these workouts. After one finishes and syncs, HealthKit surfaces a completed
// `HKWorkout` with a `[start, end]` window and an HR series — everything media auto-discovery and the
// Clips composer need, EXCEPT a persisted anchor a `SessionMedia` row can point at. This decides, from
// plain values, which watch workouts to turn into `WorkoutSession` anchors, which already-anchored ones
// to attach late-syncing media to, and which to skip. No HealthKit / Photos / SwiftData type crosses
// this boundary, so the whole decision is unit-tested in `SnappetTests` with no device.
//
// The rules (from the requirements):
//   • FR2 media-only — a workout with zero clips in its window mints nothing.
//   • FR3 idempotent — never a second anchor for the same `HKWorkout.uuid`; re-runs are safe.
//   • FR4 late media — an already-anchored workout gets NEW clips attached additively (deduped).
//   • FR10 gym-overlap — suppress minting when the window overlaps a user-tracked *gym* session
//     (that in-app session is authoritative). Kilter is deliberately NOT an overlap source: watch
//     climbing and Kilter board climbing are distinct activities that coexist (decision Q2).
enum WatchWorkoutReconciler {

    /// A completed Apple Watch workout described in plain values — snapshotted from `HKWorkout` at the
    /// service edge (`activity`/`displayName` resolved there so this stays HealthKit-free).
    struct WorkoutInfo: Equatable, Sendable {
        var workoutUUID: UUID
        /// Human label for the anchor's `routineName` / subtitle, e.g. "Outdoor Run", "Climbing".
        var displayName: String
        var start: Date
        var end: Date
        /// Measured energy (kcal) / distance (m) from HealthKit, when present — carried for the
        /// session detail; `nil` when the workout didn't record them.
        var energyKcal: Double?
        var distanceMeters: Double?

        var interval: DateInterval { DateInterval(start: start, end: max(end, start)) }
        var midpoint: Date { Date(timeIntervalSince1970: (start.timeIntervalSince1970 + max(end, start).timeIntervalSince1970) / 2) }
    }

    /// What the service should do for one workout. Skips are simply omitted (nothing to persist).
    enum Action: Equatable {
        /// Create a new watch-origin `WorkoutSession` anchor + its `SessionMedia` rows.
        case mint(WorkoutInfo, candidates: [SessionMediaService.Candidate])
        /// Attach freshly-discovered media to an existing anchor (FR4 late sync). `sessionID` is the
        /// existing `WorkoutSession.id`; `newCandidates` are only the not-yet-stored assets.
        case attach(sessionID: UUID, newCandidates: [SessionMediaService.Candidate])
    }

    /// Decide the actions for a batch of watch workouts.
    ///
    /// - `workouts`: candidate `HKWorkout`s in scan scope (any order).
    /// - `anchoredSessionByUUID`: `HKWorkout.uuid → WorkoutSession.id` for anchors that already exist.
    /// - `existingMediaBySession`: `WorkoutSession.id → localIdentifiers already stored` (late-media dedup).
    /// - `candidatesByWorkout`: `HKWorkout.uuid → discovered media` in that workout's window.
    /// - `gymSessionIntervals`: intervals of user-tracked gym sessions, for FR10 overlap suppression.
    static func plan(
        workouts: [WorkoutInfo],
        anchoredSessionByUUID: [UUID: UUID],
        existingMediaBySession: [UUID: Set<String>],
        candidatesByWorkout: [UUID: [SessionMediaService.Candidate]],
        gymSessionIntervals: [DateInterval]
    ) -> [Action] {
        var out: [Action] = []
        // Deterministic order: oldest first, so a first-run all-time back-fill mints in chronological order.
        for wk in workouts.sorted(by: { $0.start < $1.start }) {
            let candidates = candidatesByWorkout[wk.workoutUUID] ?? []

            if let sessionID = anchoredSessionByUUID[wk.workoutUUID] {
                // Already anchored (FR3) → only attach media not already stored for it (FR4).
                let stored = existingMediaBySession[sessionID] ?? []
                let fresh = candidates.filter { !stored.contains($0.localIdentifier) }
                if !fresh.isEmpty { out.append(.attach(sessionID: sessionID, newCandidates: fresh)) }
                continue
            }

            // Not yet anchored.
            if candidates.isEmpty { continue }                                   // FR2 media-only
            if overlapsGymSession(wk, gymSessionIntervals) { continue }          // FR10 gym-overlap
            out.append(.mint(wk, candidates: candidates))
        }
        return out
    }

    /// FR10: does the workout coincide with a user-tracked gym session? True when the workout's
    /// **midpoint** falls inside any gym interval padded by `SessionMediaService.padSec` — the same
    /// ±90 s clock-skew tolerance media discovery uses, so "the same session" is judged consistently.
    static func overlapsGymSession(_ wk: WorkoutInfo, _ gymIntervals: [DateInterval],
                                   pad: TimeInterval = SessionMediaService.padSec) -> Bool {
        let mid = wk.midpoint
        return gymIntervals.contains { interval in
            let padded = DateInterval(start: interval.start.addingTimeInterval(-pad),
                                      end: interval.end.addingTimeInterval(pad))
            return padded.contains(mid)
        }
    }
}
