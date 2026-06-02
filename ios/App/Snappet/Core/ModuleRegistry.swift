import SwiftUI

/// The single source of truth for which mini-apps exist in the suite. Each module's
/// feature folder defines a `static var module: AppModule` (see the existing Workout
/// module); they're collected here. New modules are added by appending one line.
enum ModuleRegistry {
    @MainActor
    static var all: [AppModule] {
        [
            WorkoutModule.module,
            WorkoutTrackerModule.module,
            KilterModule.module,
            PomodoroModule.module,
            HabitModule.module,
            JournalModule.module,
            TipModule.module,
            ExpenseModule.module,
            BudgetModule.module,
        ]
    }

    @MainActor
    static func modules(in category: ModuleCategory) -> [AppModule] {
        all.filter { $0.category == category }
    }
}
