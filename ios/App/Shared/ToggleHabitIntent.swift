import AppIntents
import WidgetKit

/// Interactive habit check-off from a home-screen widget (#81 Phase 2). Runs WITHOUT opening the app:
/// it records the desired state to the App-Group outbox (`WidgetOutbox`) and optimistically updates
/// the Today snapshot so the widget reflects the tap immediately; the app reconciles the outbox into
/// SwiftData on its next foreground (`HabitCheckoffReconciler`). Because it only touches App-Group
/// files (never SwiftData), it behaves identically in the widget process or the app process.
///
/// Lives in `Shared/` so it's compiled into both the widget (for `Button(intent:)`) and the app (for
/// the Phase-3 AppShortcuts that will reuse it).
struct ToggleHabitIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Off Habit"
    static let description = IntentDescription("Mark a habit done (or not done) for today.")
    /// The whole point is checking off in place — don't bring the app forward.
    static let openAppWhenRun = false

    @Parameter(title: "Habit")
    var habitID: String

    init() {}
    init(habitID: String) { self.habitID = habitID }

    func perform() async throws -> some IntentResult {
        guard let uuid = UUID(uuidString: habitID) else { return .result() }
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)

        // Resolve the snapshot to TODAY first: if the app built it before midnight, yesterday's
        // doneToday must not seed `current` (else a tap meant to check ON computes desired=false and
        // silently no-ops). resolvedForDisplay stamps today's dayStart, so the optimistic write below
        // is a fresh today-snapshot (#81 Phase 2 review fix).
        let resolved = WidgetSnapshotStore.read()?.resolvedForDisplay(now: now)
        let current = resolved?.habits.first { $0.id == uuid }?.doneToday ?? false
        let desired = !current

        // Durable intent for the app to reconcile into SwiftData on next foreground.
        WidgetOutbox.append(HabitToggle(habitID: uuid, day: day, desired: desired, requestedAt: now))

        // Optimistic snapshot update so the widget shows the new state before the app reconciles.
        if var snap = resolved {
            snap.habits = snap.habits.map { item in
                guard item.id == uuid else { return item }
                var updated = item
                updated.doneToday = desired
                return updated
            }
            snap.generatedAt = now
            WidgetSnapshotStore.write(snap)
        }

        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
