import AppIntents

/// Declares Snappet's App Shortcuts so they appear in the Shortcuts app and are sayable to Siri
/// (#81 Phase 3). Discovered in the MAIN app bundle (hence app target, not the extension); the
/// intents themselves live in `Shared/`. Each phrase must contain `\(.applicationName)`.
struct SnappetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPomodoroIntent(),
            phrases: [
                "Start a focus timer in \(.applicationName)",
                "Start a \(.applicationName) focus session",
            ],
            shortTitle: "Start Focus",
            systemImageName: "timer")
        AppShortcut(
            intent: CheckOffHabitIntent(),
            phrases: [
                "Check off a habit in \(.applicationName)",
                "Mark a \(.applicationName) habit done",
            ],
            shortTitle: "Check Off Habit",
            systemImageName: "checkmark.circle")
        AppShortcut(
            intent: QuickJournalIntent(),
            phrases: [
                "Add a journal entry in \(.applicationName)",
                "Quick journal in \(.applicationName)",
            ],
            shortTitle: "Quick Journal",
            systemImageName: "square.and.pencil")
        AppShortcut(
            intent: StartRoutineIntent(),
            phrases: [
                "Start a workout in \(.applicationName)",
            ],
            shortTitle: "Start Workout",
            systemImageName: "dumbbell")
        AppShortcut(
            intent: OpenModuleIntent(),
            phrases: [
                "Open a \(.applicationName) app",
            ],
            shortTitle: "Open App",
            systemImageName: "square.stack.3d.up")
    }
}
