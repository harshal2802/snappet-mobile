import SwiftUI
import SwiftData

// MARK: - Edit lineup (prompt 232)

/// Edit an installed lineup — downloaded, scanned from a poster, or from a friend's code: delay the
/// whole day or one stage (a weather hold, a late start), fix a set's artist / stage / time, add a
/// set or a stage, remove a set, rename the festival, or reset everything to the original. Every
/// change is a `FestivalLineupEdits` overlay on the stored pack, so stars, "I'm here" stretches and
/// clip tags stay attached to their sets.
struct FestivalLineupEditView: View {
    let lineup: FestivalLineup

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var pack: FestivalPack?
    @State private var delay: FestivalDelaySheet.Request?
    @State private var editing: FestivalSetEditSheet.Request?
    @State private var renaming = false
    @State private var newName = ""
    @State private var newLocation = ""
    @State private var addingDay = false
    @State private var confirmingReset = false

    var body: some View {
        NavigationStack {
            Group {
                if let pack {
                    list(pack)
                } else {
                    ContentUnavailableView("This lineup couldn't be read",
                                           systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle("Edit lineup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("festival.edit.done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newName = lineup.name
                            newLocation = pack?.location ?? lineup.location
                            renaming = true
                        } label: { Label("Name & location", systemImage: "pencil") }
                        .accessibilityIdentifier("festival.edit.rename")
                        Button {
                            addingDay = true
                        } label: { Label("Add a day", systemImage: "calendar.badge.plus") }
                        .accessibilityIdentifier("festival.edit.addDay")
                        if let pack {
                            Button {
                                editing = .init(setID: nil, stage: "",
                                                day: pack.days.first?.date ?? "")
                            } label: { Label("Add a stage", systemImage: "plus.rectangle") }
                        }
                        Button(role: .destructive) {
                            confirmingReset = true
                        } label: { Label("Reset all edits", systemImage: "arrow.uturn.backward") }
                        .disabled(lineup.edits.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("festival.edit.menu")
                }
            }
            .alert("Name & location", isPresented: $renaming) {
                TextField("Name", text: $newName)
                TextField("Location", text: $newLocation)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let location = newLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                    mutate { edits, original in
                        if !name.isEmpty { edits.name = name == original.name ? nil : name }
                        edits.location = location == original.location ? nil : location
                    }
                }
            }
            .sheet(isPresented: $addingDay) {
                if let pack {
                    FestivalAddDaySheet(pack: pack) { date in
                        mutate { edits, _ in
                            if !edits.addedDays.contains(date) { edits.addedDays.append(date) }
                        }
                    }
                }
            }
            .confirmationDialog("Reset all edits?", isPresented: $confirmingReset,
                                titleVisibility: .visible) {
                Button("Reset to the original lineup", role: .destructive) {
                    mutate { edits, _ in edits = FestivalLineupEdits() }
                }
            } message: {
                Text("Every time change, added and removed set goes back to how the lineup was installed.")
            }
            .sheet(item: $delay) { request in
                if let pack {
                    FestivalDelaySheet(pack: pack, request: request) { moved, extended, seconds in
                        mutate { edits, original in
                            edits.shift(startAndEnd: moved, endOnly: extended, by: seconds,
                                        original: original)
                        }
                    }
                }
            }
            .sheet(item: $editing) { request in
                if let pack {
                    FestivalSetEditSheet(lineup: lineup, pack: pack, request: request) { change in
                        mutate(change)
                    }
                }
            }
        }
        .task(id: lineup.editsData) { pack = lineup.pack() }
    }

    private func list(_ pack: FestivalPack) -> some View {
        let tabs = Dictionary(FestivalSchedule.dayTabs(for: pack).map { ($0.date, $0) },
                              uniquingKeysWith: { a, _ in a })
        return List {
            Section {
                Button {
                    let now = Date()
                    let day = pack.day(containing: now)?.date ?? pack.days.first?.date ?? ""
                    delay = .init(stage: nil, day: day)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(SnappetColor.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delay the schedule").foregroundStyle(SnappetColor.ink)
                            Text("Weather hold, late start — shift every stage or one stage from a time on")
                                .font(.caption)
                                .foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                }
                .accessibilityIdentifier("festival.edit.delay")
            }
            ForEach(pack.days, id: \.date) { day in
                let label = tabs[day.date].map { "\($0.weekday.capitalized) \($0.dayNumber)" } ?? day.date
                ForEach(day.stages, id: \.name) { stage in
                    Section {
                        ForEach(stage.sets) { set in
                            setRow(set, pack: pack, day: day.date)
                        }
                        Button {
                            editing = .init(setID: nil, stage: stage.name, day: day.date)
                        } label: {
                            Label("Add a set", systemImage: "plus")
                        }
                        .tint(SnappetColor.brand)
                        .accessibilityIdentifier("festival.edit.add.\(day.date).\(stage.name)")
                    } header: {
                        HStack {
                            Text("\(label) · \(stage.name)")
                            Spacer()
                            Button("Delay this stage") {
                                delay = .init(stage: stage.name, day: day.date)
                            }
                            .font(.caption)
                            .textCase(nil)
                            .tint(SnappetColor.brand)
                            .accessibilityIdentifier("festival.edit.delayStage.\(day.date).\(stage.name)")
                        }
                    }
                }
                if day.stages.isEmpty {
                    Section("\(label)") {
                        Text("No sets this day yet").foregroundStyle(SnappetColor.textSecondary)
                        Button {
                            editing = .init(setID: nil, stage: pack.days.flatMap { $0.stages.map(\.name) }.first ?? "",
                                            day: day.date)
                        } label: {
                            Label("Add a set", systemImage: "plus")
                        }
                        .tint(SnappetColor.brand)
                        .accessibilityIdentifier("festival.edit.add.\(day.date)")
                        if lineup.edits.addedDays.contains(day.date) {
                            Button("Remove this day", role: .destructive) {
                                mutate { edits, _ in edits.addedDays.removeAll { $0 == day.date } }
                            }
                            .accessibilityIdentifier("festival.edit.removeDay.\(day.date)")
                        }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Edits sit on top of the lineup as installed: reinstalling a newer version keeps them, "
                     + "sharing the lineup or your plan sends them along, and ⋯ → Reset all edits puts "
                     + "everything back.")
            }
        }
    }

    private func setRow(_ set: FestivalSet, pack: FestivalPack, day: String) -> some View {
        let original = lineup.originalPack()
        let was = original.flatMap { lineup.edits.originalTimes(of: set.id, in: $0) }
        let isAdded = lineup.edits.added.contains { $0.id == set.id }
        return Button {
            editing = .init(setID: set.id, stage: set.stage, day: day)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(set.artist).foregroundStyle(SnappetColor.ink)
                    HStack(spacing: 4) {
                        Text(range(set, pack))
                        if let was {
                            Text("· \(FestivalLineupEdits.shiftLabel(set.start.timeIntervalSince(was.start)))")
                        } else if isAdded {
                            Text("· added")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(was != nil || isAdded ? SnappetColor.brand : SnappetColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(SnappetColor.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("festival.edit.set.\(set.artist)")
    }

    private func range(_ set: FestivalSet, _ pack: FestivalPack) -> String {
        "\(FestivalSchedule.timeLabel(set.start, offsetSeconds: pack.utcOffsetSeconds))"
            + " – \(FestivalSchedule.timeLabel(set.end, offsetSeconds: pack.utcOffsetSeconds))"
    }

    private func mutate(_ change: (inout FestivalLineupEdits, FestivalPack) -> Void) {
        guard let original = lineup.originalPack() else { return }
        var edits = lineup.edits
        change(&edits, original)
        lineup.edits = edits
        try? context.save()
        pack = lineup.pack()
    }
}

// MARK: - Add a day

/// Pick a date to add as a festival day (prompt 232) — the day after the last one by default.
struct FestivalAddDaySheet: View {
    let pack: FestivalPack
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: FestivalPosterDraftView.dayBinding($date),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                if pack.days.contains(where: { $0.date == date }) {
                    Text("That day is already in the lineup.")
                        .font(.footnote)
                        .foregroundStyle(SnappetColor.textSecondary)
                }
            }
            .navigationTitle("Add a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(date); dismiss() }
                        .disabled(date.isEmpty || pack.days.contains { $0.date == date })
                        .accessibilityIdentifier("festival.addDay.save")
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            var draft = FestivalDraft(name: "", location: "", startDate: pack.startDate,
                                      endDate: pack.endDate, utcOffsetSeconds: 0, days: [])
            draft.days = pack.days.map { .init(date: $0.date, stages: []) }
            date = draft.nextDayDate
        }
    }
}

// MARK: - Delay the schedule

/// Shift a day's sets later (or earlier): all stages or one, from a time on, by a preset or custom
/// amount. A set already playing at that time keeps its start and ends later. Shows exactly what
/// will move before applying.
struct FestivalDelaySheet: View {
    struct Request: Identifiable {
        var stage: String?
        var day: String
        var id: String { "\(day)|\(stage ?? "*")" }
    }

    let pack: FestivalPack
    let request: Request
    var onApply: (_ moved: [FestivalSet], _ extended: [FestivalSet], _ seconds: TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var stages: Set<String>?
    @State private var from = Date()
    @State private var minutes = 30
    @State private var custom = false

    private static let presets = [15, 30, 45, 60]

    var body: some View {
        let targets = FestivalLineupEdits.delayTargets(in: pack, stages: stages, from: from)
        let stageCount = Set((targets.moved + targets.extended).map(\.stage)).count
        return NavigationStack {
            Form {
                Section("Which stages") {
                    FestivalFlowChips(items: [nil] + dayStages.map(Optional.some),
                              label: { $0 ?? "All stages" },
                              selected: { $0 == nil ? stages == nil : stages == [$0!] },
                              onTap: { stages = $0.map { [$0] } })
                }
                Section {
                    DatePicker("Sets starting after", selection: $from)
                        .environment(\.timeZone, tz)
                        .accessibilityIdentifier("festival.delay.from")
                } header: {
                    Text("From")
                } footer: {
                    Text("Only this festival day moves. A set already playing ends later too.")
                }
                Section("By") {
                    FestivalFlowChips(items: Self.presets.map(Optional.some) + [nil],
                              label: { $0.map { "+\($0) min" } ?? "Custom" },
                              selected: { $0 == nil ? custom : (!custom && minutes == $0) },
                              onTap: { choice in
                                  if let choice { minutes = choice; custom = false } else { custom = true }
                              })
                    if custom {
                        Stepper(value: $minutes, in: -120...240, step: 5) {
                            Text(FestivalLineupEdits.shiftLabel(TimeInterval(minutes * 60)))
                                .monospacedDigit()
                        }
                        .accessibilityIdentifier("festival.delay.custom")
                    }
                }
                Section {
                    Text(summary(moved: targets.moved.count, extended: targets.extended.count,
                                 stages: stageCount))
                        .accessibilityIdentifier("festival.delay.summary")
                } footer: {
                    Text("Reminders re-plan; your stars, “I'm here” and clip tags stay put. Undo from Edit lineup ⋯ → Reset all edits.")
                }
            }
            .navigationTitle("Delay the schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(targets.moved, targets.extended, TimeInterval(minutes * 60))
                        dismiss()
                    }
                    .disabled(minutes == 0 || targets.moved.isEmpty && targets.extended.isEmpty)
                    .accessibilityIdentifier("festival.delay.apply")
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            stages = request.stage.map { [$0] }
            from = defaultFrom
        }
    }

    private var tz: TimeZone { TimeZone(secondsFromGMT: pack.utcOffsetSeconds) ?? .current }

    private var day: FestivalDay? { pack.days.first { $0.date == request.day } }

    private var dayStages: [String] { day?.stages.map(\.name) ?? [] }

    /// Now when the delay is today; otherwise the day's first set.
    private var defaultFrom: Date {
        let now = Date()
        if pack.day(containing: now)?.date == request.day { return now }
        return day?.allSets.map(\.start).min() ?? now
    }

    private func summary(moved: Int, extended: Int, stages: Int) -> String {
        guard moved + extended > 0 else { return "Nothing on these stages after that time." }
        let by = FestivalLineupEdits.shiftLabel(TimeInterval(minutes * 60))
        var line = "Moves \(moved) set\(moved == 1 ? "" : "s") on \(stages) stage\(stages == 1 ? "" : "s") \(by)."
        if extended > 0 { line += " \(extended) playing then end\(extended == 1 ? "s" : "") \(by) later." }
        return line
    }
}

/// A wrapping row of calm chips (never cut off — they wrap to the next line).
private struct FestivalFlowChips<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    let selected: (Item) -> Bool
    let onTap: (Item) -> Void

    var body: some View {
        FestivalWrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onTap(item)
                } label: {
                    Text(label(item)).font(.footnote)
                        .snappetPill(selected: selected(item))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("festival.chip.\(label(item))")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Minimal flow layout: rows left to right, wrapping at the proposed width.
private struct FestivalWrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - One set: edit / add

/// Change a set's artist, stage and time, or remove it — or add a new one (`setID == nil`).
struct FestivalSetEditSheet: View {
    struct Request: Identifiable {
        var setID: UUID?
        var stage: String
        var day: String
        var id: String { setID?.uuidString ?? "new|\(day)|\(stage)" }
    }

    let lineup: FestivalLineup
    let pack: FestivalPack
    let request: Request
    var onSave: ((inout FestivalLineupEdits, FestivalPack) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var artist = ""
    @State private var stage = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var confirmingRemove = false

    private var existing: FestivalSet? { request.setID.flatMap { pack.setsByID[$0] } }
    private var tz: TimeZone { TimeZone(secondsFromGMT: pack.utcOffsetSeconds) ?? .current }
    private var allStages: [String] {
        var names: [String] = []
        for name in pack.days.flatMap({ $0.stages.map(\.name) }) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Artist") {
                    TextField("Artist", text: $artist)
                        .accessibilityIdentifier("festival.setEdit.artist")
                }
                Section {
                    TextField("Stage", text: $stage)
                        .accessibilityIdentifier("festival.setEdit.stage")
                    if !allStages.isEmpty {
                        FestivalFlowChips(items: allStages, label: { $0 }, selected: { $0 == stage },
                                  onTap: { stage = $0 })
                    }
                } header: {
                    Text("Stage")
                } footer: {
                    if request.setID == nil && request.stage.isEmpty {
                        Text("Type a new stage name to add a stage.")
                    }
                }
                Section("Time") {
                    DatePicker("Starts", selection: $start)
                        .accessibilityIdentifier("festival.setEdit.start")
                    DatePicker("Ends", selection: $end, in: start...)
                        .accessibilityIdentifier("festival.setEdit.end")
                }
                .environment(\.timeZone, tz)
                if existing != nil {
                    Section {
                        Button("Remove this set", role: .destructive) { confirmingRemove = true }
                            .accessibilityIdentifier("festival.setEdit.remove")
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add a set" : "Edit set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(artist.trimmingCharacters(in: .whitespaces).isEmpty
                                  || stage.trimmingCharacters(in: .whitespaces).isEmpty
                                  || end <= start)
                        .accessibilityIdentifier("festival.setEdit.save")
                }
            }
            .confirmationDialog("Remove \(existing?.artist ?? "this set")?",
                                isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    guard let id = request.setID else { return }
                    onSave { edits, _ in edits.remove(id) }
                    dismiss()
                }
            } message: {
                Text("It leaves your schedule and plan. Reset all edits brings it back.")
            }
        }
        .onAppear(perform: seed)
    }

    private func seed() {
        if let set = existing {
            artist = set.artist
            stage = set.stage
            start = set.start
            end = set.end
            return
        }
        stage = request.stage
        // A new set starts where the stage's last set ends that day, else 18:00 festival-local.
        let day = pack.days.first { $0.date == request.day }
        let last = day?.allSets.filter { $0.stage == request.stage }.map(\.end).max()
        let evening = day?.window(utcOffsetSeconds: pack.utcOffsetSeconds)?.start
            .addingTimeInterval(12 * 3600)
        start = last ?? evening ?? Date()
        end = start.addingTimeInterval(3600)
    }

    private func save() {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let stage = stage.trimmingCharacters(in: .whitespacesAndNewlines)
        let (start, end) = (start, end)
        if let id = request.setID {
            onSave { edits, original in
                edits.update(id, artist: artist, stage: stage, start: start, end: end, original: original)
            }
        } else {
            let festivalID = pack.id
            onSave { edits, _ in
                edits.add(artist: artist, stage: stage, start: start, end: end, festivalID: festivalID)
            }
        }
        dismiss()
    }
}

// MARK: - Edit time (from a set's page)

/// A set started late or the stage is running behind: nudge this set's time (+5 / +15 / +30) or
/// set it exactly, and — on by default — carry the later sets on the same stage along by the same
/// amount. "Reset to the lineup's time" undoes this set's change.
struct FestivalEditTimeSheet: View {
    let lineup: FestivalLineup
    let setID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pack: FestivalPack?
    @State private var start = Date()
    @State private var end = Date()
    @State private var moveLater = true

    var body: some View {
        NavigationStack {
            Group {
                if let pack, let set = pack.setsByID[setID] {
                    form(pack: pack, set: set)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Edit time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(end <= start)
                        .accessibilityIdentifier("festival.editTime.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            pack = lineup.pack()
            if let set = pack?.setsByID[setID] { start = set.start; end = set.end }
        }
    }

    private func form(pack: FestivalPack, set: FestivalSet) -> some View {
        let later = FestivalLineupEdits.laterSets(after: set, in: pack)
        let delta = end.timeIntervalSince(set.end)
        let original = lineup.originalPack()
        let was = original.flatMap { lineup.edits.originalTimes(of: setID, in: $0) }
        return Form {
            Section {
                DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("festival.editTime.start")
                DatePicker("Ends", selection: $end, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("festival.editTime.end")
            } header: {
                Text("\(set.artist) · \(set.stage)")
            }
            .environment(\.timeZone, TimeZone(secondsFromGMT: pack.utcOffsetSeconds) ?? .current)
            .onChange(of: end) { _, new in
                // Past midnight: an end picked "before" the start is the next morning.
                if new <= start { end = new.addingTimeInterval(24 * 3600) }
                else if new.timeIntervalSince(start) > 24 * 3600 { end = new.addingTimeInterval(-24 * 3600) }
            }
            Section {
                HStack(spacing: 8) {
                    ForEach([5, 15, 30], id: \.self) { mins in
                        Button("+\(mins) min") {
                            start.addTimeInterval(TimeInterval(mins * 60))
                            end.addTimeInterval(TimeInterval(mins * 60))
                        }
                        .font(.subheadline)
                        .foregroundStyle(SnappetColor.ink)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .pagerOutline()
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("festival.editTime.plus\(mins)")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !later.isEmpty {
                Section {
                    Toggle(isOn: $moveLater) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Also move later sets on \(set.stage)")
                            Text("\(later.count) set\(later.count == 1 ? "" : "s")"
                                 + (delta == 0 ? "" : " · \(FestivalLineupEdits.shiftLabel(delta))"))
                                .font(.caption)
                                .foregroundStyle(SnappetColor.textSecondary)
                        }
                    }
                    .tint(SnappetColor.brand)
                    .accessibilityIdentifier("festival.editTime.moveLater")
                }
            }
            Section {
                EmptyView()
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your stars, “I'm here” and clip tags stay on this set at its new time.")
                    if let was {
                        Button("Reset to the lineup's time "
                               + "(\(FestivalSchedule.timeLabel(was.start, offsetSeconds: pack.utcOffsetSeconds))"
                               + "–\(FestivalSchedule.timeLabel(was.end, offsetSeconds: pack.utcOffsetSeconds)))") {
                            mutate { edits, _ in edits.resetTimes(setID) }
                            dismiss()
                        }
                        .tint(SnappetColor.brand)
                        .accessibilityIdentifier("festival.editTime.reset")
                    }
                }
            }
        }
    }

    private func save() {
        guard let pack, let set = pack.setsByID[setID] else { return }
        let delta = end.timeIntervalSince(set.end)
        let later = moveLater ? FestivalLineupEdits.laterSets(after: set, in: pack) : []
        let (start, end) = (start, end)
        let setID = setID
        mutate { edits, original in
            if delta != 0, !later.isEmpty {
                edits.shift(startAndEnd: later, by: delta, original: original)
            }
            edits.update(setID, start: start, end: end, original: original)
        }
        dismiss()
    }

    private func mutate(_ change: (inout FestivalLineupEdits, FestivalPack) -> Void) {
        guard let original = lineup.originalPack() else { return }
        var edits = lineup.edits
        change(&edits, original)
        lineup.edits = edits
        try? context.save()
    }
}
