import SwiftUI

/// A routine's detail (workout-redesign E4, Flow 5): its prescription as a **discipline-rhythm** of
/// type-tagged blocks — each block its discipline glyph tile + an adaptive prescription
/// line whose columns derive from the measure (strength `sets × reps`, timed `sets × hold`, climb
/// `type · grade · attempts`, run `distance`) — with a prominent Start button and an Edit action. A routine
/// that mixes a strength block + a timed circuit + a climb now reads as a colored modality rhythm, not a
/// flat reps×weight list. Pushed onto the App Library's stack.
struct RoutineDetailView: View {
    let routine: Routine
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let start: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SuiteRouter.self) private var router
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var app
    @Environment(SnappetCore.self) private var core
    @State private var editing = false
    @State private var sharing = false
    @State private var scheduling = false

    /// The disciplines present, in canonical order — drives the "mixed rhythm" summary chips.
    private var disciplines: [WorkoutDiscipline] {
        let present = Set(routine.exercises.map(\.discipline))
        return WorkoutDiscipline.allCases.filter { present.contains($0) }
    }

    var body: some View {
        List {
            Section { scheduleCard }
                .listRowBackground(SnappetColor.surface)

            if let detail = routine.detail, !detail.isEmpty {
                Section { Text(detail).font(.system(size: 14)).foregroundStyle(SnappetColor.textSecondary) }
                    .listRowBackground(SnappetColor.surface)
            }

            Section {
                ForEach(routine.exercises) { re in
                    RoutineBlockRow(item: re, resolver: resolver, unit: unit)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("\(routine.exercises.count) blocks · \(routine.totalSets) sets")
                    Spacer()
                    // The discipline rhythm: one glyph per type the routine mixes (grey since prompt 222).
                    ForEach(disciplines) { d in
                        Image(systemName: d.symbol).font(.caption2)
                    }
                }
                .snappetLabel().textCase(nil)
            }
            .listRowBackground(SnappetColor.surface)

            if routine.sport != nil || routine.level != nil || !routine.tags.isEmpty || routine.sourceLabel != nil {
                Section {
                    // An HStack, not LabeledContent { Label }: that pairing grew the row into a tall empty card.
                    if let sport = routine.sport {
                        HStack {
                            Text("Sport")
                            Spacer()
                            Image(systemName: sport.symbol).foregroundStyle(SnappetColor.textSecondary)
                            Text(sport.display).foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    if let level = routine.level { LabeledContent("Level", value: level.display) }
                    if !routine.tags.isEmpty {
                        LabeledContent("Tags", value: routine.tags.joined(separator: ", "))
                    }
                    if let label = routine.sourceLabel {
                        if let urlString = routine.sourceURL, let url = URL(string: urlString) {
                            Link(destination: url) { LabeledContent("Source", value: label) }
                        } else {
                            LabeledContent("Source", value: label)
                        }
                    }
                } header: {
                    Text("About").snappetLabel().textCase(nil)
                }
                .listRowBackground(SnappetColor.surface)
                .font(.system(size: 15))
            }
        }
        .scrollContentBackground(.hidden)
        .background(SnappetColor.paper)
        .navigationTitle(routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom) {
            Button { dismiss(); start() } label: {
                Label("Start Workout", systemImage: "play.fill")
            }
            .buttonStyle(SnappetWidePrimaryStyle())
            .padding(.horizontal).padding(.vertical, 10)
            .background(SnappetColor.paper)
            .disabled(routine.exercises.isEmpty)
        }
        .toolbar {
            // Share-via-QR (workout-redesign E6) — mirrors KilterClimbDetailView's qrcode toolbar button.
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharing = true } label: { Image(systemName: "qrcode") }
                    .accessibilityLabel("Share routine")
                    .accessibilityIdentifier("routine.share")
            }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing) {
            RoutineEditorView(routine: routine, resolver: resolver, defaultUnit: unit)
        }
        .sheet(isPresented: $scheduling) {
            RoutineScheduleEditor(routineName: routine.name, schedule: routine.schedule,
                                  habitLink: routine.linkedHabitID.map(HabitLinkChoice.existing) ?? .none) { saved, link in
                routine.schedule = saved
                HabitRoutineLink.apply(saved == nil ? .none : link, to: routine, in: context, core: core)
                try? context.save()
                RoutineScheduleSync.replan(context: context, reminders: app.routineReminders)
            }
        }
        .sheet(isPresented: $sharing) {
            // Scanning a routine here routes it through the same router one-shot the snappet:// link path
            // uses, so WorkoutHomeView shows the one import-confirm preview (one import brain). Pop this
            // detail off first so the preview surfaces on the tracker root (where the import sheet lives).
            RoutineShareView(routine: routine, onScan: { scanned in
                router.popToRoot()
                router.pendingRoutineImport = scanned
            })
        }
    }
}

extension RoutineDetailView {
    /// The Schedule card (prompt 136, wireframe frame 1): summary + reminder line + the weekday dots, or
    /// a "Set a schedule" invitation. Tapping it opens the editor.
    @ViewBuilder var scheduleCard: some View {
        let schedule = routine.schedule
        Button { scheduling = true } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: schedule == nil ? "calendar.badge.plus" : "calendar")
                    .font(.system(size: 14)).foregroundStyle(SnappetColor.ink)
                    .frame(width: 32, height: 32)
                    .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if let schedule {
                        Text(schedule.isEnabled ? "Schedule" : "Schedule · paused")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink)
                        Text(schedule.summary()).snappetDetail()
                        Text(reminderLine(schedule) + (routine.linkedHabitID != nil ? " · Tracked in Habits" : ""))
                            .font(SnappetType.label).foregroundStyle(SnappetColor.textTertiary)
                        if case .weekly(let days, _) = schedule.repeatRule {
                            ScheduleDayDots(weekdays: days).padding(.top, 6)
                        }
                    } else {
                        Text("Not scheduled").font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink)
                        Text("Set a schedule to get reminders and see it in Up next.").snappetDetail()
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SnappetColor.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("routine.schedule")
    }

    private func reminderLine(_ s: RoutineSchedule) -> String {
        guard s.reminder.isOn else { return "No reminder" }
        let lead = s.reminder.leadMinutes
        var parts = [lead == 0 ? "Reminder at start" : "Reminder \(lead) min before"]
        if let n = s.reminder.nudgeAfterMinutes { parts.append("nudge after \(n) min") }
        return parts.joined(separator: " · ")
    }
}

/// Seven small weekday dots, filled for the scheduled days, in the user's week order.
struct ScheduleDayDots: View {
    let weekdays: Set<Int>
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 5) {
            ForEach(RoutineSchedule.orderedWeekdays(calendar), id: \.self) { wd in
                let on = weekdays.contains(wd)
                Text(calendar.veryShortWeekdaySymbols[wd - 1])
                    .font(.system(size: 10.5))
                    .frame(width: 22, height: 22)
                    .background(on ? SnappetColor.brand : SnappetColor.surfaceMuted, in: Circle())
                    .foregroundStyle(on ? SnappetColor.onBrand : SnappetColor.textSecondary)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One **type-tagged block** row inside a routine detail / editor preview (workout-redesign E4). A glyph tile makes
/// the block's discipline legible at a glance; the prescription line's columns derive from the measure. Replaces
/// the strength-only `RoutineExerciseRow`.
struct RoutineBlockRow: View {
    let item: RoutineExercise
    let resolver: ExerciseResolver
    let unit: WeightUnit

    private var discipline: WorkoutDiscipline { item.discipline }

    var body: some View {
        // A neutral glyph tile like the Library / Routines rows (prompt 222; was a discipline-accent edge bar).
        HStack(spacing: 12) {
            Image(systemName: discipline.symbol).font(.system(size: 14)).foregroundStyle(SnappetColor.ink)
                .frame(width: 32, height: 32)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(resolver.name(for: item.exerciseId, override: item.displayName))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                Text(prescription + (item.restSeconds > 0 ? " · rest \(restText(item.restSeconds))" : ""))
                    .snappetDetail()
                if let notes = item.notes, !notes.isEmpty {
                    Text(notes).font(SnappetType.label).foregroundStyle(SnappetColor.textTertiary).italic()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    /// The adaptive prescription string — the columns derive from the discipline's measure.
    private var prescription: String {
        switch discipline {
        case .strength:
            var s = "\(item.sets) × \(item.reps.isEmpty ? "—" : item.reps)"
            if let weight = item.weight {
                s += " · \(WorkoutMath.setWeight(weight, enteredIn: item.weightUnit, unit: unit))"
            }
            return s
        case .climb:
            var parts: [String] = [item.climbType.label]
            if let grade = item.climbGradeLabel, !grade.isEmpty { parts.append(grade) }
            parts.append("\(item.sets) attempt\(item.sets == 1 ? "" : "s")")
            return parts.joined(separator: " · ")
        case .timed:
            if let spec = item.timedSpec, spec.mode.isStructured { return spec.sentence }
            if let hold = item.targetDurationSec, hold > 0 {
                return "\(item.sets) × \(Int(hold))s"
            }
            return "\(item.sets) × time"
        case .run:
            if let m = item.targetDistanceMeters, m > 0 {
                let du: DistanceUnit = unit == .lb ? .mi : .km
                return SetMeasure.formatDistance(m, unit: du)
            }
            return "Open run"
        case .dance, .other, .racket:
            return "\(item.sets) × time"
        }
    }
}

/// "90s" or "1m 30s" for a rest duration.
func restText(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60, s = seconds % 60
    return s == 0 ? "\(m)m" : "\(m)m \(s)s"
}
