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

    // Several sessions a day (prompt 144, wireframe frames 7–8).
    private enum Frequency: String, CaseIterable, Identifiable {
        case once, setTimes, every
        var id: String { rawValue }
        var label: String { switch self { case .once: "Once"; case .setTimes: "At set times"; case .every: "Every…" } }
    }
    @State private var frequency: Frequency
    @State private var setTimes: [Date]
    @State private var everyMinutes: Int
    @State private var windowFrom: Date
    @State private var windowUntil: Date
    @State private var doneAfter: Int
    private let skippedSlots: Set<SlotKey>

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
        skippedSlots = s.skippedSlots
        _doneAfter = State(initialValue: s.doneAfterSessions ?? 1)
        switch s.daily {
        case .times(let ts)?:
            _frequency = State(initialValue: .setTimes)
            _setTimes = State(initialValue: ts.sorted().map { $0.on(dayOne, calendar: cal) })
            _everyMinutes = State(initialValue: 120)
            _windowFrom = State(initialValue: ScheduleTime(hour: 8, minute: 0).on(dayOne, calendar: cal))
            _windowUntil = State(initialValue: ScheduleTime(hour: 20, minute: 0).on(dayOne, calendar: cal))
        case .every(let m, let from, let until)?:
            _frequency = State(initialValue: .every)
            _setTimes = State(initialValue: [s.time.on(dayOne, calendar: cal)])
            _everyMinutes = State(initialValue: m)
            _windowFrom = State(initialValue: from.on(dayOne, calendar: cal))
            _windowUntil = State(initialValue: until.on(dayOne, calendar: cal))
        case nil:
            _frequency = State(initialValue: .once)
            _setTimes = State(initialValue: [s.time.on(dayOne, calendar: cal),
                                             ScheduleTime(hour: (s.time.hour + 6) % 24, minute: s.time.minute).on(dayOne, calendar: cal)])
            _everyMinutes = State(initialValue: 120)
            _windowFrom = State(initialValue: ScheduleTime(hour: 8, minute: 0).on(dayOne, calendar: cal))
            _windowUntil = State(initialValue: ScheduleTime(hour: 20, minute: 0).on(dayOne, calendar: cal))
        }
    }

    private var dailyDraft: DailyRepeat? {
        switch frequency {
        case .once: return nil
        case .setTimes: return .times(setTimes.map(scheduleTime))
        case .every: return .every(minutes: everyMinutes, from: scheduleTime(windowFrom), until: scheduleTime(windowUntil))
        }
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
        if let daily = dailyDraft, daily.slotTimes.count > 1 {
            s.daily = daily
            s.perDayTimes = [:]
            // Older builds read only `time`: make it the day's first session.
            if let first = daily.slotTimes.first { s.time = first }
            s.doneAfterSessions = doneAfter > 1 ? min(doneAfter, daily.slotTimes.count) : nil
            s.skippedSlots = skippedSlots
        }
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

    @ViewBuilder private var timeSection: some View {
        frequencySection
        if frequency == .once { onceTimeSection }
    }

    /// "How often on those days?" (prompt 144). Once is the default, so existing schedules look unchanged.
    private var frequencySection: some View {
        Section {
            Picker("How often", selection: $frequency) {
                ForEach(Frequency.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("schedule.frequency")
            switch frequency {
            case .once:
                EmptyView()
            case .setTimes:
                ForEach(setTimes.indices, id: \.self) { i in
                    DatePicker("Session \(i + 1)", selection: $setTimes[i], displayedComponents: .hourAndMinute)
                }
                .onDelete { idx in if setTimes.count - idx.count >= 1 { setTimes.remove(atOffsets: idx) } }
                Button {
                    let last = setTimes.last ?? time
                    setTimes.append(calendar.date(byAdding: .hour, value: 2, to: last) ?? last)
                } label: { Label("Add time", systemImage: "plus") }
                .accessibilityIdentifier("schedule.addTime")
            case .every:
                Picker("Every", selection: $everyMinutes) {
                    ForEach(DailyRepeat.intervalChoices, id: \.self) { m in Text(Self.intervalLabel(m)).tag(m) }
                }
                .accessibilityIdentifier("schedule.everyMinutes")
                DatePicker("From", selection: $windowFrom, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("schedule.windowFrom")
                DatePicker("Until", selection: $windowUntil, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("schedule.windowUntil")
            }
        } header: {
            Text("How often on those days?")
        } footer: {
            if let daily = dailyDraft {
                let times = daily.slotTimes
                Text(times.count <= 1 ? "That's only one session — choose Once instead."
                     : "\(times.count) times a day: " + Self.preview(times, calendar: calendar))
                    .accessibilityIdentifier("schedule.slotsPreview")
            }
        }
    }

    static func intervalLabel(_ m: Int) -> String {
        if m < 60 { return "\(m) minute\(m == 1 ? "" : "s")" }
        if m % 60 == 0 { return m == 60 ? "1 hour" : "\(m / 60) hours" }
        return "\(m / 60) h \(m % 60) min"
    }

    /// "8:00 AM, 10:00 AM … 8:00 PM" — up to 5 shown, then the last.
    static func preview(_ times: [ScheduleTime], calendar: Calendar) -> String {
        let text = times.map { $0.formatted(calendar: calendar) }
        guard text.count > 6 else { return text.joined(separator: ", ") }
        return text.prefix(4).joined(separator: ", ") + " … " + (text.last ?? "")
    }

    private var onceTimeSection: some View {
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
                if (dailyDraft?.slotTimes.count ?? 1) > 1 {
                    Picker("Which sessions", selection: $reminder.everySession) {
                        Text("Every session").tag(true)
                        Text("First of the day").tag(false)
                    }
                    .accessibilityIdentifier("schedule.reminderScope")
                }
                if nudgeAllowed {
                    Picker("Nudge if not started", selection: $reminder.nudgeAfterMinutes) {
                        Text("Off").tag(Int?.none)
                        ForEach(ScheduleReminder.nudgeChoices, id: \.self) { m in
                            Text(m < 60 ? "After \(m) min" : "After \(m / 60) h").tag(Int?.some(m))
                        }
                    }
                    .accessibilityIdentifier("schedule.nudge")
                } else {
                    LabeledContent("Nudge if not started", value: "Off")
                }
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
            } else if let frequentNote {
                Text(frequentNote).accessibilityIdentifier("schedule.frequentNote")
            } else if !nudgeAllowed, reminder.isOn {
                Text("Nudges are off for sessions under an hour apart, so they don't flood the Lock Screen.")
            } else if reminder.isOn {
                Text("The nudge is cancelled once you start the routine. Time Sensitive gets through Focus modes.")
            }
        }
    }

    /// Nudges are off when sessions are less than an hour apart — they'd flood the Lock Screen.
    private var nudgeAllowed: Bool {
        guard let gap = dailyDraft?.minimumGapMinutes else { return true }
        return gap >= 60
    }

    /// iOS keeps at most 64 pending notifications per app; with this many a day, say what happens.
    private var frequentNote: String? {
        let perDay = (dailyDraft?.slotTimes.count ?? 1) * (reminder.isOn && reminder.everySession ? 1 : 0)
        guard perDay > RoutineReminderPlanner.defaultBudget / RoutineReminderPlanner.horizonDays else { return nil }
        let days = max(1, RoutineReminderPlanner.defaultBudget / max(1, perDay))
        let span = days > 1 ? "the next \(days) days" : "about the next \(max(1, RoutineReminderPlanner.defaultBudget * 24 / max(1, perDay))) hours"
        return "iPhone keeps at most 64 upcoming notifications per app, so Snappet schedules \(span) of reminders and tops them up each time you open the app."
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
                if let n = dailyDraft?.slotTimes.count, n > 1 {
                    Stepper(value: $doneAfter, in: 1...n) {
                        LabeledContent("Day counts as done after",
                                       value: doneAfter == n ? "all \(n) sessions" : "\(doneAfter) session\(doneAfter == 1 ? "" : "s")")
                    }
                    .accessibilityIdentifier("schedule.doneAfter")
                }
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
