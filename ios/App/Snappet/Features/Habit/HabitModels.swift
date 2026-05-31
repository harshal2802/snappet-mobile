import Foundation
import SwiftData

/// A habit the user wants to do every day. Keyed by a stable `id` (UUID) so
/// completions can reference it independently of the SwiftData object identity.
@Model
final class Habit {
    /// Stable identity used to key `HabitCompletion` records.
    var id: UUID
    var name: String
    /// SF Symbol name shown on the row (e.g. "drop", "book"). Defaults to a generic mark.
    var symbol: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, symbol: String = "checkmark.circle", createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.createdAt = createdAt
    }
}

/// One "done" mark for a habit on a single calendar day. We store `day` normalised to
/// the start of the day (via `Calendar.startOfDay`) so there is at most one completion
/// per habit per day and day comparisons are exact.
@Model
final class HabitCompletion {
    /// Matches `Habit.id`.
    var habitID: UUID
    /// Start-of-day for the day this habit was completed.
    var day: Date

    init(habitID: UUID, day: Date) {
        self.habitID = habitID
        self.day = day
    }
}
