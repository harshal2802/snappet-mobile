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

    /// Who recorded a workout — `HKSourceRevision` snapshotted into plain values at the service
    /// edge (bundle id + recording device product type, e.g. "Watch6,9").
    struct WorkoutSource: Equatable, Sendable {
        var bundleID: String?
        var productType: String?
    }

    /// One existing watch-import anchor, for the retroactive cleanup (prompt 128).
    struct AnchorInfo: Equatable, Sendable {
        var sessionID: UUID
        var workoutUUID: UUID
        /// How many `SessionMedia` rows the anchor owns — the duplicate-collapse keeper criterion.
        var mediaCount: Int
    }

    /// Retroactive cleanup (prompt 128): which existing anchors should be DELETED.
    ///
    /// Prompt 127's source gate stops NEW ghosts, but anchors minted before it exist on real
    /// phones — a tracked Quick Session's own watch recording sat in "From Apple Watch", some of
    /// them twice. Two rules, both conservative:
    ///
    /// 1. **Duplicates collapse.** Several anchors for ONE `HKWorkout.uuid` (a historical FR3
    ///    breach — e.g. two reconciles racing before either saved) keep exactly one: the most
    ///    media, ties broken by sessionID for determinism. The rest go.
    /// 2. **Sources that fail `shouldImport` go.** The app's own companion recordings (the ghost
    ///    Quick Sessions) and phone-written workouts. A uuid with NO source entry (the workout
    ///    was since deleted from HealthKit) is KEPT — can't judge, don't touch.
    static func staleAnchors(anchors: [AnchorInfo],
                             sources: [UUID: WorkoutSource]) -> [UUID] {
        var doomed: [UUID] = []
        let byWorkout = Dictionary(grouping: anchors, by: \.workoutUUID)
        for (workoutUUID, group) in byWorkout {
            // The duplicate-collapse keeper: most media wins; ties break on sessionID so the
            // choice is stable across runs.
            var keeper: AnchorInfo? = group.min { a, b in
                if a.mediaCount != b.mediaCount { return a.mediaCount > b.mediaCount }
                return a.sessionID.uuidString < b.sessionID.uuidString
            }
            if let source = sources[workoutUUID],
               !shouldImport(sourceBundleID: source.bundleID, sourceProductType: source.productType) {
                keeper = nil    // the whole group is a ghost — nothing survives
            }
            doomed += group.filter { $0.sessionID != keeper?.sessionID }.map(\.sessionID)
        }
        return doomed.sorted { $0.uuidString < $1.uuidString }   // deterministic for tests/logs
    }

    /// Source gate (prompt 127) — decided from WHO WROTE the workout, before any timing logic:
    ///
    /// 1. **Snappet's own watch companion never re-imports.** A tracked Quick Session (or routine /
    ///    Kilter / festival session) with the watch streaming records a real `HKWorkout` under the
    ///    app's own bundle; the tracked session is authoritative and already holds the data. The
    ///    FR10 gym-overlap check tried to express this with a midpoint-in-window heuristic — which
    ///    is why a Quick Session could still ghost into "From Apple Watch" when the windows
    ///    drifted, and why Kilter (deliberately outside FR10, decision Q2) always did.
    /// 2. **Only genuine watch recordings import.** The section is CALLED "From Apple Watch"; a
    ///    workout written by an iPhone app (Google Fit, Strava-on-phone, …) is neither recorded on
    ///    a watch nor missing from its own app — importing it mislabels its provenance. Product
    ///    types look like "Watch6,9" / "iPhone14,3"; an absent product type fails closed.
    ///
    /// FR10 stays: it still suppresses a workout the user double-tracked with the *Apple* Workout
    /// app during an in-app gym session (a foreign source this gate correctly lets through).
    static func shouldImport(sourceBundleID: String?, sourceProductType: String?,
                             ownBundlePrefix: String = "com.snappet") -> Bool {
        if sourceBundleID?.hasPrefix(ownBundlePrefix) == true { return false }
        return sourceProductType?.hasPrefix("Watch") == true
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
