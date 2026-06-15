import Foundation
import SwiftData
import WidgetKit

/// Publishes the Today snapshot the home-screen widgets read (#81 Phase 1): fetch the three row
/// types from the shared store, build the snapshot (pure `WidgetSnapshotBuilder`), write it to the
/// App-Group container (`WidgetSnapshotStore`), and nudge WidgetKit to reload.
///
/// The fetch + file write are the device-dependent edge (kept thin, not unit-tested — the builder
/// and codec they wrap ARE). Cheap enough to call on every foreground/background; a no-op write
/// when the App-Group container isn't provisioned, and `reloadAllTimelines()` is a no-op when no
/// widget is installed (true through Phase 1 — the widget UI lands in Phase 2).
@MainActor
enum WidgetSnapshotService {
    static func refresh(context: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        // Don't publish during UI-test runs. The iOS Simulator DOES provision the App-Group
        // container (it just doesn't validate the group against the developer portal), so a write
        // here would persist a real `today-widget-snapshot.json` — leaking across runs and into the
        // production app on the same sim/device, defeating the in-memory-store isolation the
        // `-uiTest*` args promise. No widget reads the file during tests anyway.
        guard !isUITestLaunch else { return }
        // Apply any widget-originated check-offs (the App-Group outbox) into the canonical store
        // FIRST, so the snapshot we publish below reflects the reconciled truth (#81 Phase 2).
        reconcileOutbox(context: context, calendar: calendar)
        let records = (try? context.fetch(FetchDescriptor<UsageRecord>())) ?? []
        let habits = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        let completions = (try? context.fetch(FetchDescriptor<HabitCompletion>())) ?? []
        let focus = (try? context.fetch(FetchDescriptor<PomodoroSession>())) ?? []
        let snapshot = WidgetSnapshotBuilder.build(
            records: records, habits: habits, completions: completions, focusSessions: focus,
            now: now, calendar: calendar)
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Drain the App-Group outbox of widget check-offs and apply them to the canonical store
    /// (#81 Phase 2). The plan is pure (`HabitCheckoffReconciler`); applying is the thin SwiftData
    /// edge. Outbox files are removed ONLY after a successful save — so a save failure loses nothing
    /// and the idempotent plan safely re-applies on the next foreground.
    private static func reconcileOutbox(context: ModelContext, calendar: Calendar) {
        let toggles = WidgetOutbox.pending()
        guard !toggles.isEmpty else { return }
        let completions = (try? context.fetch(FetchDescriptor<HabitCompletion>())) ?? []
        let existing = Set(completions.map {
            HabitCheckoffReconciler.CompletionKey(habitID: $0.habitID,
                                                  day: calendar.startOfDay(for: $0.day))
        })
        let plan = HabitCheckoffReconciler.plan(toggles: toggles, existing: existing, calendar: calendar)
        guard !plan.inserts.isEmpty || !plan.deletes.isEmpty else {
            // Nothing to change (already in sync) — still clear the applied intents.
            WidgetOutbox.remove(ids: toggles.map(\.id))
            return
        }
        for key in plan.inserts {
            context.insert(HabitCompletion(habitID: key.habitID, day: key.day))
        }
        if !plan.deletes.isEmpty {
            let toDelete = Set(plan.deletes)
            for c in completions where toDelete.contains(
                HabitCheckoffReconciler.CompletionKey(habitID: c.habitID,
                                                      day: calendar.startOfDay(for: c.day))) {
                context.delete(c)
            }
        }
        do {
            try context.save()
            WidgetOutbox.remove(ids: toggles.map(\.id))   // clear only after a durable save
        } catch {
            // Keep the outbox files; the idempotent plan retries on the next foreground.
        }
    }

    /// True under the suite's UI-test launch args (the same set `SnappetApp` keys on for its
    /// in-memory store branches), so a test run never writes the shared snapshot file.
    private static var isUITestLaunch: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-uiTestFreshStore")
            || args.contains("-uiTestCorruptStore")
            || args.contains(StudioDemoSeed.argument)
    }
}
