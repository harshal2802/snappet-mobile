import SwiftUI

/// Add or edit a chore (wireframe frame 3): effort, how it repeats, who does it. "Lean toward lighter
/// share" and photo proof belong to later phases.
struct ChoreEditorSheet: View {
    let chore: Chore?
    let members: [HouseholdMember]
    let me: UUID
    var archive: (() -> Void)?
    let save: (ChoreFields) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var emoji = "🧹"
    @State private var room = ""
    @State private var effort: ChoreEffort = .s
    @State private var mode: RepeatMode = .weekly
    @State private var weekdays: Set<Int> = [2]
    @State private var everyDays = 14
    @State private var who: Who = .rotate
    @State private var fixedMember: UUID?

    enum RepeatMode: String, CaseIterable, Identifiable {
        case daily = "Daily", weekdays = "Days", weekly = "Weekly", afterDone = "After done", once = "Once"
        var id: String { rawValue }
    }

    enum Who: String, CaseIterable, Identifiable {
        case rotate = "Rotate", fixed = "One person", grabs = "Up for grabs"
        var id: String { rawValue }
    }

    static let rooms = ["Kitchen", "Bathroom", "Living room", "Bedroom", "Laundry", "Outside"]
    static let emojis = ["🧹", "🍽️", "🗑️", "🧺", "🧊", "🛁", "🌿", "🛏️", "🪟", "🐾", "🛒", "🧽"]

    init(chore: Chore?, members: [HouseholdMember], me: UUID, archive: (() -> Void)? = nil,
         save: @escaping (ChoreFields) -> Void) {
        self.chore = chore
        self.members = members
        self.me = me
        self.archive = archive
        self.save = save
        guard let chore else { return }
        _name = State(initialValue: chore.name)
        _emoji = State(initialValue: chore.emoji)
        _room = State(initialValue: chore.room)
        _effort = State(initialValue: chore.effort)
        switch chore.repeats {
        case .daily: _mode = State(initialValue: .daily)
        case .weekdays(let d): _mode = State(initialValue: .weekdays); _weekdays = State(initialValue: d)
        case .weekly: _mode = State(initialValue: .weekly)
        case .afterDone(let n): _mode = State(initialValue: .afterDone); _everyDays = State(initialValue: n)
        case .once: _mode = State(initialValue: .once)
        }
        switch chore.assignment {
        case .rotate: _who = State(initialValue: .rotate)
        case .fixed(let m): _who = State(initialValue: .fixed); _fixedMember = State(initialValue: m)
        case .upForGrabs: _who = State(initialValue: .grabs)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Menu {
                            ForEach(Self.emojis, id: \.self) { e in Button(e) { emoji = e } }
                        } label: {
                            Text(emoji).font(.title2).frame(width: 36)
                        }
                        .accessibilityLabel("Icon")
                        TextField("Chore name", text: $name)
                            .accessibilityIdentifier("household.editor.name")
                    }
                    Picker("Room", selection: $room) {
                        Text("Anywhere").tag("")
                        ForEach(Self.rooms, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Effort") {
                    Picker("Effort", selection: $effort) {
                        ForEach(ChoreEffort.allCases, id: \.self) { e in Text("\(e.label) · \(e.hint)").tag(e) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Repeats", selection: $mode) {
                        ForEach(RepeatMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("household.editor.repeats")
                    switch mode {
                    case .weekdays:
                        WeekdayToggles(selection: $weekdays)
                    case .afterDone:
                        Stepper("Every \(everyDays) days", value: $everyDays, in: 1...365)
                    default:
                        EmptyView()
                    }
                } header: {
                    Text("Repeats")
                } footer: {
                    if mode == .afterDone {
                        Text("Counts from the last time anyone did it, which suits fridges, sheets and filters better than fixed dates.")
                    }
                }

                Section {
                    Picker("Who does it", selection: $who) {
                        ForEach(Who.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if who == .fixed, members.count > 1 {
                        Picker("Person", selection: Binding(get: { fixedMember ?? me }, set: { fixedMember = $0 })) {
                            ForEach(members) { m in Text(m.id == me ? "You" : m.name).tag(m.id) }
                        }
                    }
                } header: {
                    Text("Who does it")
                } footer: {
                    if members.count <= 1 && who != .grabs {
                        Text("It's yours for now. Rotation will include everyone once others join the household.")
                    }
                }

                if let archive {
                    Section {
                        Button("Archive chore", role: .destructive) {
                            archive()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(chore == nil ? "New chore" : "Edit chore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(chore == nil ? "Add" : "Save") {
                        save(fields)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("household.editor.save")
                }
            }
        }
    }

    private var fields: ChoreFields {
        let repeats: ChoreRepeat
        switch mode {
        case .daily: repeats = .daily
        case .weekdays: repeats = weekdays.isEmpty ? .daily : .weekdays(weekdays)
        case .weekly: repeats = .weekly
        case .afterDone: repeats = .afterDone(days: everyDays)
        case .once: repeats = .once
        }
        let assignment: ChoreAssignment
        switch who {
        case .rotate:
            // Keep an existing rotation's order; a new one starts with everyone, you first.
            if case .rotate(let order)? = chore?.assignment, !order.isEmpty {
                assignment = .rotate(order)
            } else {
                assignment = .rotate([me] + members.map(\.id).filter { $0 != me })
            }
        case .fixed: assignment = .fixed(fixedMember ?? me)
        case .grabs: assignment = .upForGrabs
        }
        return ChoreFields(name: name.trimmingCharacters(in: .whitespaces), emoji: emoji, room: room,
                           effort: effort, repeats: repeats, assignment: assignment)
    }
}

/// Seven day toggles in the calendar's week order.
struct WeekdayToggles: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let cal = Calendar.current
        let days = (1...7).sorted { ChoreSchedule.weekdayOrder($0, cal) < ChoreSchedule.weekdayOrder($1, cal) }
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { d in
                let on = selection.contains(d)
                Button {
                    if on { selection.remove(d) } else { selection.insert(d) }
                } label: {
                    Text(cal.veryShortWeekdaySymbols[d - 1])
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(on ? SnappetColor.household : SnappetColor.surfaceMuted, in: Circle())
                        .foregroundStyle(on ? Color.black.opacity(0.8) : SnappetColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cal.weekdaySymbols[d - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The week's house goal: a number of chores and something to look forward to.
struct HouseholdGoalSheet: View {
    let current: HouseholdGoal?
    let save: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target: Int
    @State private var reward: String

    init(current: HouseholdGoal?, save: @escaping (Int, String) -> Void) {
        self.current = current
        self.save = save
        _target = State(initialValue: current?.target ?? 20)
        _reward = State(initialValue: current?.reward ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("\(target) chores this week", value: $target, in: 1...200)
                        .accessibilityIdentifier("household.goal.target")
                } footer: {
                    Text("Every chore done this week counts, whoever does it. One chore done twice counts once.")
                }
                Section("Reward") {
                    TextField("e.g. Pizza night", text: $reward)
                        .accessibilityIdentifier("household.goal.reward")
                }
            }
            .navigationTitle("House goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(target, reward.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .accessibilityIdentifier("household.goal.save")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
