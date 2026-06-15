import Foundation

/// Pure mapping from a drained `PendingAppAction` (Siri/Shortcuts open-app intent, #81 Phase 3) to the
/// navigation it should perform. Kept pure + in one place so the module-id literals and the one-shot
/// flags live in exactly one tested spot (not re-hardcoded in the view); `RootShell.dispatch` just
/// applies the result through `SuiteRouter`. Unit-tested in `AppActionInboxTests`.
enum AppActionRouter {
    struct Route: Equatable {
        /// The module to open (`SuiteRouter.open(module:)` / `ModuleRegistry` id).
        var moduleID: String
        /// Set `SuiteRouter.pendingPomodoroStart` before opening (start the focus timer).
        var startPomodoro: Bool = false
        /// Set `SuiteRouter.pendingJournalCompose` before opening (compose a new entry).
        var journalCompose: JournalComposeRequest? = nil
    }

    static func route(for action: PendingAppAction) -> Route {
        switch action {
        case .startPomodoro:
            return Route(moduleID: "pomodoro", startPomodoro: true)
        case .openModule(let id):
            return Route(moduleID: id)
        case .quickJournal(let text):
            return Route(moduleID: "journal", journalCompose: JournalComposeRequest(text: text))
        case .startRoutine:
            return Route(moduleID: "workout-log")   // WorkoutTrackerModule.id (#74)
        }
    }
}
