import SwiftUI
import SwiftData

/// One of the suite's other apps as a compact Home row.
struct HomeAppTile: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let open: () -> Void
}

/// Home for people who train (prompt 150), restyled in the calmer design system (prompt 212; mockup
/// `docs/ux-research/design-system/home-periwinkle.html`): one accent, regular weights, one card style, the buddy as a
/// small avatar — and **every element opens where it came from** (user, 2026-10-29: "make sure everything you show
/// in home has a deep link to get to its source"). Each tappable thing shows a chevron.
struct TrainingHomeView<Activity: View>: View {
    let snapshot: ProgressionSnapshot
    let sessions: [WorkoutSession]
    let routines: [Routine]
    let now: Date
    let otherApps: [HomeAppTile]
    @ViewBuilder let activity: () -> Activity

    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(BuddyDefaults.hatchedKey, store: BuddyDefaults.store) private var hatched = false
    @State private var showingPause = false
    @State private var showingSettings = false

    private var inputs: [ScheduledRoutineInput] { RoutineScheduleSync.inputs(routines: routines, sessions: sessions) }

    var body: some View {
        let inputs = inputs
        let plan = RoutineReminderPlanner.week(inputs, now: now)
        let active = sessions.first { $0.completedAt == nil && !$0.isImportedFromHealth }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                // The one-time hatch keeps its 3D moment; afterwards the buddy is a small avatar (no 3D on Home).
                if !hatched {
                    BuddyHero(snapshot: snapshot, active: active, sessions: sessions, routines: routines, now: now)
                } else if let active {
                    activeCard(active)
                } else {
                    buddyCard
                }
                if active == nil {
                    TodayTrainingCard(snapshot: snapshot, upNext: RoutineReminderPlanner.upNext(inputs, now: now),
                                      today: plan.first(where: \.isToday), sessions: sessions, routines: routines,
                                      hasSchedules: !inputs.isEmpty, now: now, showingPause: $showingPause)
                }
                HStack(alignment: .top, spacing: 10) {
                    weekCard(TrainingHome.week(sessions: sessions, ledger: snapshot.ledger, plan: plan, now: now), plan: plan)
                    streakCard
                }
                .fixedSize(horizontal: false, vertical: true)
                wins
                comingUp
                if !otherApps.isEmpty { appsList }
                notes(plan: plan)
                activity()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .background(SnappetColor.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: SnappetSpacing.xxl) }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingPause) {
            PauseSheet { RoutineScheduleSync.replan(context: context, reminders: app.routineReminders) }
        }
        .sheet(isPresented: $showingSettings) { SuiteSettingsView() }
        .accessibilityIdentifier("trainingHome")
    }

    // MARK: Header (→ Settings)

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide))).snappetLabel()
                Text("Today").font(SnappetType.screenTitle).foregroundStyle(SnappetColor.ink)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "person.crop.circle").font(.system(size: 26, weight: .light))
                    .foregroundStyle(SnappetColor.textSecondary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home.settings")
        }
        .padding(.top, 8)
    }

    // MARK: Buddy (→ your buddy)

    private var buddyImage: String {
        BuddyWidgetSnapshot.imageName(stage: snapshot.level.stage.rawValue, form: snapshot.form.value,
                                      paused: snapshot.pause != nil)
    }

    private var buddyCard: some View {
        NavigationLink { BuddyScreen() } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(buddyImage).resizable().scaledToFill().frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(snapshot.level.stage.title) · Level \(snapshot.level.level)").snappetTitle()
                            .accessibilityIdentifier("buddy.level")
                        Text(snapshot.pause != nil ? "Resting — form and streak are held"
                             : "\(snapshot.look.mood) · form \(Int((snapshot.form.value * 100).rounded()))%")
                            .snappetDetail()
                    }
                    Spacer()
                    chevron
                }
                ProgressView(value: snapshot.level.fraction).tint(SnappetColor.brand)
                Text("\(snapshot.level.xpIntoLevel) / \(snapshot.level.levelCost) XP to Level \(snapshot.level.level + 1)")
                    .snappetLabel()
            }
            .snappetPanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("buddy.open")
    }

    private func activeCard(_ active: WorkoutSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink { BuddyScreen() } label: {
                HStack(spacing: 12) {
                    Image(buddyImage).resizable().scaledToFill().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Training now").snappetLabel()
                        Text(active.routineName).snappetTitle()
                        Text("\(max(1, Int(active.duration / 60))) min · \(active.completedSetCount) logged").snappetDetail()
                    }
                    Spacer()
                    chevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("buddy.open")
            Button("Resume workout") {
                router.pendingWorkoutResume = true
                router.open(module: WorkoutTrackerModule.id)
            }
            .buttonStyle(.snappetPrimary)
            .accessibilityIdentifier("home.hero.resume")
        }
        .snappetPanel(glow: true)
    }

    // MARK: This week (→ History, this week / that day)

    private func weekCard(_ days: [TrainingHome.Day], plan: [RoutineReminderPlanner.WeekDay]) -> some View {
        let xp = days.reduce(0) { $0 + $1.xp }
        let heights = SnappetBars.heights(days.map { Double($0.xp) })
        return VStack(alignment: .leading, spacing: 6) {
            Button { openHistory(.week(containing: now, now: now)) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text("This week").snappetLabel(); Spacer(); chevron }
                    SnappetMetric(value: "\(xp)", unit: "XP")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.week")
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    Button { openHistory(.day(d.day.date(), now: now)) } label: {
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(d.xp > 0 ? SnappetColor.brand : SnappetColor.hairline)
                                .frame(height: max(3, 34 * heights[i]))
                            Text(d.day.date().formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 9.5, weight: d.isToday ? .semibold : .regular))
                                .foregroundStyle(d.isToday ? SnappetColor.ink : SnappetColor.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .bottom)
                        .frame(height: 50, alignment: .bottom)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(d.day.date().formatted(.dateTime.weekday(.wide))), \(d.xp) XP")
                    .accessibilityIdentifier("home.week.day")
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .snappetPanel()
    }

    private func openHistory(_ range: HistoryDateRange) {
        router.pendingHistoryRange = range
        router.open(module: WorkoutTrackerModule.id)
    }

    // MARK: Streak (→ your buddy)

    private var streakCard: some View {
        NavigationLink { BuddyScreen() } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text("Streak").snappetLabel(); Spacer(); chevron }
                SnappetMetric(value: "\(snapshot.streak.weeks)", unit: snapshot.streak.weeks == 1 ? "week" : "weeks")
                Text(snapshot.streak.freezes > 0
                     ? "\(snapshot.streak.freezes) freeze\(snapshot.streak.freezes == 1 ? "" : "s") left"
                     : "Next freeze in \(snapshot.streak.nextFreezeIn) wk")
                    .snappetDetail().padding(.top, 14)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .snappetPanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.streak")
    }

    // MARK: Recent wins (→ the session)

    @ViewBuilder private var wins: some View {
        let wins = TrainingHome.recentWins(sessions, now: now)
        if !wins.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent wins").snappetLabel().padding(.bottom, 4)
                ForEach(Array(wins.enumerated()), id: \.element.id) { i, w in
                    if i > 0 { Divider().overlay(SnappetColor.hairline) }
                    Button {
                        router.open(module: WorkoutTrackerModule.id)
                        router.push(SessionRoute(id: w.sessionID))
                    } label: {
                        SnappetRow(icon: w.icon, title: w.title, subtitle: w.detail)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.win")
                }
            }
            .snappetPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.wins")
        }
    }

    // MARK: Coming up (→ your buddy / the routine)

    @ViewBuilder private var comingUp: some View {
        let growth = TrainingHome.nextGrowth(snapshot.level)
        let milestone = TrainingHome.nextMilestone(sessions)
        let freeze = snapshot.streak.weeks > 0 && snapshot.streak.freezes < Progression.Streaks.maxFreezes
        if growth != nil || milestone != nil || freeze {
            VStack(alignment: .leading, spacing: 2) {
                Text("Coming up").snappetLabel().padding(.bottom, 4)
                if let g = growth {
                    NavigationLink { BuddyScreen() } label: {
                        SnappetRow(icon: "🌟", title: "Grows into \(g.next.title)",
                                   subtitle: "Level \(g.atLevel) · \(g.levelsToGo) level\(g.levelsToGo == 1 ? "" : "s") to go")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.comingUp.growth")
                }
                if let m = milestone {
                    Divider().overlay(SnappetColor.hairline)
                    Button { open(m) } label: {
                        SnappetRow(icon: "🎯", title: "\(SessionInsights.ordinal(m.target)) \(m.name)",
                                   subtitle: "\(m.toGo) to go")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.comingUp.milestone")
                }
                if freeze {
                    Divider().overlay(SnappetColor.hairline)
                    NavigationLink { BuddyScreen() } label: {
                        SnappetRow(icon: "❄︎", title: "Next streak freeze",
                                   subtitle: "in \(snapshot.streak.nextFreezeIn) week\(snapshot.streak.nextFreezeIn == 1 ? "" : "s")")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.comingUp.freeze")
                }
            }
            .snappetPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.comingUp")
        }
    }

    /// The routine's own page (exercises, history); a quick-session series has no routine, so its latest session.
    private func open(_ m: TrainingHome.Milestone) {
        router.open(module: WorkoutTrackerModule.id)
        if let id = m.routineID, let r = routines.first(where: { $0.id == id }) {
            router.push(r)
        } else if let id = m.latestSessionID {
            router.push(SessionRoute(id: id))
        }
    }

    // MARK: Other apps (→ the app)

    private var appsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Your other apps").snappetLabel().padding(.bottom, 4)
            ForEach(Array(otherApps.enumerated()), id: \.element.id) { i, tile in
                if i > 0 { Divider().overlay(SnappetColor.hairline) }
                Button(action: tile.open) {
                    HStack(spacing: 12) {
                        Image(systemName: tile.systemImage).font(.system(size: 15)).foregroundStyle(tile.tint)
                            .frame(width: 32, height: 32)
                            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tile.title).font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink)
                            Text(tile.detail).snappetDetail().lineLimit(1)
                        }
                        Spacer()
                        chevron
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.app.\(tile.id)")
            }
        }
        .snappetPanel()
    }

    // MARK: Notes (→ the routine / your buddy) — quiet lines, not warning boxes

    @ViewBuilder private func notes(plan: [RoutineReminderPlanner.WeekDay]) -> some View {
        if plan.first(where: \.isToday)?.state != .done,
           let missed = TrainingHome.missedNote(plan: plan, paused: snapshot.pause != nil) {
            let name = plan.last(where: { $0.state == .missed })?.names.first
            Button {
                if let name, let r = routines.first(where: { $0.name == name }) {
                    router.pendingRoutineStart = r.id
                    router.open(module: WorkoutTrackerModule.id)
                } else {
                    router.open(module: WorkoutTrackerModule.id)
                }
            } label: {
                Text("\(missed) \(Text("Do it today ›").fontWeight(.semibold).foregroundStyle(SnappetColor.brand))")
                    .snappetDetail().multilineTextAlignment(.leading)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.missedNote")
        }
        if snapshot.freezeCoveredLastWeek() {
            NavigationLink { BuddyScreen() } label: {
                Text("❄︎ A streak freeze covered last week, so your \(snapshot.streak.weeks)-week streak is safe.")
                    .snappetDetail().padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.freezeNote")
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SnappetColor.textTertiary)
    }
}

// MARK: - Hero

/// The buddy at the top of Home: live 3D (tap to cheer), level, mood, streak and freezes, the bar to
/// the next level. Hatch first; asleep when paused; the live workout while training.
struct BuddyHero: View {
    let snapshot: ProgressionSnapshot
    let active: WorkoutSession?
    let sessions: [WorkoutSession]
    let routines: [Routine]
    let now: Date

    @Environment(SuiteRouter.self) private var router
    @AppStorage(BuddyDefaults.hatchedKey, store: BuddyDefaults.store) private var hatched = false
    @State private var hatchingStage: BuddyStage?
    @State private var cheer = 0
    @State private var onScreen = true

    private var shownStage: BuddyStage { hatchingStage ?? (hatched ? snapshot.level.stage : .egg) }
    private var look: BuddyLook {
        BuddyLook(stage: shownStage, form: snapshot.form.value, paused: snapshot.pause != nil && hatchingStage == nil && active == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .top) {
                // Paused while another tab is showing (prompt 193): Home stays alive inside the TabView, and its
                // scroll-visibility never changes on a tab switch, so the buddy kept animating behind Clips.
                BuddyCreatureView(look: look, cheerTrigger: cheer, animated: onScreen && router.tab == .home,
                                  interactive: false)
                    .frame(height: 230)
                chips.padding(10)
            }
            info.padding(.horizontal, 14).padding(.bottom, 12)
        }
        .background(LinearGradient(colors: [Color(hue: look.hue, saturation: 0.22, brightness: snapshot.pause != nil ? 0.22 : 0.28),
                                            Color(white: 0.08)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
        .onScrollVisibilityChange(threshold: 0.15) { onScreen = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.hero")
    }

    // MARK: Chips

    @ViewBuilder private var chips: some View {
        HStack {
            if let active {
                chip("● Training now", tint: .red)
                Spacer()
                chip("\(max(1, Int(active.duration / 60))) min")
            } else if let p = snapshot.pause {
                chip("Paused · \(p.reason.title)")
                Spacer()
                chip(p.plannedEnd.map { "back \($0.formatted(.dateTime.weekday(.abbreviated).day().month()))" } ?? "until you're back")
            } else {
                chip(now.formatted(.dateTime.weekday(.abbreviated).day().month()))
                Spacer()
                if snapshot.streak.weeks >= 1 {
                    chip("🔥 \(snapshot.streak.weeks) week\(snapshot.streak.weeks == 1 ? "" : "s")"
                         + (snapshot.streak.freezes > 0 ? " · ❄︎ \(snapshot.streak.freezes)" : ""))
                }
            }
        }
    }

    private func chip(_ text: String, tint: Color = .white) -> some View {
        Text(text).font(.caption.weight(.bold)).foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.black.opacity(0.35), in: Capsule())
    }

    // MARK: Info

    @ViewBuilder private var info: some View {
        if !hatched || hatchingStage != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Meet your training buddy").font(.title3.weight(.heavy)).foregroundStyle(.white)
                Text("Your \(snapshot.ledger.sessionCount) sessions already count — it hatches straight to **Level \(snapshot.level.level) · \(snapshot.level.stage.title)**.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                Button(hatchingStage == nil ? "Hatch" : "Hatching…") { hatch() }
                    .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                    .frame(maxWidth: .infinity)
                    .disabled(hatchingStage != nil)
                    .accessibilityIdentifier("buddy.hatch")
            }
        } else if let active {
            let ledger = Progression.ledger(sessions, including: active,
                                            schedules: ProgressionSnapshot.schedules(routines),
                                            pauses: PauseStore.load())
            let soFar = ledger.awards[active.id]?.total ?? 0
            let level = Progression.levelInfo(totalXP: ledger.totalXP)
            VStack(alignment: .leading, spacing: 5) {
                // The workout details still lead to your buddy; Resume is its own button below.
                NavigationLink {
                    BuddyScreen()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(active.routineName).font(.title3.weight(.heavy)).foregroundStyle(.white)
                            Spacer()
                            Text("Your buddy ›").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        }
                        Text(soFar > 0 ? "+\(soFar) XP so far" : "Keep going — XP lands at 5 minutes")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.yellow)
                            .accessibilityIdentifier("home.hero.xpSoFar")
                        HStack {
                            Text("\(active.completedSetCount) logged").font(.caption)
                            Spacer()
                            Text("Level \(level.level + 1) in \(level.xpToNext) XP").font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.65))
                        ProgressView(value: level.fraction).tint(SnappetColor.workout)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("buddy.open")
                Button {
                    router.pendingWorkoutResume = true
                    router.open(module: WorkoutTrackerModule.id)
                } label: {
                    Text("Resume workout").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                .padding(.top, 4)
                .accessibilityIdentifier("home.hero.resume")
            }
        } else {
            NavigationLink {
                BuddyScreen()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(snapshot.level.stage.title) · Level \(snapshot.level.level)")
                        .font(.title3.weight(.heavy)).foregroundStyle(.white)
                        .accessibilityIdentifier("buddy.level")
                    Text(snapshot.pause != nil ? "Resting — Form and streak are held"
                         : snapshot.look.mood + " · Form \(Int((snapshot.form.value * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(snapshot.pause != nil ? .cyan : snapshot.form.value >= 0.45 ? .green : .yellow)
                    HStack {
                        Text("\(snapshot.level.xpIntoLevel) / \(snapshot.level.levelCost) XP")
                        Spacer()
                        if let next = Progression.nextStageLevel(after: snapshot.level.level) {
                            Text("\(Progression.stage(forLevel: next).title) at Level \(next)")
                        }
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
                    ProgressView(value: snapshot.level.fraction).tint(SnappetColor.workout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("buddy.open")
        }
    }

    private func hatch() {
        let target = snapshot.level.stage
        Task { @MainActor in
            for stage in BuddyStage.allCases where stage.rawValue <= target.rawValue {
                hatchingStage = stage
                cheer += 1
                try? await Task.sleep(for: .milliseconds(stage == target ? 1_300 : 750))
            }
            hatched = true
            hatchingStage = nil
        }
    }
}

// MARK: - Today's training

/// One clear thing to do today: the planned session with its likely XP and Start / Skip (the card itself opens the
/// routine's page); a calm rest-day card; or, when paused, a pause card. Restyled in prompt 212.
struct TodayTrainingCard: View {
    let snapshot: ProgressionSnapshot
    let upNext: RoutineReminderPlanner.UpNext?
    /// Today in this week's plan — "done for today" when its planned session is finished.
    let today: RoutineReminderPlanner.WeekDay?
    let sessions: [WorkoutSession]
    let routines: [Routine]
    let hasSchedules: Bool
    let now: Date
    @Binding var showingPause: Bool

    @Environment(SuiteRouter.self) private var router
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @AppStorage(PauseStore.key, store: BuddyDefaults.store) private var pausesRaw = "[]"

    var body: some View {
        Group {
            if let p = snapshot.pause {
                calm(kicker: "Paused", title: "Take care of yourself",
                     detail: p.muteReminders
                        ? "Reminders are quiet\(p.plannedEnd.map { " until \($0.formatted(.dateTime.weekday(.wide).day().month()))" } ?? ""). Training anyway still counts."
                        : "Training anyway still counts.", routine: nil) {
                    Button("I'm back — end pause") {
                        PauseStore.endActive()
                        pausesRaw = PauseStore.encode(PauseStore.load())
                        RoutineScheduleSync.replan(context: context, reminders: app.routineReminders)
                    }
                    .buttonStyle(.snappetPrimary)
                    .accessibilityIdentifier("home.endPause")
                }
            } else if let u = upNext, u.isToday, let routine = routines.first(where: { $0.id == u.routineID }) {
                planned(u, routine)
            } else if today?.state == .done {
                let next = upNext.flatMap { u in routines.first { $0.id == u.routineID }.map { ($0, u) } }
                let earned = sessions.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: now) }
                    .compactMap { snapshot.ledger.awards[$0.id]?.total }.reduce(0, +)
                calm(kicker: "Done for today ✓",
                     title: (today?.names.first ?? "Training") + (earned > 0 ? " · +\(earned) XP" : ""),
                     detail: next.map { "Next: \($0.0.name) \($0.1.start.formatted(.relative(presentation: .named)))" }
                        ?? "Nice work. Rest is part of the plan.",
                     routine: next?.0) { EmptyView() }
            } else {
                let next = upNext.flatMap { u in routines.first { $0.id == u.routineID }.map { ($0, u) } }
                calm(kicker: hasSchedules ? "Rest day" : "Today",
                     title: hasSchedules ? "Nothing planned today" : "No routine scheduled",
                     detail: next.map { "Next: \($0.0.name) \($0.1.start.formatted(.relative(presentation: .named)))" }
                        ?? (hasSchedules ? "Extra sessions earn XP too." : "Schedule a routine and your week plans itself."),
                     routine: next?.0) {
                    Button(hasSchedules ? "Quick session" : "Pick a routine") {
                        if !hasSchedules { router.pendingShowRoutines = true }
                        router.open(module: WorkoutTrackerModule.id)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.today.secondary")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.today")
    }

    /// The routine's own page (exercises, history, vs last time).
    private func openRoutine(_ routine: Routine) {
        router.open(module: WorkoutTrackerModule.id)
        router.push(routine)
    }

    private func planned(_ u: RoutineReminderPlanner.UpNext, _ routine: Routine) -> some View {
        let xp = TrainingHome.xpEstimate(routineID: routine.id, sessions: sessions, ledger: snapshot.ledger)
        let minutes = TrainingHome.typicalMinutes(routineID: routine.id, sessions: sessions)
        return VStack(alignment: .leading, spacing: 4) {
            Button { openRoutine(routine) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Today · \(u.start.formatted(date: .omitted, time: .shortened))").snappetLabel()
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SnappetColor.textTertiary)
                    }
                    Text(routine.name).snappetTitle()
                    Text((minutes.map { "About \($0) min" } ?? "\(routine.exercises.count) exercises") + " · ≈ +\(xp) XP")
                        .snappetDetail()
                        .accessibilityIdentifier("home.today.xp")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.today.open")
            HStack(spacing: 6) {
                Button("Start") {
                    router.pendingRoutineStart = routine.id
                    router.open(module: WorkoutTrackerModule.id)
                }
                .buttonStyle(.snappetPrimary)
                .accessibilityIdentifier("home.today.start")
                Button("Skip today") {
                    RoutineScheduleSync.skip(routineID: routine.id, day: u.day, context: context, reminders: app.routineReminders)
                }
                .font(SnappetType.body).foregroundStyle(SnappetColor.textSecondary)
                .padding(.horizontal, 10)
                .accessibilityIdentifier("home.today.skip")
                Spacer()
                Button("Pause…") { showingPause = true }
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityIdentifier("home.today.pause")
            }
            .padding(.top, 8)
        }
        .snappetPanel(glow: true)
    }

    private func calm<Actions: View>(kicker: String, title: String, detail: String, routine: Routine?,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { if let routine { openRoutine(routine) } } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(kicker).snappetLabel()
                        Spacer()
                        if routine != nil {
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SnappetColor.textTertiary)
                        }
                    }
                    Text(title).snappetTitle()
                    Text(detail).snappetDetail()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(routine == nil)
            actions().padding(.top, 8)
        }
        .snappetPanel()
    }
}
