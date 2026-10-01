import Foundation
import SwiftData

/// How the Schedule editor wants the routine tied to Habits (prompt 137).
enum HabitLinkChoice: Hashable, Sendable {
    case none
    /// Create a habit named after the routine.
    case newHabit
    /// Tick off an existing habit (several routines may share one, e.g. "Gym").
    case existing(UUID)
}

/// The SwiftData edge of the routine ↔ habit link (prompt 137). The link lives on the routine
/// (`Routine.linkedHabitID`), so one habit can be fed by several routines and unlinking never touches
/// the habit's history.
@MainActor
enum HabitRoutineLink {
    static let defaultSymbol = "dumbbell.fill"

    static func linkedHabit(for routine: Routine, in context: ModelContext) -> Habit? {
        guard let id = routine.linkedHabitID else { return nil }
        return try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first
    }

    /// Apply the editor's choice. Returns the habit now linked (nil when unlinked).
    @discardableResult
    static func apply(_ choice: HabitLinkChoice, to routine: Routine, in context: ModelContext,
                      core: SnappetCore?) -> Habit? {
        switch choice {
        case .none:
            routine.linkedHabitID = nil
            return nil
        case .existing(let id):
            routine.linkedHabitID = id
            return try? context.fetch(FetchDescriptor<Habit>(predicate: #Predicate { $0.id == id })).first
        case .newHabit:
            // Always a fresh habit: a routine that's already linked arrives here as `.existing`.
            let habit = Habit(name: routine.name, symbol: defaultSymbol)
            context.insert(habit)
            routine.linkedHabitID = habit.id
            core?.log(module: "habit", action: "create", summary: "Added habit: \(routine.name) (from routine)")
            return habit
        }
    }

    /// A session of `routine` was completed on `day` → tick its habit off (idempotent).
    static func markDone(routine: Routine, day: Date, in context: ModelContext, core: SnappetCore?) {
        guard let habit = linkedHabit(for: routine, in: context) else { return }
        let start = Calendar.current.startOfDay(for: day)
        // Several sessions a day (prompt 144): the day counts once enough of them are done.
        let needed = routine.schedule?.sessionsForDayDone ?? 1
        if needed > 1 {
            let rid = routine.id
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
            let done = ((try? context.fetch(FetchDescriptor<WorkoutSession>(
                predicate: #Predicate { $0.routineID == rid && $0.startedAt >= start && $0.startedAt < end }))) ?? [])
                .filter { $0.completedAt != nil }.count
            guard done >= needed else { return }
        }
        let habitID = habit.id
        let existing = (try? context.fetch(FetchDescriptor<HabitCompletion>(
            predicate: #Predicate { $0.habitID == habitID && $0.day == start }))) ?? []
        guard existing.isEmpty else { return }
        context.insert(HabitCompletion(habitID: habitID, day: start))
        // Doing it un-skips it.
        habit.skippedDayKeys?.removeAll { $0 == DayKey(start).value }
        core?.log(module: "habit", action: "done", summary: "Did: \(habit.name) (workout)")
    }

    /// The routine's "Skip today" → record it on the linked habit so the streak can excuse it.
    static func recordSkip(routine: Routine, day: DayKey, in context: ModelContext) {
        guard let habit = linkedHabit(for: routine, in: context) else { return }
        var keys = Set(habit.skippedDayKeys ?? [])
        keys.insert(day.value)
        let floor = DayKey(Calendar.current.date(byAdding: .day, value: -62, to: .now) ?? .now).value
        habit.skippedDayKeys = keys.filter { $0 >= floor }.sorted()
    }

    /// Unlink every routine from `habitID` (habit deleted, or "Unlink" in the habit editor).
    static func unlinkAll(habitID: UUID, in context: ModelContext) {
        let routines = (try? context.fetch(FetchDescriptor<Routine>(
            predicate: #Predicate { $0.linkedHabitID == habitID }))) ?? []
        for r in routines { r.linkedHabitID = nil }
    }
}
