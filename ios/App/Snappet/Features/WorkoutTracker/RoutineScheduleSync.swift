import Foundation
import SwiftData

/// Glue between SwiftData and the pure `RoutineReminderPlanner` (prompt 136): gathers every scheduled
/// routine + its recent sessions into `ScheduledRoutineInput`s, then hands the plan to `RoutineReminders`.
/// Called whenever something that changes the plan happens — edit / start / finish / skip in the tracker,
/// and every foreground (a new day rolls the 14-day window forward).
@MainActor
enum RoutineScheduleSync {
    /// Inputs for every routine that has a schedule. `sessions` may be any superset (all sessions is fine).
    static func inputs(routines: [Routine], sessions: [WorkoutSession],
                       calendar: Calendar = .current) -> [ScheduledRoutineInput] {
        let byRoutine = Dictionary(grouping: sessions.filter { $0.routineID != nil && !$0.isImportedFromHealth },
                                   by: { $0.routineID! })
        return routines.compactMap { routine in
            guard let schedule = routine.schedule else { return nil }
            let mine = byRoutine[routine.id] ?? []
            let startDate = schedule.startDay.date(calendar: calendar)
            return ScheduledRoutineInput(
                routineID: routine.id, name: routine.name,
                blockCount: routine.exercises.count, setCount: routine.totalSets,
                schedule: schedule,
                doneDays: Set(mine.map { DayKey($0.startedAt, calendar: calendar) }),
                completedSessions: mine.filter { !$0.isActive && $0.startedAt >= startDate }.count,
                sessionStarts: mine.map(\.startedAt))
        }
    }

    /// Re-plan and apply. Skipped under UI-test launches so a test never leaves real notifications (or a
    /// permission prompt) behind — the prompt-133 rule for device-local side effects.
    static func replan(context: ModelContext, reminders: RoutineReminders, now: Date = .now) {
        guard !isUITestLaunch else { return }
        let routines = (try? context.fetch(FetchDescriptor<Routine>())) ?? []
        guard routines.contains(where: { $0.scheduleData != nil }) else {
            Task { await reminders.apply([]) }
            return
        }
        let horizonStart = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        let sessions = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.startedAt >= horizonStart }))) ?? []
        let plan = RoutineReminderPlanner.plan(inputs(routines: routines, sessions: sessions), now: now)
        Task { await reminders.apply(plan) }
    }

    /// Record "Skip today" (from the Up next card or a notification action) and re-plan.
    static func skip(routineID: UUID, day: DayKey, context: ModelContext, reminders: RoutineReminders) {
        guard let routine = try? context.fetch(FetchDescriptor<Routine>(
            predicate: #Predicate { $0.id == routineID })).first,
              var schedule = routine.schedule else { return }
        schedule.skippedDays.insert(day)
        // Keep the skip list bounded: nothing older than ~2 months matters to any view.
        let floor = DayKey(Calendar.current.date(byAdding: .day, value: -62, to: .now) ?? .now)
        schedule.skippedDays = schedule.skippedDays.filter { $0 >= floor }
        routine.schedule = schedule
        HabitRoutineLink.recordSkip(routine: routine, day: day, in: context)   // prompt 137
        try? context.save()
        Task { await reminders.clearDelivered(for: routineID) }
        replan(context: context, reminders: reminders)
    }

    /// "Skip this one" on a day with several sessions (prompt 144): skip just that slot, then re-plan.
    static func skipSlot(routineID: UUID, slot: SlotKey, context: ModelContext, reminders: RoutineReminders) {
        guard let routine = try? context.fetch(FetchDescriptor<Routine>(
            predicate: #Predicate { $0.id == routineID })).first,
              var schedule = routine.schedule else { return }
        schedule.skippedSlots.insert(slot)
        let floor = DayKey(Calendar.current.date(byAdding: .day, value: -62, to: .now) ?? .now)
        schedule.skippedSlots = schedule.skippedSlots.filter { $0.day >= floor }
        routine.schedule = schedule
        try? context.save()
        replan(context: context, reminders: reminders)
    }

    static var isUITestLaunch: Bool {
        let args = CommandLine.arguments
        return args.contains("-uiTestFreshStore") || args.contains("-uiTestCorruptStore")
            || args.contains("-uiTestSeedStudioDemo") || args.contains("-uiTestSeedRoutineHistory")
    }
}
