import AppIntents
import SwiftData

/// **Workout App Intents** (prompt 199) — Shortcuts, Siri, Spotlight, the Action button and other apps' automations
/// can start a Quick Session, log a set or a climb attempt, and finish the session. They live in the APP target
/// (not `Shared/`): iOS runs them in the app's own process — launching it in the background when needed — so the
/// logging intents write straight to the app's store (`WorkoutIntentService`) and an open player shows the set at once.
/// The store comes from `AppDependencyManager` (registered in `SnappetApp.init`).

/// One of your activities, as a Shortcuts picker value.
struct ActivityEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Activity"
    static let defaultQuery = ActivityEntityQuery()

    /// `LibraryEntry.raw(ActivityKey)` — stable across renames of the display title.
    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(row: LibraryCatalog.Row) {
        id = LibraryEntry.raw(row.key)
        title = row.title
        subtitle = LibraryPick.subtitle(row)
    }
}

struct ActivityEntityQuery: EntityStringQuery {
    @Dependency private var container: ModelContainer

    @MainActor
    private var rows: [LibraryCatalog.Row] { WorkoutIntentService.activities(in: container.mainContext) }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ActivityEntity] {
        let all = rows
        return identifiers.compactMap { id in all.first { LibraryEntry.raw($0.key) == id }.map(ActivityEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ActivityEntity] {
        rows.filter { $0.title.localizedStandardContains(string) }.prefix(30).map(ActivityEntity.init)
    }

    /// Your activities, most used first.
    @MainActor
    func suggestedEntities() async throws -> [ActivityEntity] {
        rows.prefix(30).map(ActivityEntity.init)
    }
}

/// A climb attempt's outcome.
enum AttemptOutcome: String, AppEnum {
    case fall, project, sent, flash
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Outcome"
    static let caseDisplayRepresentations: [AttemptOutcome: DisplayRepresentation] = [
        .fall: "Fall", .project: "Project", .sent: "Sent", .flash: "Flash",
    ]
    var status: KilterAscentStatus {
        switch self {
        case .fall: return .attempt
        case .project: return .project
        case .sent: return .sent
        case .flash: return .flash
        }
    }
}

/// "Start a Quick Session" — optionally with an activity on it. Opens the app.
struct StartQuickSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Quick Session"
    static let description = IntentDescription("Start a Quick Session in the Gym Tracker, optionally with an activity.")
    static let openAppWhenRun = true

    @Parameter(title: "Activity")
    var activity: ActivityEntity?

    init() {}

    func perform() async throws -> some IntentResult {
        AppActionInbox.enqueue(.startQuickSession(activity?.id))
        return .result()
    }
}

/// "Log a set" — on the running session (a Quick Session is started if none is). Doesn't open the app.
struct LogSetIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Set"
    static let description = IntentDescription(
        "Log a set — reps × weight, or a time / distance — on an activity in your running session. Numbers you leave out repeat your last set.")
    static let openAppWhenRun = false

    @Parameter(title: "Activity")
    var activity: ActivityEntity
    @Parameter(title: "Reps")
    var reps: Int?
    @Parameter(title: "Weight")
    var weight: Double?
    @Parameter(title: "Seconds")
    var seconds: Double?
    @Parameter(title: "Metres")
    var meters: Double?

    @Dependency private var container: ModelContainer

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$reps) × \(\.$weight) on \(\.$activity)") {
            \.$seconds
            \.$meters
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let out = try WorkoutIntentService.logSet(activity: activity.id, reps: reps, weight: weight,
                                                      seconds: seconds, meters: meters, in: container.mainContext)
            return .result(dialog: "\(out.startedSession ? "Started a Quick Session. " : "")\(out.message)")
        } catch {
            return .result(dialog: "\(Self.explain(error))")
        }
    }

    static func explain(_ error: Error) -> String {
        switch error as? WorkoutIntentService.Failure {
        case .unknownActivity(let a)?: return "Couldn't find “\(a)” in your activities."
        case .notAClimb(let a)?: return "“\(a)” isn't a climb."
        case .nothingToLog?: return "There was nothing to log — give it reps, a weight or a time."
        case nil: return "Couldn't log that."
        }
    }
}

/// "Log a climb attempt" — Fall / Project / Sent / Flash on a climb. Doesn't open the app.
struct LogClimbAttemptIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Climb Attempt"
    static let description = IntentDescription("Log an attempt on a climb, with how it went.")
    static let openAppWhenRun = false

    @Parameter(title: "Climb")
    var climb: ActivityEntity
    @Parameter(title: "Outcome", default: .fall)
    var outcome: AttemptOutcome

    @Dependency private var container: ModelContainer

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$outcome) on \(\.$climb)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let out = try WorkoutIntentService.logAttempt(climb: climb.id, outcome: outcome.status, in: container.mainContext)
            return .result(dialog: "\(out.startedSession ? "Started a Quick Session. " : "")\(out.message)")
        } catch {
            return .result(dialog: "\(LogSetIntent.explain(error))")
        }
    }
}

/// "Finish my workout" — finishes the running session the way the player's Finish does. Opens the app.
struct FinishSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Workout"
    static let description = IntentDescription("Finish the running workout session.")
    static let openAppWhenRun = true

    init() {}

    func perform() async throws -> some IntentResult {
        AppActionInbox.enqueue(.finishSession)
        return .result()
    }
}
