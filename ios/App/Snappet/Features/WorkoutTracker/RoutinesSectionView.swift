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
                    Button("New Routine") { newRoutine() }.buttonStyle(.snappetPrimary)
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
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }
            if !mine.isEmpty {
                Section("My routines") {
                    ForEach(mine) { routine in
                        Button { open(routine) } label: { RoutineRow(routine: routine, resolver: resolver) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("routineRow")
                            .listRowBackground(SnappetColor.surface)
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
                Section("Starter routines") {
                    ForEach(starters) { routine in
                        Button { open(routine) } label: { RoutineRow(routine: routine, resolver: resolver) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("routineRow")
                            .listRowBackground(SnappetColor.surface)
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
        .scrollContentBackground(.hidden)
        .background(SnappetColor.paper)
    }

    private func startButton(_ routine: Routine) -> some View {
        Button { start(routine) } label: { Label("Start", systemImage: "play.fill") }
            .tint(SnappetColor.brand)
            .disabled(routine.exercises.isEmpty)
    }

    private func deleteButton(_ routine: Routine) -> some View {
        Button(role: .destructive) { deleteRoutine(routine) } label: { Label("Delete", systemImage: "trash") }
    }
}

/// One routine list row (prompt 219): a neutral glyph tile, the name + an outlined schedule chip, counts · level, and
/// the first three exercises.
struct RoutineRow: View {
    let routine: Routine
    let resolver: ExerciseResolver

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: routine.sport.flatMap { $0 == .general ? nil : $0.symbol } ?? "list.bullet")
                .font(.system(size: 14)).foregroundStyle(SnappetColor.ink)
                .frame(width: 34, height: 34)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(routine.name).font(.system(size: 15.5, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                    if let schedule = routine.schedule, schedule.isEnabled {
                        ScheduleChip(schedule: schedule)
                    }
                }
                Text(Self.summary(exercises: routine.exercises.count, sets: routine.totalSets, level: routine.level?.display))
                    .snappetDetail()
                if !routine.exercises.isEmpty {
                    Text(routine.exercises.prefix(3)
                        .map { resolver.name(for: $0.exerciseId, override: $0.displayName) }
                        .joined(separator: ", ") + (routine.exercises.count > 3 ? "…" : ""))
                        .font(.system(size: 11)).foregroundStyle(SnappetColor.textTertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// "1 exercise · 1 set · Beginner" — was "1 exercises · 1 sets" (prompt 219).
    static func summary(exercises: Int, sets: Int, level: String?) -> String {
        (["\(exercises) exercise\(exercises == 1 ? "" : "s")", "\(sets) set\(sets == 1 ? "" : "s")"] + [level].compactMap { $0 })
            .joined(separator: " · ")
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
            .font(.system(size: 10.5))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(SnappetColor.hairline))
            .foregroundStyle(SnappetColor.textSecondary)
            .lineLimit(1)
            .accessibilityLabel("Scheduled \(schedule.summary(calendar: calendar))")
    }
}
