import SwiftUI
import SwiftData
import Charts

/// The daily home (#60 §D): aggregates historical usage across every mini-app so the
/// suite reads as one app, not a bag of tools. Reactive via `@Query` — any mini-app
/// logging to `SnappetCore` updates this automatically.
///
/// Actionable, not read-only (#71): an "Up next" Today section derives cards from the same
/// SwiftData rows the modules query (via the pure `TodayDigest`), feed rows deep-link into
/// their module through the shell-hoisted `SuiteRouter`, and a fresh install gets a flagship
/// CTA that lands in Workout Reels onboarding instead of an empty dashboard.
struct HomeDashboardView: View {
    @Query(sort: \UsageRecord.timestamp, order: .reverse) private var records: [UsageRecord]
    // Today-card sources — the same rows the modules themselves query, so the cards can't
    // drift from what each mini-app shows (#71). `TodayDigest` turns them into card facts.
    @Query private var habits: [Habit]
    @Query private var habitCompletions: [HabitCompletion]
    @Query private var focusSessions: [PomodoroSession]
    @Query private var workoutSessions: [WorkoutSession]
    @Query private var budgetCategories: [BudgetCategory]
    @Query private var budgetTransactions: [BudgetTransaction]
    @Query private var kilterEntries: [KilterLogEntry]
    @Query private var kilterSessionsQ: [KilterSession]
    @Query private var kilterPlansQ: [KilterPlan]

    @Environment(SuiteRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// Drives the 7-day chart's grow-up-from-baseline animation on appear.
    @State private var chartAppeared = false
    /// The clock every "today" derivation reads (`todayCards`, `todayStart` → stat tiles, week
    /// chart, streak). Held in **state** — not read inline as `.now` — so the dashboard re-renders
    /// when the day rolls over instead of freezing yesterday's facts ("Streak safe for today"
    /// surviving into tomorrow, #71 review fix). Refreshed on `.NSCalendarDayChanged` (app awake
    /// across midnight) and on scenePhase `.active` (suspended-overnight resume).
    @State private var now: Date = .now

    var body: some View {
        NavigationStack {
            // Empty ↔ populated is a cross-fade (issue #30 §5.2) — and rendering one OR
            // the other (not an .overlay) fixes the empty-state-overlaps-content bug.
            ZStack {
                if records.isEmpty {
                    flagshipHero.transition(.opacity)
                } else {
                    feed.transition(.opacity)
                }
            }
            .snappetAnimation(SnappetMotion.standard, value: records.isEmpty)
            // The warm "paper" canvas on the shell screen, not just at cold start (#77).
            .background(SnappetColor.paper.ignoresSafeArea())
            .navigationTitle("Today")
            // The day rolled over while the app was awake (receive on main: the OS posts this
            // notification on a background thread).
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .receive(on: DispatchQueue.main)) { _ in now = .now }
            // Returning from a suspension (the phone slept past midnight) — the notification may
            // not have been delivered, so re-read the clock on every foregrounding.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { now = .now }
            }
        }
    }

    // MARK: first run

    /// First-run replacement for the dead-end empty state (#71): lead with the flagship pitch
    /// and a CTA that deep-links straight into Workout Reels — which, on a fresh install, opens
    /// its value-first onboarding (`AppModel.phase == .onboarding`). Browsing the rest of the
    /// suite stays one secondary tap away.
    private var flagshipHero: some View {
        ScrollView {
            VStack(spacing: SnappetSpacing.xl) {
                VStack(spacing: SnappetSpacing.md) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(SnappetColor.reels)
                    Text("Turn workouts into highlight reels")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Snappet reads your workout heart rate and cuts the clips you filmed into a shareable reel — automatically.")
                        .font(.subheadline)
                        .foregroundStyle(SnappetColor.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        router.open(module: "workout")
                    } label: {
                        Text("Make your first reel")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("home.flagshipCTA")
                }
                .frame(maxWidth: .infinity)
                .snappetCard()

                Button {
                    router.tab = .apps
                } label: {
                    Label("Or browse all 9 apps", systemImage: "square.stack.3d.up")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("home.browseApps")
            }
            .padding()
            .padding(.top, SnappetSpacing.xl)
        }
    }

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SnappetSpacing.xl) {
                upNext
                todayRow
                weekChart
                activityFeed
            }
            .padding()
        }
        // Clear the suite's floating tab bar so the last card isn't covered.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: SnappetSpacing.xxl) }
    }

    // MARK: up next (actionable Today cards, #71)

    /// One actionable card: a fact derived from a module's own rows + the route a tap takes.
    private struct TodayCard: Identifiable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
        let tint: Color
        let open: () -> Void
    }

    /// Cards in a fixed habits → workout → focus → budget → climb order; each renders only
    /// when its `TodayDigest` derivation is non-nil (i.e. the module has data).
    private var todayCards: [TodayCard] {
        let cal = Calendar.current
        // `now` is the state clock above — NOT `Date.now` — so cards roll at midnight.
        var cards: [TodayCard] = []
        if let h = TodayDigest.habitsToday(habits: habits, completions: habitCompletions,
                                           now: now, calendar: cal) {
            cards.append(TodayCard(
                id: "habits",
                title: h.allDone ? "All \(h.total) habit\(h.total == 1 ? "" : "s") done"
                                 : "\(h.remaining) habit\(h.remaining == 1 ? "" : "s") left",
                detail: h.allDone ? "Streak safe for today" : "Tap to check off",
                systemImage: h.allDone ? "checkmark.seal.fill" : "checkmark.seal",
                tint: SnappetColor.habits) { router.open(module: "habit") })
        }
        if let r = TodayDigest.resumeWorkout(sessions: workoutSessions) {
            cards.append(TodayCard(
                id: "resumeWorkout",
                title: "Resume \(r.routineName)",
                detail: "Started \(r.startedAt.formatted(.relative(presentation: .named)))",
                systemImage: "dumbbell.fill",
                tint: SnappetColor.workout) {
                    // Carry the intent: the player is a fullScreenCover on WorkoutHomeView's local
                    // state, so the route alone would land on the dashboard with the player closed.
                    router.pendingWorkoutResume = true
                    router.open(module: WorkoutTrackerModule.id)
                })
        }
        if let f = TodayDigest.focusToday(sessions: focusSessions, now: now, calendar: cal) {
            cards.append(TodayCard(
                id: "focus",
                title: f.minutesToday > 0 ? "\(f.minutesToday) focus min today"
                                          : "No focus yet today",
                detail: f.minutesToday > 0 ? "Start another block" : "Start a focus block",
                systemImage: "timer",
                tint: SnappetColor.pomodoro) { router.open(module: "pomodoro") })
        }
        if let b = TodayDigest.budgetPace(categories: budgetCategories,
                                          transactions: budgetTransactions,
                                          now: now, calendar: cal) {
            cards.append(TodayCard(
                id: "budget",
                title: "\(b.spent.asCurrency) of \(b.monthlyBudget.asCurrency)",
                detail: b.onPace ? "On pace this month" : "Over pace this month",
                systemImage: "chart.pie.fill",
                tint: SnappetColor.budget) { router.open(module: "budget") })
        }
        if let resume = activeKilterResume {
            // A plan-backed session is live → resume it, mirroring "Resume <routine>" for Workout.
            // Takes the slot the history-based "Plan tonight's session" card would otherwise fill.
            cards.append(TodayCard(
                id: "resumeKilter",
                title: "Resume climbing session",
                detail: "\(resume.done) of \(resume.total) done",
                systemImage: "figure.climbing",
                tint: SnappetColor.kilter) {
                    router.open(module: "kilter")
                    router.push(KilterPlanRoute())
                })
        } else if let k = TodayDigest.climbPlan(history: kilterEntries.map(KilterClimbLog.from)) {
            cards.append(TodayCard(
                id: "climbPlan",
                title: "Plan tonight's session",
                detail: k.workingGradeLabel.map { "Working grade ~\($0)" }
                    ?? "\(k.loggedClimbs) climb\(k.loggedClimbs == 1 ? "" : "s") logged",
                systemImage: "figure.climbing",
                tint: SnappetColor.kilter) {
                    // Two-level deep link: the module root, then its plan screen.
                    router.open(module: "kilter")
                    router.push(KilterPlanRoute())
                })
        }
        return cards
    }

    /// `(done, total)` of an open plan whose session is still live — drives the "Resume climbing
    /// session" card. `nil` when no plan-backed session is running. Store-derived (reactive via
    /// `@Query`), so it doesn't depend on the live in-memory session manager.
    private var activeKilterResume: (done: Int, total: Int)? {
        let openSessionIds = Set(kilterSessionsQ.filter { $0.endedAt == nil }.map(\.id))
        guard let plan = kilterPlansQ.first(where: { p in
            p.completedAt == nil && (p.sessionId.map(openSessionIds.contains) ?? false)
        }) else { return nil }
        let p = KilterPlanProgress.progress(plan.items)
        return (p.done, p.total)
    }

    @ViewBuilder private var upNext: some View {
        let cards = todayCards
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
                Text("Up next").font(.title3.bold())
                ForEach(cards) { card in
                    Button(action: card.open) {
                        HStack(spacing: SnappetSpacing.md) {
                            Image(systemName: card.systemImage)
                                .font(.title3)
                                .foregroundStyle(card.tint)
                                .frame(width: 36, height: 36)
                                .background(card.tint.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title).font(.headline)
                                    .foregroundStyle(SnappetColor.ink)
                                Text(card.detail).font(.caption)
                                    .foregroundStyle(SnappetColor.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .snappetTile()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.today.\(card.id)")
                }
            }
            .snappetAnimation(SnappetMotion.standard, value: cards.map(\.id))
        }
    }

    // MARK: today

    private var todayStart: Date { Calendar.current.startOfDay(for: now) }
    private var todayRecords: [UsageRecord] { records.filter { $0.timestamp >= todayStart } }

    private var todayRow: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Today").font(.title3.bold())
            HStack(spacing: SnappetSpacing.md) {
                StatTile(value: "\(todayRecords.count)", label: "actions",
                         systemImage: "bolt.fill", tint: SnappetColor.brand)
                StatTile(value: "\(Set(todayRecords.map(\.module)).count)", label: "apps used",
                         systemImage: "square.grid.2x2.fill", tint: SnappetColor.journal)
                StatTile(value: streakText, label: "day streak",
                         systemImage: "flame.fill", tint: SnappetColor.workout)
            }
        }
    }

    // MARK: 7-day chart

    private struct DayCount: Identifiable { let id = UUID(); let day: Date; let count: Int }

    private var lastWeek: [DayCount] {
        let cal = Calendar.current
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: todayStart)!
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            let count = records.filter { $0.timestamp >= day && $0.timestamp < next }.count
            return DayCount(day: day, count: count)
        }
    }

    private var weekChart: some View {
        VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Last 7 days").font(.headline)
            Chart(lastWeek) { d in
                BarMark(x: .value("Day", d.day, unit: .day),
                        // Bars grow up from the baseline on appear (issue #30 §5.2).
                        y: .value("Actions", chartAppeared || reduceMotion ? d.count : 0))
                .foregroundStyle(.tint)
                .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 160)
            .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: chartAppeared)
            .onAppear { chartAppeared = true }
            .onDisappear { chartAppeared = false }
        }
    }

    // MARK: activity feed

    /// Module id → display title for the modules the registry still vends. Doubles as the
    /// known-id set (a feed row deep-links only when its module exists; a record from a removed
    /// module renders as a plain, non-tappable row) and as the row caption source — captions show
    /// the module's *display* title, not the raw persisted id, so a renamed module (e.g.
    /// `workout-log` → "Gym Tracker", #74) reads right while historical ids stay untouched.
    private var moduleTitles: [String: String] {
        Dictionary(uniqueKeysWithValues: ModuleRegistry.all.map { ($0.id, $0.title) })
    }

    private var activityFeed: some View {
        let titles = moduleTitles
        return VStack(alignment: .leading, spacing: SnappetSpacing.sm) {
            Text("Recent activity").font(.headline)
            ForEach(records.prefix(12)) { r in
                VStack(spacing: 0) {
                    if let title = titles[r.module] {
                        // Feed rows deep-link into their module (#71).
                        Button {
                            router.open(module: r.module)
                        } label: {
                            FeedRow(record: r, moduleTitle: title, tappable: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.feedRow.\(r.module)")
                    } else {
                        FeedRow(record: r, moduleTitle: nil, tappable: false)
                    }
                    Divider()
                }
                // New rows slide + fade in (issue #30 §5.2).
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .snappetAnimation(SnappetMotion.standard, value: records.count)
    }

    /// Consecutive days (ending today) with at least one logged action — via the pure
    /// `TodayDigest.activityStreak` so Home and the home-screen widget (#81) share one definition.
    private var streakText: String {
        "\(TodayDigest.activityStreak(records: records, now: now, calendar: Calendar.current))"
    }
}

/// One activity-feed line. Tappable rows get a trailing chevron so the affordance is visible.
private struct FeedRow: View {
    let record: UsageRecord
    /// The module's display title (from the registry); `nil` (retired/unknown id) falls back to
    /// the capitalized raw id — ids are persisted and never renamed (#74), titles are.
    let moduleTitle: String?
    let tappable: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary).font(.subheadline)
                    .foregroundStyle(SnappetColor.ink)
                Text(moduleTitle ?? record.module.capitalized).font(.caption)
                    .foregroundStyle(SnappetColor.textSecondary)
            }
            Spacer()
            Text(record.timestamp, format: .relative(presentation: .numeric))
                .font(.caption).foregroundStyle(.tertiary)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, SnappetSpacing.xs)
        .contentShape(Rectangle())
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String
    let tint: Color
    var body: some View {
        VStack(spacing: SnappetSpacing.xs) {
            // Icon is a non-colour signal so the three tiles are distinguishable without
            // relying on hue alone (issue #30 accessibility).
            Image(systemName: systemImage).font(.subheadline).foregroundStyle(tint)
            Text(value).font(.title.bold()).foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(SnappetColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .snappetTile()
        // Numbers count up rather than snapping (issue #30 §5.2).
        .animation(.snappy, value: value)
    }
}
