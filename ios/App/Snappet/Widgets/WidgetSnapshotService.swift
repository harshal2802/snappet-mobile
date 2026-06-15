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
        let habits = (try? context.fetch(FetchDescriptor<Habit>())) ?? []
        let completions = (try? context.fetch(FetchDescriptor<HabitCompletion>())) ?? []
        let focus = (try? context.fetch(FetchDescriptor<PomodoroSession>())) ?? []
        let snapshot = WidgetSnapshotBuilder.build(
            habits: habits, completions: completions, focusSessions: focus,
            now: now, calendar: calendar)
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
