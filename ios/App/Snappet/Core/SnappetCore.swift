import Foundation
import SwiftData

/// Snappet Core — the shared on-device data layer (#60 §D, schema spec).
///
/// Every mini-app logs what the user did to a single `UsageRecord` table; the Home
/// dashboard aggregates across all of them to show "historical sub-app usage." This
/// is the contract that turns a bag of mini-apps into a suite whose value compounds.
/// On-device only (SwiftData / local store) — nothing is transmitted.
@Model
final class UsageRecord {
    /// The mini-app that produced this record (matches `AppModule.id`).
    var module: String
    /// A short verb for what happened (e.g. "open", "session", "export", "entry").
    var action: String
    /// Human-readable one-line summary shown in the activity feed.
    var summary: String
    /// Optional numeric the dashboard can sum/chart (minutes, dollars, reps, …).
    var metric: Double?
    var timestamp: Date

    init(module: String, action: String, summary: String,
         metric: Double? = nil, timestamp: Date = .now) {
        self.module = module
        self.action = action
        self.summary = summary
        self.metric = metric
        self.timestamp = timestamp
    }
}

/// The list of every persisted model in the shared store. Mini-apps that need their
/// own history add their `@Model` types here (one central place so the container
/// schema stays consistent). Keep `UsageRecord` first.
///
/// Adding a model? Also add its Row to `SnappetBackup` (Core/SnappetBackup.swift) so the
/// suite backup keeps covering everything — `SnappetBackupTests` fails until you do.
enum SnappetSchema {
    static let models: [any PersistentModel.Type] = [
        UsageRecord.self,
        // mini-app @Model types:
        PomodoroSession.self,
        Habit.self, HabitCompletion.self,
        JournalEntry.self,
        ExpenseGroup.self, ExpenseRecord.self,
        BudgetCategory.self, BudgetTransaction.self,
        Routine.self, WorkoutSession.self, CustomExercise.self, SessionMedia.self,
        TimedExerciseCatalog.self,
        StudioProject.self,
        TipCalculation.self,
        KilterLogEntry.self, KilterSession.self, KilterFavorite.self, KilterCreatedClimb.self,
        KilterPlan.self, KilterLitEvent.self,
        // Recap feed (F0b) — append-only activity log + interaction rows + outbox
        FeedActivity.self, FeedReaction.self, FeedSaveItem.self, FeedShareEvent.self, FeedOutboxEntry.self,
    ]
}

/// Thin wrapper over the shared `ModelContext` exposing the usage-logging API every
/// mini-app calls, plus aggregation helpers for the dashboard. Injected via the
/// environment as `@Environment(SnappetCore.self)`.
@MainActor
@Observable
final class SnappetCore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Record a usage event. Call this from any mini-app on a meaningful action.
    func log(module: String, action: String, summary: String, metric: Double? = nil) {
        context.insert(UsageRecord(module: module, action: action, summary: summary, metric: metric))
        try? context.save()
    }

    /// Most-recent records (activity feed).
    func recent(limit: Int = 40) -> [UsageRecord] {
        var d = FetchDescriptor<UsageRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    /// Records on/after `since` (for day/week aggregation).
    func records(since: Date) -> [UsageRecord] {
        let d = FetchDescriptor<UsageRecord>(
            predicate: #Predicate { $0.timestamp >= since },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(d)) ?? []
    }
}
