import SwiftUI

/// The Habit mini-app: daily streak tracker. Vends its descriptor to the App Library
/// and routes to `HabitRootView`. Marking a habit done logs to `SnappetCore` so the
/// Home dashboard can aggregate habit activity alongside the rest of the suite.
enum HabitModule {
    @MainActor
    static var module: AppModule {
        AppModule(
            id: "habit",
            title: "Habits",
            subtitle: "Daily streaks",
            systemImage: "checkmark.seal",
            tint: .green,
            category: .productivity
        ) { HabitRootView() }
    }
}
