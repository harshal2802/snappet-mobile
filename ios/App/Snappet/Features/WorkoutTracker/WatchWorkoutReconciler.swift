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
    /// edge: the writing app's display name ("Apple Watch", "Google Health"), its bundle id, and
    /// the recording device's product type ("Watch6,9" / "iPhone14,3").
    struct WorkoutSource: Equatable, Sendable {
        var name: String?
        var bundleID: String?
        var productType: String?
    }

    /// A workout as it exists in HealthKit right now — used to re-link an anchor whose original
    /// `HKWorkout.uuid` disappeared (prompt 129). Fitbit/Google Health rewrite their samples on
    /// each sync: the same workout returns under a NEW uuid, which is why the app kept minting
    /// twins and why old anchors resolved to nothing.
    struct WorkoutIdentity: Equatable, Sendable {
        var uuid: UUID
        var start: Date
        var duration: TimeInterval
        var source: WorkoutSource
    }

    /// One existing import anchor, for maintenance (prompts 128/129).
    struct AnchorInfo: Equatable, Sendable {
        var sessionID: UUID
        var workoutUUID: UUID
        /// How many `SessionMedia` rows the anchor owns — the duplicate-collapse keeper criterion.
        var mediaCount: Int
        /// The anchor's own window, for re-linking to a re-synced workout.
        var start: Date = .distantPast
        var duration: TimeInterval = 0
    }

    /// What to do with an existing anchor (prompt 129).
    enum AnchorAction: Equatable, Sendable {
        /// The workout still exists: stamp/refresh the stored provenance so the row can name its
        /// real origin instead of claiming the Watch.
        case stampSource(sessionID: UUID, source: WorkoutSource)
        /// The original uuid is gone but the SAME workout is back under a new one (a Fitbit/Google
        /// Health re-sync): point the anchor at it and stamp the source. Keeps the row and its
        /// clips instead of deleting and re-minting a twin.
        case relink(sessionID: UUID, to: UUID, source: WorkoutSource)
        /// Nothing in HealthKit corresponds to this anchor any more — drop it (media rows go with
        /// it via `SessionCascade`). Only ever emitted when the lookup is demonstrably healthy.
        case delete(sessionID: UUID)
    }

    /// How far apart a re-synced workout's start/duration may be and still be judged the same
    /// workout. Re-syncs rewrite samples verbatim, so this only absorbs sub-minute jitter.
    static let relinkTolerance: TimeInterval = 60

    /// Anchor maintenance (prompt 129) — what to do with every existing import anchor.
    ///
    /// Replaces prompt 128's delete-only `staleAnchors`, which was built on the wrong model: it
    /// assumed an unresolvable anchor meant a workout the user deleted, when on a real device it
    /// meant **Fitbit/Google Health had re-synced and rewritten the workout under a new uuid**.
    /// Deleting there would throw away a real session (and its clips); the right move is to
    /// re-link. Rules, in order:
    ///
    /// 1. **Duplicates collapse** — several anchors for ONE uuid keep the most-media one (ties on
    ///    sessionID, stable). The rest are deleted.
    /// 2. **Resolvable** → `stampSource`, so the row can name its true origin.
    /// 3. **Unresolvable but matched** (same start ± tolerance, same duration ± tolerance, and the
    ///    candidate isn't already anchored) → `relink` + stamp.
    /// 4. **Unresolvable and unmatched** → `delete`, but ONLY when `lookupHealthy` (some anchors
    ///    did resolve, proving reads work). A denied/blipped HealthKit read must never be read as
    ///    "the user deleted everything".
    /// 5. Own-source anchors (`shouldImport` false) are deleted — the tracked session owns that data.
    static func maintain(anchors: [AnchorInfo],
                         sources: [UUID: WorkoutSource],
                         candidates: [WorkoutIdentity] = [],
                         lookupHealthy: Bool) -> [AnchorAction] {
        var out: [AnchorAction] = []
        var claimedCandidates = Set(anchors.map(\.workoutUUID))     // never relink onto a live anchor
        let byWorkout = Dictionary(grouping: anchors, by: \.workoutUUID)

        for workoutUUID in byWorkout.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let group = byWorkout[workoutUUID] ?? []
            let keeper = group.min { a, b in
                if a.mediaCount != b.mediaCount { return a.mediaCount > b.mediaCount }
                return a.sessionID.uuidString < b.sessionID.uuidString
            }
            // Rule 1 — every non-keeper in a duplicate group goes.
            for dupe in group where dupe.sessionID != keeper?.sessionID {
                out.append(.delete(sessionID: dupe.sessionID))
            }
            guard let anchor = keeper else { continue }

            if let source = sources[workoutUUID] {
                // Rule 5 then rule 2.
                if !shouldImport(sourceBundleID: source.bundleID, sourceProductType: source.productType) {
                    out.append(.delete(sessionID: anchor.sessionID))
                } else {
                    out.append(.stampSource(sessionID: anchor.sessionID, source: source))
                }
                continue
            }

            // Rule 3 — a re-synced twin of this exact workout?
            let match = candidates.first { cand in
                !claimedCandidates.contains(cand.uuid)
                    && abs(cand.start.timeIntervalSince(anchor.start)) <= relinkTolerance
                    && abs(cand.duration - anchor.duration) <= relinkTolerance
            }
            if let match {
                claimedCandidates.insert(match.uuid)
                out.append(.relink(sessionID: anchor.sessionID, to: match.uuid, source: match.source))
            } else if lookupHealthy {
                out.append(.delete(sessionID: anchor.sessionID))   // Rule 4
            }
        }
        return out
    }

    /// Source gate — decided from WHO WROTE the workout, before any timing logic.
    ///
    /// **Only one rule: never re-import our own recordings.** A session tracked in-app with the
    /// watch streaming writes an `HKWorkout` under the app's own bundle; the tracked session is
    /// authoritative and already holds that data, so importing it back would duplicate it. (The
    /// FR10 gym-overlap check tried to express this as a midpoint-in-window heuristic, which
    /// missed whenever a long watch workout swallowed a short tracked one.)
    ///
    /// Everything else imports, **whoever wrote it**. Prompt 127 additionally demanded a real
    /// Watch (`productType` "Watch…") on the theory that a section named "From Apple Watch" should
    /// only hold watch recordings. Device evidence killed that: Apple Health is a shared store and
    /// this user's climbing sessions are written into it by **Google Health (`com.fitbit
    /// .FitbitMobile`, productType iPhone…)** — real workouts, with real clips filmed during them.
    /// Dropping them would have silently stranded that footage. The lie was never the import; it
    /// was the ⌚ label the app stamped on everything (fixed by storing the true source and
    /// naming it — `WorkoutSession.importSourceLabel`).
    static func shouldImport(sourceBundleID: String?, sourceProductType: String? = nil,
                             ownBundlePrefix: String = "com.snappet") -> Bool {
        sourceBundleID?.hasPrefix(ownBundlePrefix) != true
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
