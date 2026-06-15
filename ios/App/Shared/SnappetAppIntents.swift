import AppIntents
import WidgetKit

/// Siri / Shortcuts App Intents (#81 Phase 3). They reuse Phase 2's cross-process channels rather
/// than inventing new ones: `CheckOffHabitIntent` runs OFF-PROCESS and writes the `WidgetOutbox` the
/// app reconciles; the "open-app-and-act" intents set `openAppWhenRun = true`, enqueue a typed
/// `PendingAppAction` to the App-Group `AppActionInbox`, and the app drains + dispatches it through the
/// existing `SuiteRouter` deep-link plumbing. In `Shared/` so the app's `AppShortcutsProvider` and the
/// widget can both reference them. (Swift 6: `static` metadata is `let`, not `var`.)

/// The mini-apps a "open app" shortcut can target. AppEnum so it's a Shortcuts picker.
enum ModuleChoice: String, AppEnum {
    case pomodoro, habits, journal, gymTracker, workoutReels, kilter, budget, splitExpenses, tip

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Snappet App"
    static let caseDisplayRepresentations: [ModuleChoice: DisplayRepresentation] = [
        .pomodoro: "Pomodoro",
        .habits: "Habits",
        .journal: "Journal",
        .gymTracker: "Gym Tracker",
        .workoutReels: "Workout Reels",
        .kilter: "Kilter Board",
        .budget: "Budget",
        .splitExpenses: "Split Expenses",
        .tip: "Tip Calculator",
    ]

    /// The `SuiteRouter`/`ModuleRegistry` module id.
    var moduleID: String {
        switch self {
        case .pomodoro: return "pomodoro"
        case .habits: return "habit"
        case .journal: return "journal"
        case .gymTracker: return "workout-log"   // WorkoutTrackerModule.id (display "Gym Tracker", #74)
        case .workoutReels: return "workout"
        case .kilter: return "kilter"
        case .budget: return "budget"
        case .splitExpenses: return "expense"
        case .tip: return "tip"
        }
    }
}

/// "Start a focus timer" (the #81 AC). Opens the app; the drained action starts the app-owned timer.
struct StartPomodoroIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Focus Timer"
    static let description = IntentDescription("Start a Pomodoro focus session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppActionInbox.enqueue(.startPomodoro)
        return .result()
    }
}

/// Check a habit off for today — WITHOUT opening the app (reuses the Phase-2 outbox; the app
/// reconciles into SwiftData, and the reconcile logs the UsageRecord that advances the streak).
struct CheckOffHabitIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Off a Habit"
    static let description = IntentDescription("Mark a habit done for today.")
    static let openAppWhenRun = false

    @Parameter(title: "Habit")
    var habit: HabitEntity

    init() {}
    init(habit: HabitEntity) { self.habit = habit }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        WidgetOutbox.append(HabitToggle(habitID: habit.id, day: day, desired: true, requestedAt: now))
        // Optimistic snapshot update (today-resolved) so any widget reflects it immediately.
        if var snap = WidgetSnapshotStore.read()?.resolvedForDisplay(now: now) {
            snap.habits = snap.habits.map { item in
                guard item.id == habit.id else { return item }
                var updated = item
                updated.doneToday = true
                return updated
            }
            snap.generatedAt = now
            WidgetSnapshotStore.write(snap)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: "Checked off \(habit.name).")
    }
}

/// Open a chosen mini-app.
struct OpenModuleIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a Snappet App"
    static let description = IntentDescription("Jump straight to one of Snappet's apps.")
    static let openAppWhenRun = true

    @Parameter(title: "App")
    var module: ModuleChoice

    init() {}
    init(module: ModuleChoice) { self.module = module }

    func perform() async throws -> some IntentResult {
        AppActionInbox.enqueue(.openModule(module.moduleID))
        return .result()
    }
}

/// Capture a quick journal entry (optionally dictated), then open it.
struct QuickJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Journal Entry"
    static let description = IntentDescription("Jot a quick journal note.")
    static let openAppWhenRun = true

    @Parameter(title: "Note", requestValueDialog: "What's on your mind?")
    var text: String?

    init() {}
    init(text: String?) { self.text = text }

    func perform() async throws -> some IntentResult {
        AppActionInbox.enqueue(.quickJournal(text))
        return .result()
    }
}

/// Open the gym tracker to start a workout. (Auto-launching a specific named routine is a follow-up —
/// it needs the workout player's start path; recorded in decisions.md.)
struct StartRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Workout"
    static let description = IntentDescription("Open the gym tracker to start a routine.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        AppActionInbox.enqueue(.startRoutine)
        return .result()
    }
}
