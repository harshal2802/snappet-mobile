import Foundation
import SwiftData

// Deleting a session must take its dependents with it (prompt 125).
//
// The suite links tables with plain UUID FKs — no SwiftData relationships, so NOTHING cascades.
// Wardrobe already learned this (`WardrobePhotoStore.deleteAll(forItem:)` before the item delete);
// sessions had not: deleting a gym/Kilter session from History left its `SessionMedia`,
// `StudioProject` and festival rows behind forever. The feeds filter orphans at read time, so the
// bug was invisible on screen — but the store grew garbage on every delete, and a deleted
// watch-imported workout RESURRECTED on the next reconcile (nothing remembered it was deleted).

/// Deleted watch-import anchors, remembered so `WatchWorkoutImportService.reconcile` never
/// re-mints them. UserDefaults-backed like the reconcile watermark (device-local bookkeeping,
/// not user data — deliberately outside SwiftData/backup).
enum WatchImportTombstones {
    static let key = "watchImport.deletedWorkoutUUIDs"
    /// The suite UI-test launches write to instead of `.standard` (prompt 133).
    static let uiTestSuiteName = "uitest.watchImport"

    /// Where tombstones live for THIS launch.
    ///
    /// A UI test runs against an in-memory store, so its deletes are throwaway — but tombstones are
    /// UserDefaults, which the in-memory swap does NOT isolate. A test that deleted an imported
    /// session would therefore write a REAL tombstone and permanently exclude that workout from the
    /// user's actual app, long after the test store evaporated. Under `-uiTestFreshStore` they go to
    /// a scratch suite instead; the shipped app is unaffected (`.standard`, as before).
    static var store: UserDefaults {
        guard ProcessInfo.processInfo.arguments.contains("-uiTestFreshStore"),
              let suite = UserDefaults(suiteName: uiTestSuiteName) else { return .standard }
        return suite
    }

    static func all(defaults: UserDefaults = WatchImportTombstones.store) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func record(_ uuid: UUID, defaults: UserDefaults = WatchImportTombstones.store) {
        var uuids = all(defaults: defaults)
        guard uuids.insert(uuid).inserted else { return }
        defaults.set(uuids.map(\.uuidString).sorted(), forKey: key)
    }
}

/// The one way to delete a session row: sweep the dependents FIRST, then the session.
@MainActor
enum SessionCascade {

    /// Delete a gym/dance `WorkoutSession` and everything hanging off its id: `SessionMedia`,
    /// `StudioProject`, `FestivalAttendance`, `FestivalClipTag`. A watch-imported anchor also
    /// records a tombstone so the reconciler never re-mints it. Does NOT save — callers batch
    /// deletes (clear-all) and save once.
    ///
    /// `FeedActivity` rows are deliberately left alone: that log is append-only by design and the
    /// Recap feed derives its cards from live sessions, so an orphan activity row is dormant.
    static func deleteWorkoutSession(_ session: WorkoutSession, in context: ModelContext,
                                     defaults: UserDefaults = WatchImportTombstones.store) {
        if let watchUUID = session.healthKitWorkoutUUID {
            WatchImportTombstones.record(watchUUID, defaults: defaults)
        }
        sweepShared(sessionID: session.id, in: context)
        let sid = session.id
        for row in fetch(FetchDescriptor<FestivalAttendance>(
            predicate: #Predicate { $0.sessionID == sid }), in: context) { context.delete(row) }
        for row in fetch(FetchDescriptor<FestivalClipTag>(
            predicate: #Predicate { $0.sessionID == sid }), in: context) { context.delete(row) }
        context.delete(session)
    }

    /// Delete a `KilterSession` and its media/studio dependents (Kilter clips ride the same
    /// `SessionMedia` table, keyed by the Kilter session's id). Does NOT save — see above.
    static func deleteKilterSession(_ session: KilterSession, in context: ModelContext) {
        sweepShared(sessionID: session.id, in: context)
        context.delete(session)
    }

    private static func sweepShared(sessionID: UUID, in context: ModelContext) {
        for row in fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sessionID }), in: context) { context.delete(row) }
        for row in fetch(FetchDescriptor<StudioProject>(
            predicate: #Predicate { $0.sessionID == sessionID }), in: context) { context.delete(row) }
    }

    private static func fetch<M: PersistentModel>(_ descriptor: FetchDescriptor<M>,
                                                  in context: ModelContext) -> [M] {
        (try? context.fetch(descriptor)) ?? []
    }
}
