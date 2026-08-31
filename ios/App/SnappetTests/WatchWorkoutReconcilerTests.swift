import XCTest
@testable import Snappet

/// Unit tests for the **pure** Apple Watch → Clips reconciliation (watch-workouts-clips, PR1). No device,
/// no HealthKit, no Photos, no SwiftData — synthetic workouts + candidates → asserts which anchors mint,
/// which get late media attached, and which are suppressed (media-only, idempotency, gym overlap).
final class WatchWorkoutReconcilerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func workout(_ uuid: UUID = UUID(), name: String = "Run",
                         startOffset: Double, minutes: Double) -> WatchWorkoutReconciler.WorkoutInfo {
        WatchWorkoutReconciler.WorkoutInfo(
            workoutUUID: uuid, displayName: name,
            start: t0.addingTimeInterval(startOffset),
            end: t0.addingTimeInterval(startOffset + minutes * 60),
            energyKcal: 300, distanceMeters: 5000)
    }

    private func candidate(_ id: String, offset: Double = 10) -> SessionMediaService.Candidate {
        SessionMediaService.Candidate(localIdentifier: id, kind: .video, offsetSec: offset, durationSec: 6)
    }

    // MARK: FR2 — media-only

    func testWorkoutWithNoMediaMintsNothing() {
        let wk = workout(startOffset: 0, minutes: 30)
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [:], gymSessionIntervals: [])
        XCTAssertTrue(actions.isEmpty)
    }

    func testWorkoutWithMediaMintsAnchor() {
        let wk = workout(startOffset: 0, minutes: 30)
        let cands = [candidate("a"), candidate("b")]
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: cands], gymSessionIntervals: [])
        XCTAssertEqual(actions, [.mint(wk, candidates: cands)])
    }

    // MARK: FR3 — idempotency

    func testAlreadyAnchoredWithNoNewMediaDoesNothing() {
        let wk = workout(startOffset: 0, minutes: 30)
        let sessionID = UUID()
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk],
            anchoredSessionByUUID: [wk.workoutUUID: sessionID],
            existingMediaBySession: [sessionID: ["a"]],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],   // already stored
            gymSessionIntervals: [])
        XCTAssertTrue(actions.isEmpty, "no re-mint, no re-attach of stored media")
    }

    // MARK: FR4 — late-syncing media attaches to the existing anchor

    func testLateMediaAttachesOnlyFreshAssets() {
        let wk = workout(startOffset: 0, minutes: 30)
        let sessionID = UUID()
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk],
            anchoredSessionByUUID: [wk.workoutUUID: sessionID],
            existingMediaBySession: [sessionID: ["a"]],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a"), candidate("b")]],
            gymSessionIntervals: [])
        XCTAssertEqual(actions, [.attach(sessionID: sessionID, newCandidates: [candidate("b")])])
    }

    // MARK: FR10 — gym overlap suppression (and climbing coexistence)

    func testWorkoutOverlappingGymSessionIsSuppressed() {
        let wk = workout(startOffset: 0, minutes: 30)   // midpoint = t0 + 15 min
        let gym = DateInterval(start: t0, end: t0.addingTimeInterval(60 * 60))  // covers the midpoint
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],
            gymSessionIntervals: [gym])
        XCTAssertTrue(actions.isEmpty, "an in-app gym session owns that time window")
    }

    func testNonOverlappingWorkoutStillMintsAlongsideGym() {
        let wk = workout(startOffset: 3 * 60 * 60, minutes: 30)   // 3h later, no overlap
        let gym = DateInterval(start: t0, end: t0.addingTimeInterval(60 * 60))
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],
            gymSessionIntervals: [gym])
        XCTAssertEqual(actions.count, 1)
    }

    /// Decision Q2: Kilter is NOT a gym-overlap source, so a watch **Climbing** workout coinciding with a
    /// board session still mints — the caller only ever passes gym intervals here.
    func testClimbingCoexistsWhenNoGymIntervalsPassed() {
        let wk = workout(name: "Climbing", startOffset: 0, minutes: 45)
        let actions = WatchWorkoutReconciler.plan(
            workouts: [wk], anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [wk.workoutUUID: [candidate("a")]],
            gymSessionIntervals: [])   // Kilter intervals are deliberately not supplied
        XCTAssertEqual(actions.count, 1)
    }

    func testGymOverlapUsesPadTolerance() {
        // Workout midpoint sits 60s AFTER a gym session's end — inside the ±90s pad ⇒ suppressed.
        let gymEnd = t0.addingTimeInterval(20 * 60)
        let wk = workout(startOffset: 20 * 60 + 60 - 15, minutes: 0.5)  // midpoint ≈ gymEnd + 60s
        let gym = DateInterval(start: t0, end: gymEnd)
        XCTAssertTrue(WatchWorkoutReconciler.overlapsGymSession(wk, [gym]))
    }

    // MARK: source gate — only our OWN recordings are refused (prompt 129)

    /// A session tracked in-app writes its own `HKWorkout`; the tracked session is authoritative,
    /// so re-importing it would duplicate it.
    func testOwnRecordingsAreNeverImported() {
        XCTAssertFalse(WatchWorkoutReconciler.shouldImport(sourceBundleID: "com.snappet.app.watchkitapp"))
        XCTAssertFalse(WatchWorkoutReconciler.shouldImport(sourceBundleID: "com.snappet.app"))
    }

    /// Everything else imports, WHOEVER wrote it. Prompt 127 briefly demanded a real Watch; device
    /// evidence killed that — this user's climbing sessions are written into Apple Health by
    /// **Google Health (com.fitbit.FitbitMobile, productType iPhone14,3)**, with clips filmed
    /// during them. Dropping those would strand real footage; the bug was the ⌚ LABEL, not the
    /// import (see `WorkoutSession.importSourceLabel`).
    func testWorkoutsFromAnySourceImportIncludingPhoneWrittenOnes() {
        XCTAssertTrue(WatchWorkoutReconciler.shouldImport(sourceBundleID: "com.apple.health.8F3A"))
        XCTAssertTrue(WatchWorkoutReconciler.shouldImport(sourceBundleID: "com.fitbit.FitbitMobile"),
                      "Google Health writes real workouts into the shared Health store")
        XCTAssertTrue(WatchWorkoutReconciler.shouldImport(sourceBundleID: nil),
                      "an unknown writer is still the user's workout")
    }

    // MARK: anchor maintenance (prompt 129) — stamp, re-link, or delete

    private func anchor(_ session: UUID = UUID(), workout: UUID, media: Int = 0,
                        start: Date = Date(timeIntervalSince1970: 1_000_000),
                        minutes: Double = 30) -> WatchWorkoutReconciler.AnchorInfo {
        .init(sessionID: session, workoutUUID: workout, mediaCount: media,
              start: start, duration: minutes * 60)
    }

    private let watchSource = WatchWorkoutReconciler.WorkoutSource(
        name: "Apple Watch", bundleID: "com.apple.health.8F3A", productType: "Watch6,9")
    private let googleSource = WatchWorkoutReconciler.WorkoutSource(
        name: "Google Health", bundleID: "com.fitbit.FitbitMobile", productType: "iPhone14,3")

    /// A resolvable anchor is stamped with its true writer, so the row can say "Google Health"
    /// instead of the UI assuming a Watch.
    func testResolvableAnchorIsStampedWithItsRealSource() {
        let wk = UUID()
        let a = anchor(workout: wk, media: 1)
        let actions = WatchWorkoutReconciler.maintain(
            anchors: [a], sources: [wk: googleSource], lookupHealthy: true)
        XCTAssertEqual(actions, [.stampSource(sessionID: a.sessionID, source: googleSource)])
    }

    /// THE device bug: Fitbit/Google Health rewrite a workout on each sync under a NEW uuid, which
    /// orphaned the anchor (and made the importer mint a twin). The anchor re-links to the new
    /// uuid — keeping the row and its clips — instead of being deleted.
    func testOrphanedAnchorRelinksToReSyncedWorkout() {
        let oldUUID = UUID(), newUUID = UUID()
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        let a = anchor(workout: oldUUID, media: 3, start: start, minutes: 180)
        let resynced = WatchWorkoutReconciler.WorkoutIdentity(
            uuid: newUUID, start: start.addingTimeInterval(20), duration: 180 * 60,
            source: googleSource)

        let actions = WatchWorkoutReconciler.maintain(
            anchors: [a], sources: [:], candidates: [resynced], lookupHealthy: true)

        XCTAssertEqual(actions, [.relink(sessionID: a.sessionID, to: newUUID, source: googleSource)])
    }

    /// A different workout must not be captured by the re-link.
    func testRelinkRejectsAWorkoutWithADifferentWindow() {
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        let a = anchor(workout: UUID(), media: 1, start: start, minutes: 30)
        let other = WatchWorkoutReconciler.WorkoutIdentity(
            uuid: UUID(), start: start.addingTimeInterval(3 * 3600), duration: 30 * 60,
            source: watchSource)
        let actions = WatchWorkoutReconciler.maintain(
            anchors: [a], sources: [:], candidates: [other], lookupHealthy: true)
        XCTAssertEqual(actions, [.delete(sessionID: a.sessionID)])
    }

    /// A blipped/denied HealthKit read resolves NOTHING — that must never be read as "the user
    /// deleted every workout". Nothing is deleted while the lookup is unhealthy.
    func testUnhealthyLookupNeverDeletes() {
        let a = anchor(workout: UUID(), media: 1)
        let actions = WatchWorkoutReconciler.maintain(
            anchors: [a], sources: [:], candidates: [], lookupHealthy: false)
        XCTAssertTrue(actions.isEmpty)
    }

    /// Our own recordings are dropped — the tracked session owns that data.
    func testOwnSourceAnchorIsDeleted() {
        let wk = UUID()
        let a = anchor(workout: wk, media: 2)
        let own = WatchWorkoutReconciler.WorkoutSource(
            name: "Snappet", bundleID: "com.snappet.app.watchkitapp", productType: "Watch6,9")
        let actions = WatchWorkoutReconciler.maintain(
            anchors: [a], sources: [wk: own], lookupHealthy: true)
        XCTAssertEqual(actions, [.delete(sessionID: a.sessionID)])
    }

    /// Duplicate anchors of one workout collapse to the most-media keeper, which is then stamped.
    func testDuplicateAnchorsCollapseToMostMedia() {
        let wk = UUID()
        let keeper = anchor(workout: wk, media: 3)
        let dupe = anchor(workout: wk, media: 1)
        let actions = WatchWorkoutReconciler.maintain(
            anchors: [dupe, keeper], sources: [wk: watchSource], lookupHealthy: true)
        XCTAssertTrue(actions.contains(.delete(sessionID: dupe.sessionID)))
        XCTAssertTrue(actions.contains(.stampSource(sessionID: keeper.sessionID, source: watchSource)))
        XCTAssertEqual(actions.count, 2)
    }

    // MARK: ordering — oldest first (chronological back-fill)

    func testMintsAreOldestFirst() {
        let older = workout(name: "A", startOffset: 0, minutes: 20)
        let newer = workout(name: "B", startOffset: 5 * 60 * 60, minutes: 20)
        let actions = WatchWorkoutReconciler.plan(
            workouts: [newer, older],   // supplied newest-first
            anchoredSessionByUUID: [:], existingMediaBySession: [:],
            candidatesByWorkout: [older.workoutUUID: [candidate("a")],
                                  newer.workoutUUID: [candidate("b")]],
            gymSessionIntervals: [])
        guard case let .mint(first, _) = actions.first else { return XCTFail("expected mints") }
        XCTAssertEqual(first.displayName, "A", "older workout mints first")
    }
}

/// The label the History row / detail header shows for an imported session (prompt 129). The old
/// `isFromAppleWatch` was just "came from HealthKit", which is how a Google Health workout ended
/// up badged ⌚ on a real device.
@MainActor
final class ImportSourceLabelTests: XCTestCase {

    private func imported(name: String, product: String) -> WorkoutSession {
        let s = WorkoutSession(routineName: "Climbing", completedAt: .now,
                               healthKitWorkoutUUID: UUID())
        s.importSourceName = name
        s.importSourceProductType = product
        return s
    }

    func testWatchRecordingReadsAsAppleWatch() {
        let s = imported(name: "Apple Watch", product: "Watch6,9")
        XCTAssertTrue(s.isFromAppleWatch)
        XCTAssertEqual(s.importSourceLabel, "Apple Watch")
    }

    /// The reported bug, in one assertion.
    func testPhoneWrittenWorkoutIsNotClaimedAsAWatchRecording() {
        let s = imported(name: "Google Health", product: "iPhone14,3")
        XCTAssertFalse(s.isFromAppleWatch, "an iPhone-written workout is not a Watch recording")
        XCTAssertTrue(s.isImportedFromHealth, "it IS an import, so it stays out of tracked history")
        XCTAssertEqual(s.importSourceLabel, "Google Health")
    }

    /// A pre-129 row has no stored provenance: it must degrade to neutral, never assert a device.
    func testUnknownProvenanceDegradesToNeutralHealth() {
        let s = imported(name: "", product: "")
        XCTAssertFalse(s.isFromAppleWatch)
        XCTAssertEqual(s.importSourceLabel, "Health")
    }

    func testTrackedSessionIsNeitherImportedNorWatch() {
        let s = WorkoutSession(routineName: "Quick session", completedAt: .now)
        XCTAssertFalse(s.isImportedFromHealth)
        XCTAssertFalse(s.isFromAppleWatch)
    }
}
