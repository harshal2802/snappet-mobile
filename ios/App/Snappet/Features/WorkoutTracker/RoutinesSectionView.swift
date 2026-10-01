import SwiftUI

/// The Routines section: starter routines + the user's own, grouped. Tapping a routine pushes
/// its detail (where it can be started or edited); swipe to delete. Lives in the App Library's
/// NavigationStack.
struct RoutinesSectionView: View {
    let routines: [Routine]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let open: (Routine) -> Void
    let start: (Routine) -> Void
    let deleteRoutine: (Routine) -> Void
    let newRoutine: () -> Void
    /// Bring a routine in from a QR code / a photo of one (prompt 138).
    var scanRoutine: () -> Void = {}
    var importPhoto: () -> Void = {}
    /// Scheduled routines (prompt 136) — the Up next card renders only when this is non-empty.
    var scheduleInputs: [ScheduledRoutineInput] = []
    var skip: (UUID, DayKey) -> Void = { _, _ in }
    var skipSlot: (UUID, SlotKey) -> Void = { _, _ in }

    private var mine: [Routine] { routines.filter { !$0.isStarter } }
    private var starters: [Routine] {
        routines.filter(\.isStarter).sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if routines.isEmpty {
                ContentUnavailableView {
                    Label("No routines", systemImage: "list.bullet.rectangle.portrait")
                } description: {
                    Text("Build a routine from the exercise catalog, or scan one a friend shares.")
                } actions: {
                    Button("New Routine") { newRoutine() }.buttonStyle(.borderedProminent)
                    Button { scanRoutine() } label: { Label("Scan QR Code", systemImage: "qrcode.viewfinder") }
                        .accessibilityIdentifier("routines.empty.scan")
                    Button { importPhoto() } label: { Label("Import from Photos", systemImage: "photo.on.rectangle") }
                        .accessibilityIdentifier("routines.empty.photos")
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if !scheduleInputs.isEmpty {
                // TimelineView so "today" / missed / the kicker roll over without another data change.
                TimelineView(.everyMinute) { ctx in
                    let upNext = RoutineReminderPlanner.upNext(scheduleInputs, now: ctx.date)
                    RoutineUpNextCard(upNext: upNext,
                                      week: RoutineReminderPlanner.week(scheduleInputs, now: ctx.date),
                                      routine: upNext.flatMap { u in routines.first { $0.id == u.routineID } },
                                      start: start, skip: skip, skipSlot: skipSlot)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }
            if !mine.isEmpty {
                Section("My Routines") {
                    ForEach(mine) { routine in
                        Button { open(routine) } label: { RoutineRow(routine: routine, resolver: resolver) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("routineRow")
                            // Start + Delete both live on the trailing edge: a leading (left→right)
                            // swipe is the system back gesture here (this list is the module's root in
                            // the App Library's NavigationStack), so a leading action fought it and
                            // popped the user out to the App Library instead of revealing Start.
                            .swipeActions(edge: .trailing) { deleteButton(routine); startButton(routine) }
                            .contextMenu { startButton(routine); deleteButton(routine) }
                    }
                }
            }
            if !starters.isEmpty {
                Section("Starter Routines") {
                    ForEach(starters) { routine in
                        Button { open(routine) } label: { RoutineRow(routine: routine, resolver: resolver) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("routineRow")
                            // Start + Delete both live on the trailing edge: a leading (left→right)
                            // swipe is the system back gesture here (this list is the module's root in
                            // the App Library's NavigationStack), so a leading action fought it and
                            // popped the user out to the App Library instead of revealing Start.
                            .swipeActions(edge: .trailing) { deleteButton(routine); startButton(routine) }
                            .contextMenu { startButton(routine); deleteButton(routine) }
                    }
                }
            }
        }
    }

    private func startButton(_ routine: Routine) -> some View {
        Button { start(routine) } label: { Label("Start", systemImage: "play.fill") }
            .tint(SnappetColor.workout)
            .disabled(routine.exercises.isEmpty)
    }

    private func deleteButton(_ routine: Routine) -> some View {
        Button(role: .destructive) { deleteRoutine(routine) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// One routine list row: name, sport/level chips, and an exercise-count summary.
struct RoutineRow: View {
    let routine: Routine
    let resolver: ExerciseResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let sport = routine.sport, sport != .general {
                    Image(systemName: sport.symbol).foregroundStyle(SnappetColor.workout)
                }
                Text(routine.name).font(.headline).lineLimit(1)
                if let schedule = routine.schedule, schedule.isEnabled {
                    ScheduleChip(schedule: schedule)
                }
            }
            HStack(spacing: 6) {
                Text("\(routine.exercises.count) exercises · \(routine.totalSets) sets")
                if let level = routine.level {
                    Text("·"); Text(level.display)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !routine.exercises.isEmpty {
                Text(routine.exercises.prefix(3)
                    .map { resolver.name(for: $0.exerciseId, override: $0.displayName) }
                    .joined(separator: ", ") + (routine.exercises.count > 3 ? "…" : ""))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The small "📅 M W F" chip on a scheduled routine's row (prompt 136).
struct ScheduleChip: View {
    let schedule: RoutineSchedule
    private let calendar = Calendar.current

    private var text: String {
        switch schedule.repeatRule {
        case .weekly(let days, let every) where days.count == 7:
            return every > 1 ? "Daily · \(every)w" : "Daily"
        case .weekly(let days, let every):
            let letters = RoutineSchedule.orderedWeekdays(calendar).filter(days.contains)
                .map { calendar.veryShortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
            return every > 1 ? "\(letters) · \(every)w" : letters
        case .everyDays(let n): return n == 1 ? "Daily" : "Every \(n)d"
        case .once: return schedule.startDay.date(calendar: calendar).formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// "Daily · 7×" when there are several sessions a day (prompt 144).
    private var fullText: String {
        guard schedule.isMultiSlot, let n = schedule.daily?.slotTimes.count else { return text }
        return "\(text) · \(n)×"
    }

    var body: some View {
        Label(fullText, systemImage: "calendar")
            .font(.caption2.weight(.bold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(SnappetColor.workout.opacity(0.18), in: Capsule())
            .foregroundStyle(SnappetColor.workout)
            .lineLimit(1)
            .accessibilityLabel("Scheduled \(schedule.summary(calendar: calendar))")
    }
}
