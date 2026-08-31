import XCTest
import SwiftData
@testable import Snappet

/// Deleting a session must take its plain-UUID-FK dependents with it (prompt 125) — nothing
/// cascades on its own in this schema, and before the cascade existed every History delete left
/// `SessionMedia` / `StudioProject` / festival rows behind forever (and a deleted watch import
/// resurrected on the next reconcile).
@MainActor
final class SessionCascadeTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        defaults = UserDefaults(suiteName: "SessionCascadeTests")!
        defaults.removePersistentDomain(forName: "SessionCascadeTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SessionCascadeTests")
        defaults = nil
        context = nil
        container = nil
    }

    private func count<M: PersistentModel>(_ type: M.Type) -> Int {
        (try? context.fetchCount(FetchDescriptor<M>())) ?? -1
    }

    // MARK: - Workout sessions

    func testDeleteWorkoutSessionSweepsItsDependentsAndOnlyItsDependents() {
        let doomed = WorkoutSession(routineName: "Doomed")
        let kept = WorkoutSession(routineName: "Kept")
        context.insert(doomed)
        context.insert(kept)
        for s in [doomed, kept] {
            context.insert(SessionMedia(sessionID: s.id, localIdentifier: "asset-\(s.id)",
                                        kind: .video, offsetSec: 10))
            context.insert(StudioProject(sessionID: s.id))
            context.insert(FestivalAttendance(packID: "p", setID: UUID(), artist: "A",
                                              stage: "S", sessionID: s.id))
            context.insert(FestivalClipTag(packID: "p", setID: UUID(), artist: "A", stage: "S",
                                           mediaID: UUID(), sessionID: s.id, confidence: 1,
                                           reason: "test", source: .user))
        }
        try? context.save()

        SessionCascade.deleteWorkoutSession(doomed, in: context, defaults: defaults)
        try? context.save()

        XCTAssertEqual(count(WorkoutSession.self), 1)
        XCTAssertEqual(count(SessionMedia.self), 1, "only the kept session's media survives")
        XCTAssertEqual(count(StudioProject.self), 1)
        XCTAssertEqual(count(FestivalAttendance.self), 1)
        XCTAssertEqual(count(FestivalClipTag.self), 1)
    }

    /// A tracked (non-watch) session must record NO tombstone — tombstones exist purely so the
    /// watch reconciler skips deleted imports.
    func testDeleteTrackedSessionRecordsNoTombstone() {
        let session = WorkoutSession(routineName: "Tracked")
        context.insert(session)
        SessionCascade.deleteWorkoutSession(session, in: context, defaults: defaults)
        XCTAssertTrue(WatchImportTombstones.all(defaults: defaults).isEmpty)
    }

    /// The resurrection bug: a deleted watch anchor inside the reconcile look-back was simply
    /// missing from `anchoredSessionByUUID` and got re-minted on the next pass. The tombstone is
    /// what makes the delete stick.
    func testDeleteWatchImportRecordsItsTombstone() {
        let hkUUID = UUID()
        let session = WorkoutSession(routineName: "Outdoor Run", healthKitWorkoutUUID: hkUUID)
        context.insert(session)

        SessionCascade.deleteWorkoutSession(session, in: context, defaults: defaults)

        XCTAssertEqual(WatchImportTombstones.all(defaults: defaults), [hkUUID])
    }

    func testTombstonesAccumulateAndDeduplicate() {
        let a = UUID(), b = UUID()
        WatchImportTombstones.record(a, defaults: defaults)
        WatchImportTombstones.record(b, defaults: defaults)
        WatchImportTombstones.record(a, defaults: defaults)
        XCTAssertEqual(WatchImportTombstones.all(defaults: defaults), [a, b])
    }

    // MARK: - Kilter sessions

    func testDeleteKilterSessionSweepsMediaAndStudio() {
        let doomed = KilterSession(angle: 40, source: "manual")
        let kept = KilterSession(angle: 40, source: "manual")
        context.insert(doomed)
        context.insert(kept)
        for s in [doomed, kept] {
            context.insert(SessionMedia(sessionID: s.id, localIdentifier: "asset-\(s.id)",
                                        kind: .video, offsetSec: 5))
            context.insert(StudioProject(sessionID: s.id))
        }
        try? context.save()

        SessionCascade.deleteKilterSession(doomed, in: context)
        try? context.save()

        XCTAssertEqual(count(KilterSession.self), 1)
        XCTAssertEqual(count(SessionMedia.self), 1)
        XCTAssertEqual(count(StudioProject.self), 1)
    }
}

/// The "a deleted import stays deleted" round trip (prompt 133). `SessionCascadeTests` above proves
/// deleting records a tombstone; this proves the IMPORT GATE then honours it — the half that was
/// only wired, never asserted. Reconcile re-scans a 7-day look-back, so without the tombstone a
/// just-deleted workout is merely absent from the anchor map and gets re-minted on the next pass.
final class WatchImportGateTests: XCTestCase {

    private struct Fetched: Equatable {
        var uuid = UUID()
        var bundle: String? = "com.apple.health.8F3A"
    }

    private func gate(_ workouts: [Fetched], tombstones: Set<UUID>) -> [Fetched] {
        WatchWorkoutReconciler.importable(workouts, tombstones: tombstones) {
            .init(uuid: $0.uuid, sourceBundleID: $0.bundle)
        }
    }

    func testTombstonedWorkoutIsNeverReImported() {
        let deleted = Fetched(), kept = Fetched()
        let out = gate([deleted, kept], tombstones: [deleted.uuid])
        XCTAssertEqual(out, [kept], "the deleted workout must not come back on the next reconcile")
    }

    func testWithoutATombstoneTheWorkoutWouldReturn() {
        // The failure mode being guarded against: nothing else in the pipeline remembers a delete.
        let deleted = Fetched()
        XCTAssertEqual(gate([deleted], tombstones: []), [deleted])
    }

    func testOwnRecordingsAreStillRefusedByTheSameGate() {
        let own = Fetched(bundle: "com.snappet.app.watchkitapp")
        XCTAssertTrue(gate([own], tombstones: []).isEmpty)
    }

    func testTombstonesAndSourceGateCompose() {
        let deleted = Fetched(), own = Fetched(bundle: "com.snappet.app"), good = Fetched()
        XCTAssertEqual(gate([deleted, own, good], tombstones: [deleted.uuid]), [good])
    }

    /// A UI test runs against an in-memory store, but tombstones are UserDefaults — which that swap
    /// does NOT isolate. Without a scratch suite a test's delete would permanently exclude one of
    /// the user's REAL workouts from import, long after the test store evaporated.
    func testUITestLaunchesWriteTombstonesToAScratchSuite() {
        let isUITest = ProcessInfo.processInfo.arguments.contains("-uiTestFreshStore")
        if isUITest {
            XCTAssertNotEqual(WatchImportTombstones.store, .standard,
                              "a UI-test launch must not write real tombstones")
        } else {
            XCTAssertEqual(WatchImportTombstones.store, .standard,
                           "the shipped app keeps using the standard defaults")
        }
    }
}
