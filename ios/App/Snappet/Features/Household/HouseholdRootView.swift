import SwiftUI
import SwiftData

/// Household root (household prompt 01; wireframe frames 1–3). Pushed into the App Library's stack.
/// Sections sit in a top segmented control: a mini-app never adds its own bottom bar.
struct HouseholdRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SnappetCore.self) private var core
    @Environment(SuiteRouter.self) private var router
    @State private var store: HouseholdStore?
    @State private var section: Section = .today
    @State private var editing: EditTarget?
    @State private var settingGoal = false
    @State private var celebrate = 0
    @State private var inviting = false
    @State private var joining: JoinTarget?
    @State private var askingHelp: Chore?
    @State private var showingPet = false
    @State private var recapWeek: RecapWeek?
    /// The last week whose recap opened by itself (prompt 03), so it shows once per new week.
    @AppStorage("household.recap.seenWeek", store: BuddyDefaults.store) private var recapSeenWeek = ""

    struct RecapWeek: Identifiable {
        var start: Date
        var id: Date { start }
    }

    enum Section: String, CaseIterable, Identifiable {
        case today = "Today", chores = "All chores", week = "Week", household = "Household"
        var id: String { rawValue }
    }

    /// The join sheet, from the Household section (scanner first) or an opened invite link.
    struct JoinTarget: Identifiable {
        var invite: HouseholdInvite?
        var id: String { invite?.token.base64URL ?? "scan" }
    }

    enum EditTarget: Identifiable {
        case new
        case chore(Chore)
        var id: String {
            switch self {
            case .new: return "new"
            case .chore(let c): return c.id.uuidString
            }
        }
    }

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Household")
        .background(SnappetColor.paper)
        .task { if store == nil { store = app.householdStore() } }
        .onChange(of: router.pendingHouseholdJoin, initial: true) { _, invite in
            guard let invite else { return }
            router.pendingHouseholdJoin = nil
            joining = JoinTarget(invite: invite)
        }
    }

    @ViewBuilder
    private func content(_ store: HouseholdStore) -> some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("household.section")

            if section == .household {
                HouseholdMembersView(store: store, service: app.householdSync,
                                     invite: { inviting = true }, join: { joining = JoinTarget(invite: nil) })
            } else if store.board.activeChores.isEmpty {
                emptyState(store)
            } else {
                switch section {
                case .today:
                    HouseholdTodayView(store: store, service: app.householdSync, setGoal: { settingGoal = true },
                                       edit: { editing = .chore($0) }, askHelp: { askingHelp = $0 },
                                       openPet: { showingPet = true }, ticked: { celebrate += 1 }, cheer: $celebrate,
                                       petCovered: showingPet)
                case .chores:
                    HouseholdChoresView(store: store, edit: { editing = .chore($0) })
                case .week:
                    HouseholdWeekView(store: store, setGoal: { settingGoal = true },
                                      recap: { recapWeek = RecapWeek(start: Self.lastWeekStart) })
                case .household:
                    EmptyView()
                }
            }
        }
        .celebrates(on: celebrate)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .new } label: { Label("Add chore", systemImage: "plus") }
                    .accessibilityIdentifier("household.addChore")
            }
        }
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                ChoreEditorSheet(chore: nil, members: store.board.members, me: store.me) { fields in
                    store.create(fields)
                    core.log(module: "household", action: "chore.add", summary: "Added \(fields.name ?? "a chore")")
                }
            case .chore(let chore):
                ChoreEditorSheet(chore: chore, members: store.board.members, me: store.me,
                                 archive: { store.archive(chore) }) { fields in
                    store.edit(chore, to: fields)
                }
            }
        }
        .navigationDestination(isPresented: $showingPet) { HouseholdPetScreen(store: store) }
        .sheet(item: $askingHelp) { chore in
            HouseholdAskHelpSheet(chore: chore) { note in store.askHelp(chore, note: note) }
        }
        .sheet(item: $recapWeek) { week in
            HouseholdRecapSheet(store: store, weekStart: week.start)
        }
        .task {
            // Once per new week, if last week had anything to celebrate.
            let key = ChoreSchedule.weekKey(Self.lastWeekStart)
            guard recapSeenWeek != key, recapWeek == nil else { return }
            recapSeenWeek = key
            if store.board.roundsByDay(weekStart: Self.lastWeekStart).reduce(0, +) > 0 {
                recapWeek = RecapWeek(start: Self.lastWeekStart)
            }
        }
        .sheet(isPresented: $inviting) {
            HouseholdInviteSheet(service: app.householdSync, householdName: store.displayName)
        }
        .sheet(item: $joining) { target in
            HouseholdJoinSheet(service: app.householdSync, store: store, invite: target.invite)
        }
        .sheet(isPresented: $settingGoal) {
            HouseholdGoalSheet(current: store.board.goal(now: .now)) { target, reward in
                store.setGoal(target: target, reward: reward)
            }
        }
    }

    static var lastWeekStart: Date {
        Calendar.current.date(byAdding: .weekOfYear, value: -1, to: ChoreSchedule.weekStart(.now)) ?? .now
    }

    private func emptyState(_ store: HouseholdStore) -> some View {
        ContentUnavailableView {
            Label("No chores yet", systemImage: "house")
        } description: {
            Text("Keep the household's chores in one place and work towards a goal together. Everything stays on this phone.")
        } actions: {
            VStack(spacing: 10) {
                Button("Add a chore") { editing = .new }
                    .buttonStyle(SnappetWidePrimaryStyle())
                    .accessibilityIdentifier("household.empty.add")
                Button("Start with common chores") {
                    for fields in HouseholdStarter.chores(me: store.me) { store.create(fields) }
                }
                .buttonStyle(HouseholdOutlineStyle(wide: true))
                .accessibilityIdentifier("household.empty.starter")
            }
            .frame(maxWidth: 260)
        }
        .frame(maxHeight: .infinity)
    }
}

/// A sensible first board, so an empty household is one tap from useful.
enum HouseholdStarter {
    static func chores(me: UUID) -> [ChoreFields] {
        let mine = ChoreAssignment.rotate([me])
        return [
            ChoreFields(name: "Dishes", emoji: "🍽️", room: "Kitchen", effort: .s, repeats: .daily, assignment: mine),
            ChoreFields(name: "Bins out", emoji: "🗑️", room: "Outside", effort: .s, repeats: .weekly, assignment: mine),
            ChoreFields(name: "Hoover", emoji: "🧹", room: "Living room", effort: .m, repeats: .weekly, assignment: mine),
            ChoreFields(name: "Laundry", emoji: "🧺", room: "Laundry", effort: .m, repeats: .weekly, assignment: .upForGrabs),
            ChoreFields(name: "Clean the fridge", emoji: "🧊", room: "Kitchen", effort: .l,
                        repeats: .afterDone(days: 14), assignment: .upForGrabs),
            ChoreFields(name: "Water plants", emoji: "🌿", room: "Living room", effort: .s,
                        repeats: .weekdays([2, 5]), assignment: mine),
        ]
    }
}

// MARK: - Today (frame 1)

struct HouseholdTodayView: View {
    let store: HouseholdStore
    var service: HouseholdPeerService?
    let setGoal: () -> Void
    let edit: (Chore) -> Void
    let askHelp: (Chore) -> Void
    let openPet: () -> Void
    let ticked: () -> Void
    @Binding var cheer: Int
    var petCovered = false

    var body: some View {
        let now = Date.now
        let board = store.board
        let help = board.openHelpRequests(now: now)
        let thankable = Self.thankable(board, me: store.me, now: now)
        let buckets = board.today(me: store.me, now: now)
        let mine = buckets.mine, grabs = buckets.grabs, others = buckets.others
        let later = buckets.later

        List {
            Section {
                HouseholdPetCard(store: store, service: service, setGoal: setGoal, openPet: openPet, cheer: $cheer,
                                 covered: petCovered)
            }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section { HouseholdPowerHourRow(store: store) }

            if !help.isEmpty {
                Section("Asked for a hand") {
                    ForEach(help, id: \.opID) { HouseholdHelpCard(store: store, request: $0) }
                }
            }
            if !thankable.isEmpty {
                Section("Both of you did it") {
                    ForEach(thankable, id: \.round.first.opID) { item in
                        HStack(spacing: 10) {
                            Text(item.chore.emoji).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.chore.name).font(.system(size: 15, weight: .medium))
                                Text("Done by \(item.others.map { board.name(of: $0) }.joined(separator: " & ")) and you. It counts once for the goal; you're both credited.")
                                    .snappetDetail()
                            }
                            Spacer()
                            Button("👏 Thank") { for m in item.others { store.thank(m, for: item.chore.id) } }
                                .buttonStyle(HouseholdPillStyle())
                                .accessibilityIdentifier("household.thank")
                        }
                    }
                }
            }

            if !mine.isEmpty {
                Section("Yours today") {
                    ForEach(mine, id: \.chore.id) { r in row(r.chore, r.status, r.assignee) }
                }
            }
            if !grabs.isEmpty {
                Section("Up for grabs") {
                    ForEach(grabs, id: \.chore.id) { r in row(r.chore, r.status, r.assignee, grab: true) }
                }
            }
            if !others.isEmpty {
                Section("Others' turn") {
                    ForEach(others, id: \.chore.id) { r in row(r.chore, r.status, r.assignee) }
                }
            }
            if mine.isEmpty && grabs.isEmpty && others.isEmpty {
                Section {
                    Label("Nothing due today. Enjoy it.", systemImage: "sparkles")
                        .font(SnappetType.body).foregroundStyle(SnappetColor.textSecondary)
                }
            }
            if !later.isEmpty {
                Section("Coming up") {
                    ForEach(later, id: \.chore.id) { chore, next in
                        Button { edit(chore) } label: {
                            HStack(spacing: 12) {
                                Text(chore.emoji).font(.title3)
                                Text(chore.name).font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink)
                                Spacer()
                                Text(HouseholdFormat.next(next)).snappetDetail()
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ chore: Chore, _ status: ChoreStatus, _ assignee: UUID?, grab: Bool = false) -> some View {
        ChoreRow(chore: chore, status: status, assignee: assignee, board: store.board, me: store.me,
                 grab: grab ? { store.claim(chore) } : nil,
                 toggle: {
                     if case .done(let round) = status, round.members.contains(store.me) {
                         store.uncomplete(chore)
                     } else {
                         store.complete(chore)
                         ticked()
                     }
                 })
            .contentShape(Rectangle())
            .contextMenu {
                Button("Edit", systemImage: "pencil") { edit(chore) }
                if store.isShared, !Self.isDone(status), assignee == store.me {
                    Button("Ask for a hand", systemImage: "hand.raised") { askHelp(chore) }
                }
            }
    }

    private static func isDone(_ status: ChoreStatus) -> Bool {
        if case .done = status { return true } else { return false }
    }

    /// Today's rounds I shared with someone I haven't thanked yet.
    static func thankable(_ board: ChoreBoard, me: UUID, now: Date) -> [(chore: Chore, round: ChoreRound, others: [UUID])] {
        board.activeChores.compactMap { chore in
            guard let round = board.rounds(of: chore).last, round.members.contains(me),
                  Calendar.current.isDate(round.first.at, inSameDayAs: now) else { return nil }
            let others = round.members.filter { m in
                m != me && !board.thanks.contains { $0.by == me && $0.member == m && $0.chore == chore.id && $0.at >= round.first.at }
            }
            return others.isEmpty ? nil : (chore, round, others)
        }
    }
}

struct ChoreRow: View {
    let chore: Chore
    let status: ChoreStatus
    let assignee: UUID?
    let board: ChoreBoard
    let me: UUID
    let grab: (() -> Void)?
    let toggle: () -> Void

    private var isDone: Bool { if case .done = status { return true } else { return false } }

    var body: some View {
        HStack(spacing: 12) {
            Text(chore.emoji).font(.title3).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(chore.name).font(.system(size: 15, weight: .medium)).strikethrough(isDone)
                    EffortBadge(effort: chore.effort)
                }
                Text(detail).font(SnappetType.detail).foregroundStyle(detailColor)
            }
            .opacity(isDone ? 0.55 : 1)
            Spacer()
            if let grab, !isDone {
                Button("I'll do it", action: grab)
                    .buttonStyle(HouseholdPillStyle())
                    .accessibilityIdentifier("household.claim.\(chore.name)")
            }
            Button(action: toggle) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2.weight(.light))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isDone ? SnappetColor.onBrand : SnappetColor.textTertiary,
                                     isDone ? SnappetColor.brand : SnappetColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark \(chore.name) not done" : "Mark \(chore.name) done")
            .accessibilityIdentifier("household.check.\(chore.name)")
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        switch status {
        case .done(let round):
            let who = round.members.map { $0 == me ? "you" : board.name(of: $0) }.joined(separator: " & ")
            return "Done \(round.first.at.formatted(date: .omitted, time: .shortened)) by \(who)"
        case .due(let over) where over > 0:
            return over == 1 ? "1 day overdue" : "\(over) days overdue"
        case .due:
            var parts = [ChoreSchedule.summary(chore.repeats, short: true)]
            if case .rotate = chore.assignment, assignee == me { parts.append("your turn") }
            if let last = board.completions.last(where: { $0.chore == chore.id }), case .afterDone = chore.repeats {
                parts.append("last done \(last.at.formatted(.relative(presentation: .named)))")
            }
            return parts.joined(separator: " · ")
        case .notDue(let next):
            return next.map { HouseholdFormat.next($0) } ?? "Done"
        }
    }

    private var detailColor: Color {
        if case .due(let over) = status, over > 0 { return SnappetColor.perfHard }
        return SnappetColor.textSecondary
    }
}

struct EffortBadge: View {
    let effort: ChoreEffort
    var body: some View {
        Text(effort.label)
            .font(.system(size: 10))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SnappetColor.hairline))
            .foregroundStyle(SnappetColor.textSecondary)
            .accessibilityLabel("Effort \(effort.label)")
    }
}

enum HouseholdFormat {
    /// "Tomorrow", "Thu", "in 12 days".
    static func next(_ day: DayKey, now: Date = .now, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: day.date(calendar: calendar)).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return day.date(calendar: calendar).formatted(.dateTime.weekday(.wide))
        default: return "in \(days) days"
        }
    }
}

// MARK: - House goal card

struct HouseholdGoalCard: View {
    let board: ChoreBoard
    let now: Date
    let setGoal: () -> Void

    var body: some View {
        let start = ChoreSchedule.weekStart(now)
        let done = board.roundsByDay(weekStart: start).reduce(0, +)
        let end = Calendar.current.date(byAdding: .day, value: 6, to: start) ?? now
        Button(action: setGoal) {
            VStack(alignment: .leading, spacing: 6) {
                if let goal = board.goal(now: now), goal.target > 0 {
                    Text("House goal · ends \(end.formatted(.dateTime.weekday(.abbreviated)))").snappetLabel()
                    Text("\(Text("\(done)").font(SnappetType.metric).foregroundStyle(SnappetColor.ink)) \(Text(goal.reward.isEmpty ? "of \(goal.target) chores" : "of \(goal.target) chores → \(goal.reward)").font(SnappetType.metricUnit).foregroundStyle(SnappetColor.textSecondary))")
                        .monospacedDigit()
                        .accessibilityIdentifier("household.goal.progress")
                    HouseholdThinBar(fraction: Double(min(done, goal.target)) / Double(goal.target))
                    Text(done >= goal.target ? "Goal reached. Nice work." : "\(goal.target - done) to go").snappetDetail()
                } else {
                    Text("House goal").snappetLabel()
                    Text("\(Text("\(done)").font(SnappetType.metric).foregroundStyle(SnappetColor.ink)) \(Text(done == 1 ? "chore done this week" : "chores done this week").font(SnappetType.metricUnit).foregroundStyle(SnappetColor.textSecondary))")
                        .monospacedDigit()
                        .accessibilityIdentifier("household.goal.progress")
                    Text("Set a weekly goal and a reward to work towards ›").snappetDetail()
                }
            }
            .snappetPanel()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("household.goal.card")
        .padding(.vertical, 4)
    }
}

// MARK: - All chores

struct HouseholdChoresView: View {
    let store: HouseholdStore
    let edit: (Chore) -> Void

    var body: some View {
        let byRoom = Dictionary(grouping: store.board.activeChores) { $0.room.isEmpty ? "Anywhere" : $0.room }
        List {
            ForEach(byRoom.keys.sorted(), id: \.self) { room in
                Section(room) {
                    ForEach(byRoom[room] ?? []) { chore in
                        Button { edit(chore) } label: {
                            HStack(spacing: 12) {
                                Text(chore.emoji).font(.title3).frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(chore.name).font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink)
                                        EffortBadge(effort: chore.effort)
                                    }
                                    Text("\(ChoreSchedule.summary(chore.repeats, short: true)) · \(who(chore))")
                                        .snappetDetail()
                                }
                            }
                        }
                        .swipeActions {
                            Button("Archive", systemImage: "archivebox", role: .destructive) { store.archive(chore) }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func who(_ chore: Chore) -> String {
        switch chore.assignment {
        case .rotate(let order): return order.count > 1 ? "rotates" : "you"
        case .fixed(let m): return m == store.me ? "you" : store.board.name(of: m)
        case .upForGrabs: return "up for grabs"
        }
    }
}

// MARK: - Week (frame 2)

struct HouseholdWeekView: View {
    let store: HouseholdStore
    let setGoal: () -> Void
    let recap: () -> Void

    var body: some View {
        let now = Date.now
        let cal = Calendar.current
        let start = ChoreSchedule.weekStart(now)
        let counts = store.board.roundsByDay(weekStart: start)
        let peak = max(1, counts.max() ?? 1)
        let todayIndex = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: now)).day ?? 0
        List {
            Section { HouseholdGoalCard(board: store.board, now: now, setGoal: setGoal) }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            Section("The house this week") {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<7, id: \.self) { i in
                        let day = cal.date(byAdding: .day, value: i, to: start) ?? start
                        VStack(spacing: 4) {
                            Text(counts[i] > 0 ? "\(counts[i])" : " ").font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(SnappetColor.textSecondary)
                            // Thin bars: the accent on days with chores, a hairline stub on empty ones.
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(counts[i] > 0 ? SnappetColor.brand : SnappetColor.hairline)
                                .frame(height: max(3, 70 * CGFloat(counts[i]) / CGFloat(peak)))
                            Text(day.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 10, weight: i == todayIndex ? .semibold : .regular))
                                .foregroundStyle(i == todayIndex ? SnappetColor.ink : SnappetColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 110, alignment: .bottom)
                .padding(.vertical, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(counts.reduce(0, +)) chores done this week")
            }
            if store.board.members.count > 1 {
                Section { HouseholdFairShareCard(store: store).padding(.vertical, 4) }
                let help = store.board.openHelpRequests()
                if !help.isEmpty {
                    Section("Asked for a hand") {
                        ForEach(help, id: \.opID) { HouseholdHelpCard(store: store, request: $0) }
                    }
                }
            } else {
                Section {
                    Text("Once others join, you'll see everyone's share of the effort here, and anyone can ask for a hand with a chore.")
                        .snappetDetail()
                }
            }
            Section {
                Button(action: recap) {
                    HStack {
                        Label("Last week in the house", systemImage: "sparkles")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SnappetColor.textTertiary)
                    }
                }
                .accessibilityIdentifier("household.week.recap")
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Shared styles (design-system restyle, prompt 235)

/// The row action ("I'll do it", "Take it", "👏 Thank"): an accent outline pill.
struct HouseholdPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .snappetPill(selected: false, tint: SnappetColor.brand)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A secondary action: a neutral hairline outline (or a meaning `tint`, e.g. red for End).
struct HouseholdOutlineStyle: ButtonStyle {
    var wide = false
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: wide ? 15 : 12.5, weight: .medium))
            .foregroundStyle(tint ?? SnappetColor.ink)
            .padding(.horizontal, wide ? 16 : 11).padding(.vertical, wide ? 10 : 6)
            .frame(maxWidth: wide ? .infinity : nil)
            .overlay(Capsule().strokeBorder(tint.map { $0.opacity(0.5) } ?? SnappetColor.hairline, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A thin accent progress bar on a hairline track.
struct HouseholdThinBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(SnappetColor.hairline)
                Capsule().fill(SnappetColor.brand).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
