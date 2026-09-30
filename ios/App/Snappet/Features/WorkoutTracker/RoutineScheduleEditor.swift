import SwiftUI
import SwiftData
import UserNotifications

/// The routine **Schedule** sheet (prompt 136, wireframe frames 2–3): when it repeats, what time, how
/// long it runs, and how Snappet reminds you. Edits a local draft; Save hands back the composed
/// `RoutineSchedule` (or `nil` for Remove schedule) and the host persists + re-plans notifications.
struct RoutineScheduleEditor: View {
    let routineName: String
    let isNew: Bool
    /// `nil` schedule → remove it. The link choice says how the routine ties to Habits (prompt 137).
    let onSave: (RoutineSchedule?, HabitLinkChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @Query(sort: \Habit.createdAt) private var habits: [Habit]

    private enum RepeatKind: String, CaseIterable, Identifiable {
        case weekly, everyDays, once
        var id: String { rawValue }
        var label: String {
            switch self { case .weekly: "Weekly"; case .everyDays: "Every N days"; case .once: "Once" }
        }
    }
    private enum EndKind: String, CaseIterable, Identifiable {
        case never, onDate, afterSessions
        var id: String { rawValue }
        var label: String {
            switch self { case .never: "Never"; case .onDate: "On a date"; case .afterSessions: "After sessions" }
        }
    }

    private let calendar = Calendar.current
    /// Skips aren't editable here but must survive an edit.
    private let skipped: Set<DayKey>

    @State private var enabled: Bool
    @State private var kind: RepeatKind
    @State private var weekdays: Set<Int>
    @State private var everyWeeks: Int
    @State private var everyDays: Int
    @State private var sameTime: Bool
    @State private var time: Date
    @State private var perDay: [Int: Date]
    @State private var startDate: Date
    @State private var endKind: EndKind
    @State private var endDate: Date
    @State private var endCount: Int
    @State private var reminder: ScheduleReminder
    @State private var headsUpTime: Date
    @State private var notificationsDenied = false
    @State private var habitLink: HabitLinkChoice

    /// `habitLink`: the routine's current link (`.existing`), or `.none`. A brand-new schedule defaults to
    /// `.newHabit` (wireframe frame 3: Track in Habits on) unless `defaultTrackInHabits` is false.
    init(routineName: String, schedule: RoutineSchedule?, habitLink: HabitLinkChoice = .none,
         defaultTrackInHabits: Bool = true,
         onSave: @escaping (RoutineSchedule?, HabitLinkChoice) -> Void) {
        self.routineName = routineName
        self.isNew = schedule == nil
        self.onSave = onSave
        _habitLink = State(initialValue: schedule == nil && habitLink == .none && defaultTrackInHabits
                           ? .newHabit : habitLink)
        let cal = Calendar.current
        let s = schedule ?? .suggested(today: .now, calendar: cal)
        let dayOne = DayKey(value: 20_000_101)
        skipped = s.skippedDays
        _enabled = State(initialValue: s.isEnabled)
        switch s.repeatRule {
        case .weekly(let days, let every):
            _kind = State(initialValue: .weekly)
            _weekdays = State(initialValue: days)
            _everyWeeks = State(initialValue: every)
            _everyDays = State(initialValue: 2)
        case .everyDays(let n):
            _kind = State(initialValue: .everyDays)
            _weekdays = State(initialValue: [2, 4, 6])
            _everyWeeks = State(initialValue: 1)
            _everyDays = State(initialValue: n)
        case .once:
            _kind = State(initialValue: .once)
            _weekdays = State(initialValue: [2, 4, 6])
            _everyWeeks = State(initialValue: 1)
            _everyDays = State(initialValue: 2)
        }
        _sameTime = State(initialValue: s.perDayTimes.isEmpty)
        _time = State(initialValue: s.time.on(dayOne, calendar: cal))
        _perDay = State(initialValue: s.perDayTimes.mapValues { $0.on(dayOne, calendar: cal) })
        _startDate = State(initialValue: s.startDay.date(calendar: cal))
        switch s.end {
        case .never:
            _endKind = State(initialValue: .never)
            _endDate = State(initialValue: cal.date(byAdding: .month, value: 1, to: .now) ?? .now)
            _endCount = State(initialValue: 12)
        case .onDay(let d):
            _endKind = State(initialValue: .onDate)
            _endDate = State(initialValue: d.date(calendar: cal))
            _endCount = State(initialValue: 12)
        case .afterSessions(let n):
            _endKind = State(initialValue: .afterSessions)
            _endDate = State(initialValue: cal.date(byAdding: .month, value: 1, to: .now) ?? .now)
            _endCount = State(initialValue: n)
        }
        _reminder = State(initialValue: s.reminder)
        _headsUpTime = State(initialValue: (s.reminder.headsUp ?? ScheduleTime(hour: 20, minute: 0)).on(dayOne, calendar: cal))
    }

    // MARK: - Compose

    private func scheduleTime(_ date: Date) -> ScheduleTime {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return ScheduleTime(hour: c.hour ?? 7, minute: c.minute ?? 0)
    }

    private var draft: RoutineSchedule {
        var s = RoutineSchedule(startDay: DayKey(startDate, calendar: calendar))
        s.isEnabled = enabled
        switch kind {
        case .weekly: s.repeatRule = .weekly(weekdays: weekdays, everyWeeks: everyWeeks)
        case .everyDays: s.repeatRule = .everyDays(everyDays)
        case .once: s.repeatRule = .once
        }
        s.time = scheduleTime(time)
        if kind == .weekly, !sameTime {
            s.perDayTimes = Dictionary(uniqueKeysWithValues: weekdays.map { ($0, scheduleTime(perDay[$0] ?? time)) })
        }
        switch endKind {
        case .never: s.end = .never
        case .onDate: s.end = .onDay(DayKey(endDate, calendar: calendar))
        case .afterSessions: s.end = .afterSessions(endCount)
        }
        var r = reminder
        r.headsUp = reminder.headsUp == nil ? nil : scheduleTime(headsUpTime)
        s.reminder = r
        s.skippedDays = skipped
        return s
    }

    private var isValid: Bool { kind != .weekly || !weekdays.isEmpty }

    /// "Next 3" preview — the live proof the settings mean what the user thinks.
    private var nextThree: [Date] {
        let s = draft
        let today = DayKey(.now, calendar: calendar)
        return s.days(from: today, through: today.adding(days: 120, calendar: calendar), calendar: calendar)
            .map { s.startTime(on: $0, calendar: calendar) }
            .filter { $0 > .now }
            .prefix(3).map { $0 }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Scheduled", isOn: $enabled).accessibilityIdentifier("schedule.enabled")
                } footer: {
                    if !enabled { Text("Paused — your settings are kept, but nothing is planned or sent.") }
                }

                repeatSection
                timeSection
                durationSection
                notificationSection
                habitSection

                if !isNew {
                    Section {
                        Button("Remove schedule", role: .destructive) { onSave(nil, .none); dismiss() }
                            .accessibilityIdentifier("schedule.remove")
                    }
                }
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                        .accessibilityIdentifier("schedule.save")
                }
            }
            .task {
                guard !RoutineScheduleSync.isUITestLaunch else { return }
                let status = await UNUserNotificationCenterStatus.current()
                notificationsDenied = status == .denied
            }
        }
    }

    private var repeatSection: some View {
        Section {
            Picker("Repeat", selection: $kind) {
                ForEach(RepeatKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("schedule.kind")

            switch kind {
            case .weekly:
                WeekdayPicker(selection: $weekdays)
                Picker("Every", selection: $everyWeeks) {
                    ForEach(1...ScheduleRepeat.maxEveryWeeks, id: \.self) { n in
                        Text(n == 1 ? "Week" : "\(n) weeks").tag(n)
                    }
                }
                .accessibilityIdentifier("schedule.everyWeeks")
            case .everyDays:
                Stepper(value: $everyDays, in: 1...ScheduleRepeat.maxEveryDays) {
                    LabeledContent("Every", value: everyDays == 1 ? "Day" : "\(everyDays) days")
                }
                .accessibilityIdentifier("schedule.everyDays")
            case .once:
                EmptyView()
            }
        } header: {
            Text("Repeat")
        } footer: {
            if kind == .weekly, weekdays.isEmpty { Text("Pick at least one day.") }
            else if kind == .weekly, everyWeeks > 1 { Text("Alternating weeks count from the start date's week.") }
        }
    }

    private var timeSection: some View {
        Section("Time") {
            if kind == .weekly {
                Toggle("Same time every day", isOn: $sameTime).accessibilityIdentifier("schedule.sameTime")
            }
            if kind != .weekly || sameTime {
                DatePicker("Start at", selection: $time, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("schedule.time")
            } else {
                ForEach(RoutineSchedule.orderedWeekdays(calendar).filter(weekdays.contains), id: \.self) { wd in
                    DatePicker(calendar.weekdaySymbols[wd - 1],
                               selection: Binding(get: { perDay[wd] ?? time }, set: { perDay[wd] = $0 }),
                               displayedComponents: .hourAndMinute)
                }
            }
        }
    }

    private var durationSection: some View {
        Section {
            DatePicker(kind == .once ? "On" : "Starts", selection: $startDate, displayedComponents: .date)
                .accessibilityIdentifier("schedule.startDate")
            if kind != .once {
                Picker("Ends", selection: $endKind) {
                    ForEach(EndKind.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("schedule.endKind")
                switch endKind {
                case .never: EmptyView()
                case .onDate:
                    DatePicker("End date", selection: $endDate, in: startDate..., displayedComponents: .date)
                case .afterSessions:
                    Stepper(value: $endCount, in: 1...200) {
                        LabeledContent("After", value: "\(endCount) session\(endCount == 1 ? "" : "s")")
                    }
                }
            }
        } header: {
            Text(kind == .once ? "Date" : "Duration")
        } footer: {
            let next = nextThree
            Text(next.isEmpty ? "Nothing planned with these settings."
                 : "Next: " + next.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) }
                    .joined(separator: " · "))
                .accessibilityIdentifier("schedule.preview")
        }
    }

    private var notificationSection: some View {
        Section {
            Toggle("Remind me", isOn: $reminder.isOn).accessibilityIdentifier("schedule.remind")
            if reminder.isOn {
                Picker("When", selection: $reminder.leadMinutes) {
                    ForEach(ScheduleReminder.leadChoices, id: \.self) { m in
                        Text(m == 0 ? "At start time" : "\(m) min before").tag(m)
                    }
                }
                .accessibilityIdentifier("schedule.lead")
                Picker("Nudge if not started", selection: $reminder.nudgeAfterMinutes) {
                    Text("Off").tag(Int?.none)
                    ForEach(ScheduleReminder.nudgeChoices, id: \.self) { m in
                        Text(m < 60 ? "After \(m) min" : "After \(m / 60) h").tag(Int?.some(m))
                    }
                }
                .accessibilityIdentifier("schedule.nudge")
            }
            Toggle("Night-before heads-up", isOn: Binding(
                get: { reminder.headsUp != nil },
                set: { reminder.headsUp = $0 ? scheduleTime(headsUpTime) : nil }))
                .accessibilityIdentifier("schedule.headsUp")
            if reminder.headsUp != nil {
                DatePicker("At", selection: $headsUpTime, displayedComponents: .hourAndMinute)
            }
            if reminder.isOn || reminder.headsUp != nil {
                Toggle("Sound", isOn: $reminder.sound)
                Toggle("Time Sensitive", isOn: $reminder.timeSensitive)
                    .accessibilityIdentifier("schedule.timeSensitive")
            }
        } header: {
            Text("Notifications")
        } footer: {
            if notificationsDenied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications are off for Snappet, so reminders won't appear.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } else if reminder.isOn {
                Text("The nudge is cancelled once you start the routine. Time Sensitive gets through Focus modes.")
            }
        }
    }

    private var habitSection: some View {
        Section {
            Toggle("Track in Habits", isOn: Binding(
                get: { habitLink != .none },
                set: { habitLink = $0 ? .newHabit : .none }))
                .accessibilityIdentifier("schedule.trackHabit")
            if habitLink != .none {
                Picker("Habit", selection: $habitLink) {
                    Text("\(routineName) (new)").tag(HabitLinkChoice.newHabit)
                    ForEach(habits) { h in
                        Label(h.name, systemImage: h.symbol).tag(HabitLinkChoice.existing(h.id))
                    }
                }
                .accessibilityIdentifier("schedule.habitPicker")
            }
        } header: {
            Text("Habits")
        } footer: {
            if habitLink != .none {
                Text("Finishing this routine ticks the habit off. Its streak counts scheduled days only, so a rest day never breaks it.")
            }
        }
    }

    private func save() {
        let schedule = draft
        onSave(schedule, habitLink)
        if schedule.isEnabled, schedule.reminder.isOn || schedule.reminder.headsUp != nil,
           !RoutineScheduleSync.isUITestLaunch {
            let reminders = app.routineReminders
            Task { _ = await reminders.requestAuthorization() }
        }
        dismiss()
    }
}

/// Seven round day toggles in the user's week order (M T W T F S S where the week starts Monday).
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RoutineSchedule.orderedWeekdays(calendar), id: \.self) { wd in
                let on = selection.contains(wd)
                Button {
                    if on { selection.remove(wd) } else { selection.insert(wd) }
                    Haptics.tap()
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[wd - 1])
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(on ? SnappetColor.workout : Color(.tertiarySystemFill), in: Circle())
                        .foregroundStyle(on ? Color.black : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[wd - 1])
                .accessibilityValue(on ? "Selected" : "Not selected")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("schedule.day.\(wd)")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Tiny wrapper so views can read authorization without importing UserNotifications everywhere.
enum UNUserNotificationCenterStatus {
    enum Status { case notDetermined, denied, allowed }
    static func current() async -> Status {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }
}
