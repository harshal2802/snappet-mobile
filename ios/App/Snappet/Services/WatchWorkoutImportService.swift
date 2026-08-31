import Foundation
import SwiftData

/// Imports **Apple Watch workouts the app never controlled** into the Clips feed (watch-workouts-clips,
/// PR1). Reads completed `HKWorkout`s from HealthKit post-hoc, auto-discovers the photos/videos shot in
/// each workout's window, and — via the pure `WatchWorkoutReconciler` — mints a completed
/// `WorkoutSession` anchor (media-only) so those clips surface in Clips, or attaches late-syncing media
/// to an anchor that already exists.
///
/// This is the thin device shell: HealthKit reads, one PhotoKit scan, SwiftData writes. Every *decision*
/// lives in `WatchWorkoutReconciler` (unit-tested with no device). `@MainActor` because it writes the
/// shared `ModelContext`; the HealthKit/Photos reads hop off-main inside their continuations.
///
/// Idempotent + re-runnable: a second pass over the same workouts mints nothing new (the anchor already
/// exists, keyed on `HKWorkout.uuid`) and only attaches media that appeared since.
@MainActor
final class WatchWorkoutImportService {
    private let health: HealthKitService
    private let sessionMedia: SessionMediaService

    init(health: HealthKitService, sessionMedia: SessionMediaService) {
        self.health = health
        self.sessionMedia = sessionMedia
    }

    /// The end date of the newest workout we've reconciled — the incremental watermark. Absent ⇒ first
    /// install ⇒ scan **all-time** so the feed has content out of the box.
    private static let watermarkKey = "watchImport.lastWorkoutEnd"
    /// On steady-state runs, re-scan this far back before the watermark so media that synced *after* a
    /// recent workout completed (FR4) is still picked up for its already-minted anchor.
    private static let lookBack: TimeInterval = 7 * 86_400

    struct Result: Equatable { var minted: Int; var attachedClips: Int }

    /// Reconcile watch workouts → anchors + media. `profileMaxHR` stamps the anchor's `maxHR` for
    /// %-of-max zones (mirrors the tracked-session path); `nil` falls back to the engine default.
    @discardableResult
    func reconcile(context: ModelContext, profileMaxHR: Double?) async -> Result {
        // Full Photos authorization is required for a time-window library scan; `.limited`/denied ⇒
        // we can't auto-discover, so watch workouts simply don't populate (documented degradation).
        guard sessionMedia.canAutoDiscover else { return Result(minted: 0, attachedClips: 0) }

        let defaults = UserDefaults.standard
        let watermark = defaults.object(forKey: Self.watermarkKey) as? Date
        let since = watermark.map { $0.addingTimeInterval(-Self.lookBack) } ?? .distantPast

        // Drop workouts the user DELETED from History (prompt 125): without the tombstone check,
        // a deleted anchor inside the look-back window is simply missing from
        // `anchoredSessionByUUID` and gets re-minted on the very next pass — delete didn't stick.
        let tombstones = WatchImportTombstones.all()
        let workouts = ((try? await health.workoutsForImport(since: since)) ?? [])
            .filter { !tombstones.contains($0.id) }
        guard let unionStart = workouts.map(\.start).min(),
              let unionEnd = workouts.map(\.end).max() else { return Result(minted: 0, attachedClips: 0) }

        // ONE Photos scan over the whole span (± pad), then bucket per workout in pure code — the
        // unbounded first run could otherwise fire hundreds of per-workout queries.
        let pad = SessionMediaService.padSec
        let span = DateInterval(start: unionStart.addingTimeInterval(-pad),
                                end: max(unionEnd, unionStart).addingTimeInterval(pad))
        guard let rawAssets = try? await sessionMedia.rawAssets(in: span) else {
            return Result(minted: 0, attachedClips: 0)
        }

        // ── Inputs for the pure planner ───────────────────────────────────────────────────────────
        // Global dedup: never re-tag an asset already owned by ANY session (a video shot during a
        // Kilter/gym session stays there; the watch import only claims still-untagged media).
        var claimed = SessionMedia.allIdentifiers(in: context)

        let anchored = (try? context.fetch(
            FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.healthKitWorkoutUUID != nil }))) ?? []
        var anchoredByUUID: [UUID: UUID] = [:]
        for s in anchored { if let u = s.healthKitWorkoutUUID { anchoredByUUID[u] = s.id } }

        let gymSessions = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.completedAt != nil && $0.healthKitWorkoutUUID == nil }))) ?? []
        let gymIntervals: [DateInterval] = gymSessions.compactMap { s in
            guard let end = s.completedAt else { return nil }
            return DateInterval(start: s.startedAt, end: max(end, s.startedAt))
        }

        // Bucket media per workout, oldest first, claiming greedily so one asset can't feed two
        // overlapping workout windows.
        var candidatesByWorkout: [UUID: [SessionMediaService.Candidate]] = [:]
        var infos: [WatchWorkoutReconciler.WorkoutInfo] = []
        let summaryByUUID = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for wk in workouts.sorted(by: { $0.start < $1.start }) {
            let cands = SessionMediaService.candidates(
                from: rawAssets, startedAt: wk.start, completedAt: wk.end, existingIdentifiers: claimed)
            candidatesByWorkout[wk.id] = cands
            for c in cands { claimed.insert(c.localIdentifier) }
            infos.append(WatchWorkoutReconciler.WorkoutInfo(
                workoutUUID: wk.id, displayName: wk.activityLabel ?? "Workout",
                start: wk.start, end: wk.end,
                energyKcal: wk.energyKcal, distanceMeters: wk.distanceMeters))
        }

        let actions = WatchWorkoutReconciler.plan(
            workouts: infos,
            anchoredSessionByUUID: anchoredByUUID,
            existingMediaBySession: [:],                 // candidates are already globally deduped above
            candidatesByWorkout: candidatesByWorkout,
            gymSessionIntervals: gymIntervals)

        // ── Apply ─────────────────────────────────────────────────────────────────────────────────
        var minted = 0, attached = 0
        for action in actions {
            switch action {
            case let .mint(info, cands):
                let session = WorkoutSession(
                    routineName: info.displayName,
                    startedAt: info.start, completedAt: info.end,
                    metricsSourceRaw: MetricsSourceKind.appleWatch.rawValue,
                    healthKitWorkoutUUID: info.workoutUUID,
                    hkEnergyKcal: info.energyKcal, hkDistanceMeters: info.distanceMeters)
                // Back-fill the HealthKit HR series so the Clips overlay + session detail have it.
                if let samples = try? await health.heartRateSamples(start: info.start, end: info.end),
                   !samples.isEmpty {
                    session.hrSeries = samples.map { HRPoint(t: $0.t, bpm: $0.bpm) }
                }
                session.restHR = summaryByUUID[info.workoutUUID]?.restingBpm
                session.maxHR = profileMaxHR
                context.insert(session)
                for c in cands { insertMedia(c, sessionID: session.id, into: context) }
                minted += 1
            case let .attach(sessionID, newCandidates):
                for c in newCandidates {
                    insertMedia(c, sessionID: sessionID, into: context); attached += 1
                }
            }
        }
        if minted > 0 || attached > 0 { try? context.save() }

        // Advance the watermark to the newest workout end we saw (steady-state cutoff for next run).
        if let newest = workouts.map(\.end).max() { defaults.set(newest, forKey: Self.watermarkKey) }
        return Result(minted: minted, attachedClips: attached)
    }

    private func insertMedia(_ c: SessionMediaService.Candidate, sessionID: UUID, into context: ModelContext) {
        context.insert(SessionMedia(
            sessionID: sessionID, localIdentifier: c.localIdentifier, kind: c.kind,
            offsetSec: c.offsetSec, durationSec: c.durationSec, source: .auto))
    }
}
