import SwiftUI
import SwiftData

/// One of the suite's other apps as a compact Home tile (the 2×2 grid under the training section).
struct HomeAppTile: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let open: () -> Void
}

/// Home for people who train (prompt 150; wireframe `docs/ux-research/progression/home.html`): the buddy
/// as the hero, today's session with its likely XP, the week in XP, recent wins, what's coming up — then
/// the other apps and the activity feed. People who haven't earned XP keep the classic Home.
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
    @State private var showingPause = false

    private var inputs: [ScheduledRoutineInput] { RoutineScheduleSync.inputs(routines: routines, sessions: sessions) }

    var body: some View {
        let inputs = inputs
        let plan = RoutineReminderPlanner.week(inputs, now: now)
        let active = sessions.first { $0.completedAt == nil && !$0.isImportedFromHealth }
        ScrollView {
            VStack(alignment: .leading, spacing: SnappetSpacing.md) {
                BuddyHero(snapshot: snapshot, active: active, sessions: sessions, routines: routines, now: now)
                notes(plan: plan)
                if active == nil {
                    TodayTrainingCard(snapshot: snapshot, upNext: RoutineReminderPlanner.upNext(inputs, now: now),
                                      today: plan.first(where: \.isToday), sessions: sessions, routines: routines,
                                      hasSchedules: !inputs.isEmpty, now: now, showingPause: $showingPause)
                }
                weekCard(TrainingHome.week(sessions: sessions, ledger: snapshot.ledger, plan: plan, now: now), plan: plan)
                wins
                comingUp
                if !otherApps.isEmpty { appsGrid }
                activity()
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: SnappetSpacing.xxl) }
        // The hero replaces the "Today" title (wireframe frame 1); pushed screens keep their bars.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingPause) {
            PauseSheet { RoutineScheduleSync.replan(context: context, reminders: app.routineReminders) }
        }
        .accessibilityIdentifier("trainingHome")
    }

    // MARK: Notes (missed day, freeze used)

    @ViewBuilder private func notes(plan: [RoutineReminderPlanner.WeekDay]) -> some View {
        if plan.first(where: \.isToday)?.state != .done,
           let missed = TrainingHome.missedNote(plan: plan, paused: snapshot.pause != nil) {
            note(missed, tint: SnappetColor.workout, id: "home.missedNote")
        }
        if snapshot.freezeCoveredLastWeek() {
            note("❄︎ A streak freeze covered last week, so your \(snapshot.streak.weeks)-week streak is safe.",
                 tint: .blue, id: "home.freezeNote")
        }
    }

    private func note(_ text: String, tint: Color, id: String) -> some View {
        Text(text).font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35)))
            .accessibilityIdentifier(id)
    }

    // MARK: This week

    private func weekCard(_ days: [TrainingHome.Day], plan: [RoutineReminderPlanner.WeekDay]) -> some View {
        let planned = plan.filter { [.planned, .done, .missed].contains($0.state) }.count
        let done = plan.filter { $0.state == .done }.count
        let xp = days.reduce(0) { $0 + $1.xp }
        let top = Double(max(150, days.map(\.xp).max() ?? 0))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").font(.headline)
                Spacer()
                Text((planned > 0 ? "\(done) of \(planned) planned · " : "") + "\(xp) XP")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                ForEach(days, id: \.day) { d in
                    VStack(spacing: 3) {
                        Text(d.day.date().formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(d.isToday ? .heavy : .regular))
                            .foregroundStyle(d.isToday ? .primary : .secondary)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(d.state == .missed ? Color.orange.opacity(0.14) : SnappetColor.surface)
                            if d.xp > 0 {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(LinearGradient(colors: [SnappetColor.workout, .yellow.opacity(0.8)],
                                                         startPoint: .bottom, endPoint: .top))
                                    .frame(height: 46 * max(0.12, Double(d.xp) / top))
                            }
                            if d.state == .planned || d.state == .done || d.state == .missed {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(SnappetColor.workout.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            }
                        }
                        .frame(height: 46)
                        Text(d.xp > 0 ? "\(d.xp)" : d.isToday ? "today" : " ")
                            .font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .snappetTile()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.week")
    }

    // MARK: Recent wins

    @ViewBuilder private var wins: some View {
        let wins = TrainingHome.recentWins(sessions, now: now)
        if !wins.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent wins").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(wins) { w in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.icon)
                                Text(w.title).font(.caption.weight(.heavy)).lineLimit(2, reservesSpace: true)
                                Text(w.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 128, alignment: .leading)
                            .padding(9)
                            .background(SnappetColor.workout.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SnappetColor.workout.opacity(0.35)))
                        }
                    }
                }
            }
            .snappetTile()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.wins")
        }
    }

    // MARK: Coming up

    @ViewBuilder private var comingUp: some View {
        let growth = TrainingHome.nextGrowth(snapshot.level)
        let milestone = TrainingHome.nextMilestone(sessions)
        if growth != nil || milestone != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Coming up").font(.headline)
                if let g = growth {
                    progressRow("🌟 Grows into **\(g.next.title)**", "Level \(g.atLevel) · \(g.levelsToGo) level\(g.levelsToGo == 1 ? "" : "s")", g.fraction)
                }
                if let m = milestone {
                    progressRow("🎯 **\(SessionInsights.ordinal(m.target)) \(m.name)**", "\(m.toGo) to go", m.fraction)
                }
                if snapshot.streak.weeks > 0, snapshot.streak.freezes < Progression.Streaks.maxFreezes {
                    HStack {
                        Text("❄︎ Next streak freeze")
                        Spacer()
                        Text("in \(snapshot.streak.nextFreezeIn) week\(snapshot.streak.nextFreezeIn == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            .snappetTile()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.comingUp")
        }
    }

    private func progressRow(_ title: LocalizedStringKey, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            ProgressView(value: fraction).tint(SnappetColor.workout)
        }
    }

    // MARK: Other apps

    private var appsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your other apps").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(otherApps) { tile in
                    Button(action: tile.open) {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: tile.systemImage).foregroundStyle(tile.tint)
                            Text(tile.title).font(.subheadline.weight(.bold)).foregroundStyle(SnappetColor.ink)
                                .lineLimit(2, reservesSpace: true)
                            Text(tile.detail).font(.caption2).foregroundStyle(SnappetColor.textSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.app.\(tile.id)")
                }
            }
        }
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
                BuddyCreatureView(look: look, cheerTrigger: cheer, animated: onScreen, interactive: false)
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

/// One clear thing to do today (wireframe frames 1, 3–5): the planned session with its likely XP and
/// Start / Skip; a calm rest-day card; or, when paused, a pause card.
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
                        : "Training anyway still counts.") {
                    Button("I'm back — end pause") {
                        PauseStore.endActive()
                        pausesRaw = PauseStore.encode(PauseStore.load())
                        RoutineScheduleSync.replan(context: context, reminders: app.routineReminders)
                    }
                    .buttonStyle(.bordered).tint(SnappetColor.workout)
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
                        ?? "Nice work. Rest is part of the plan.") { EmptyView() }
            } else {
                let next = upNext.flatMap { u in routines.first { $0.id == u.routineID }.map { ($0, u) } }
                calm(kicker: hasSchedules ? "Rest day" : "Today",
                     title: hasSchedules ? "Nothing planned today" : "No routine scheduled",
                     detail: next.map { "Next: \($0.0.name) \($0.1.start.formatted(.relative(presentation: .named)))" }
                        ?? (hasSchedules ? "Extra sessions earn XP too." : "Schedule a routine and your week plans itself.")) {
                    Button(hasSchedules ? "Quick session" : "Pick a routine") {
                        if !hasSchedules { router.pendingShowRoutines = true }
                        router.open(module: WorkoutTrackerModule.id)
                    }
                    .buttonStyle(.bordered).tint(SnappetColor.workout)
                    .accessibilityIdentifier("home.today.secondary")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.today")
    }

    private func planned(_ u: RoutineReminderPlanner.UpNext, _ routine: Routine) -> some View {
        let xp = TrainingHome.xpEstimate(routineID: routine.id, sessions: sessions, ledger: snapshot.ledger)
        let minutes = TrainingHome.typicalMinutes(routineID: routine.id, sessions: sessions)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("TODAY · \(u.start.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(SnappetColor.workout)
                Spacer()
                Text("≈ +\(xp) XP").font(.caption.weight(.heavy)).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .accessibilityIdentifier("home.today.xp")
            }
            Text(routine.name).font(.title3.weight(.heavy))
            Text(minutes.map { "About \($0) min" } ?? "\(routine.exercises.count) exercises")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    router.pendingRoutineStart = routine.id
                    router.open(module: WorkoutTrackerModule.id)
                } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                    .accessibilityIdentifier("home.today.start")
                Button("Skip today") {
                    RoutineScheduleSync.skip(routineID: routine.id, day: u.day, context: context, reminders: app.routineReminders)
                }
                .buttonStyle(.bordered).tint(.secondary)
                .accessibilityIdentifier("home.today.skip")
                Spacer()
                Button("Pause…") { showingPause = true }
                    .font(.subheadline)
                    .accessibilityIdentifier("home.today.pause")
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(LinearGradient(colors: [SnappetColor.workout.opacity(0.24), SnappetColor.workout.opacity(0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SnappetColor.workout.opacity(0.35)))
    }

    private func calm<Actions: View>(kicker: String, title: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker.uppercased()).font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.heavy))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
            actions().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .snappetTile()
    }
}
