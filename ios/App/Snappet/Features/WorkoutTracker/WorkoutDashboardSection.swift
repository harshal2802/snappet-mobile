import SwiftUI
import Charts

/// The Dashboard section (workout-redesign E1 — Pulse Pro). The entry screen of the gym tracker, now
/// **discipline-aware**: a discipline-aware resume banner, a score-first hero (active days this week) with
/// a per-discipline ribbon + a calm 7-day consistency strip, a type-aware Start CTA, and — the biggest
/// previous gap — a **recent-sessions feed** (mixed-type cards with a discipline accent edge-bar + a
/// type-adaptive 3-fact rollup + a PR pill) deep-linking into each session. The weekly-volume chart,
/// personal records, quick-start, Video Studio card, and Reels cross-link carry over. All figures come
/// from the pure `WorkoutDashboardStats` + `RecentSessions` (no inline view math).
struct WorkoutDashboardSection: View {
    let history: [WorkoutSession]
    let routines: [Routine]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let activeSession: WorkoutSession?
    let studioCandidates: [StudioEntry.Candidate]
    let resume: () -> Void
    let goToRoutines: () -> Void
    let goToBrowse: () -> Void
    let openRoutine: (Routine) -> Void
    let openProgress: (String) -> Void
    let openStudio: (UUID) -> Void
    let openReels: () -> Void
    /// Deep-link into a completed session's detail (the recent-feed rows). (#181)
    let openSession: (UUID) -> Void
    /// Start a freeform Quick Session — the type-aware Start CTA. (#181)
    let startQuick: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chartDrawn = false

    private var isEmptyState: Bool { history.isEmpty && activeSession == nil }
    private var stats: WorkoutDashboardStats { WorkoutDashboardStats.make(history: history) }
    private var recents: [RecentSessions.Row] { RecentSessions.rows(history: history, unit: unit, limit: 5) }
    /// The discipline that themes the hero + Start CTA (the user's recent go-to; ember default).
    private var heroDiscipline: WorkoutDiscipline { stats.dominantRecentDiscipline ?? .strength }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let activeSession { resumeBanner(activeSession) }

                if isEmptyState {
                    emptyState
                } else {
                    heroCard
                    startCTA
                    if !recents.isEmpty { recentSection }
                    if weeklyVolume.contains(where: { $0.volumeKg > 0 }) { volumeChart }
                    if !personalRecords.isEmpty { recordsSection }
                }

                if !quickStart.isEmpty && !isEmptyState { quickStartSection }
                if !isEmptyState { studioSection }
                reelsCrossLink
            }
            .padding()
            .padding(.bottom, 24)
        }
    }

    // MARK: - Resume banner (discipline-aware)

    private func resumeBanner(_ session: WorkoutSession) -> some View {
        let discipline = WorkoutDashboardStats.dominantDiscipline(of: session) ?? .strength
        return Button(action: resume) {
            HStack(spacing: 14) {
                Image(systemName: discipline.symbol).font(.largeTitle).foregroundStyle(discipline.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workout in progress").font(.headline)
                    Text("\(session.routineName) · \(discipline.label) · \(session.completedSetCount) logged")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("Resume").fontWeight(.semibold).foregroundStyle(discipline.accent)
            }
            .padding()
            .background(discipline.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.resumeBanner")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dumbbell.fill").font(.system(size: 48)).foregroundStyle(SnappetColor.workout)
            Text("Let's get moving").font(.title3.bold())
            Text("Pick a starter routine or browse 870+ exercises to build your own.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Browse routines", action: goToRoutines).buttonStyle(.borderedProminent).tint(SnappetColor.workout)
                Button("Exercises", action: goToBrowse).buttonStyle(.bordered).tint(SnappetColor.workout)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    // MARK: - Hero (score-first: active days this week) + per-discipline ribbon + 7-day strip

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisciplineHero(value: "\(stats.weeklyActiveDays)",
                           caption: "Active days this week",
                           sublabel: stats.currentStreak > 0 ? "\(stats.currentStreak)-day streak · you're on track" : "Start a streak today",
                           systemImage: "flame.fill",
                           accent: heroDiscipline.accent)
            if !stats.disciplineCounts.isEmpty {
                StatRibbon(items: stats.disciplineCounts.map {
                    StatRibbon.Item(text: "\($0.count) \(Self.shortLabel($0.discipline, count: $0.count))",
                                    tint: $0.discipline.accent, emphasized: true, systemImage: $0.discipline.symbol)
                })
            }
            weekStrip
        }
        .snappetCard()
    }

    /// A calm 7-day consistency strip — a dot per day (filled when trained), today in coral.
    private var weekStrip: some View {
        let cal = Calendar.current
        let trained = Set(history.map { cal.startOfDay(for: $0.startedAt) })
        let today = cal.startOfDay(for: .now)
        return HStack(spacing: 8) {
            ForEach((0..<7).reversed(), id: \.self) { back in
                let day = cal.date(byAdding: .day, value: -back, to: today) ?? today
                let isToday = back == 0
                let did = trained.contains(day)
                VStack(spacing: 4) {
                    Circle()
                        .fill(did ? (isToday ? SnappetColor.brand : SnappetColor.ink)
                                  : SnappetColor.surfaceMuted)
                        .frame(width: 10, height: 10)
                    Text(Self.weekdayInitial(day, cal: cal))
                        .font(.caption2.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? SnappetColor.brand : SnappetColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Type-aware Start

    private var startCTA: some View {
        Button(action: startQuick) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("Start \(heroDiscipline.label.lowercased())").fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(SnappetColor.brand, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.dashboardStart")
    }

    // MARK: - Recent sessions feed (#181 — the previously-missing surface)

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent sessions").font(.headline)
                Spacer()
                Button("See all", action: { /* History tab */ }).font(.caption).foregroundStyle(SnappetColor.textSecondary)
                    .accessibilityHidden(true)
            }
            ForEach(recents) { row in
                Button { openSession(row.id) } label: { RecentSessionCard(row: row) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workout.recentSession")
            }
        }
    }

    // MARK: - Weekly volume chart (carried over; strength volume)

    private var volumeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly volume").font(.headline)
            Chart(weeklyVolume, id: \.weekStart) { point in
                BarMark(
                    x: .value("Week", point.weekStart, unit: .weekOfYear),
                    y: .value("Volume", chartDrawn || reduceMotion ? WorkoutMath.kgToUnit(point.volumeKg, unit) : 0)
                )
                .foregroundStyle(SnappetColor.workout)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisGridLine(); AxisTick() } }
            .frame(height: 160)
            .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: chartDrawn)
            .onAppear { chartDrawn = true }
            .onDisappear { chartDrawn = false }
        }
        .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal records").font(.headline)
            ForEach(personalRecords, id: \.exerciseId) { pr in
                Button { openProgress(pr.exerciseId) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolver.name(for: pr.exerciseId)).font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary).lineLimit(1)
                            Text("\(WorkoutMath.sessionCount(history: history, exerciseId: pr.exerciseId)) sessions")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(prText(pr.top)).font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(SnappetColor.workout)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if pr.exerciseId != personalRecords.last?.exerciseId { Divider() }
            }
        }
        .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick start").font(.headline)
            ForEach(quickStart) { routine in
                Button { openRoutine(routine) } label: {
                    HStack {
                        Image(systemName: routine.sport?.symbol ?? "list.bullet").foregroundStyle(SnappetColor.workout)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(routine.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("\(routine.exercises.count) exercises").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if routine.id != quickStart.last?.id { Divider() }
            }
        }
        .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var studioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack").foregroundStyle(SnappetColor.workout)
                Text("Video Studio").font(.headline)
            }
            if studioCandidates.isEmpty {
                Text("Film your sets, add the clips to a finished workout, and cut them into a shareable edit here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(studioCandidates) { candidate in
                    Button { openStudio(candidate.sessionID) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text("\(candidate.startedAt.formatted(.dateTime.month().day())) · \(candidate.videoCount) clip\(candidate.videoCount == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Open in Studio").font(.caption.weight(.semibold)).foregroundStyle(SnappetColor.workout)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workout.studioCandidate")
                    if candidate.id != studioCandidates.last?.id { Divider() }
                }
            }
        }
        .padding().background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }

    private var reelsCrossLink: some View {
        Button(action: openReels) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run").foregroundStyle(SnappetColor.reels)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Looking for your Apple Watch workouts?").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("Highlight reels from watch workouts live in Workout Reels.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.openReels")
    }

    // MARK: - Derived data (volume chart + PRs carry over)

    private struct WeeklyPoint { let weekStart: Date; let volumeKg: Double }
    private struct PRItem { let exerciseId: String; let top: WorkoutMath.TopSet }

    private var weeklyVolume: [WeeklyPoint] {
        guard !history.isEmpty else { return [] }
        let cal = Calendar.current
        var buckets: [Date: Double] = [:]
        for session in history {
            guard let weekStart = cal.dateInterval(of: .weekOfYear, for: session.startedAt)?.start else { continue }
            buckets[weekStart, default: 0] += WorkoutMath.sessionVolumeKg(session)
        }
        return buckets.keys.sorted().suffix(8).map { WeeklyPoint(weekStart: $0, volumeKg: buckets[$0] ?? 0) }
    }

    private var personalRecords: [PRItem] {
        let ids = Set(history.flatMap { $0.exercises.map(\.exerciseId) })
        return ids.compactMap { id in
            WorkoutMath.topSet(history: history, exerciseId: id).map { PRItem(exerciseId: id, top: $0) }
        }
        .sorted { ($0.top.bestKg * Double($0.top.bestReps)) > ($1.top.bestKg * Double($1.top.bestReps)) }
        .prefix(5).map { $0 }
    }

    private var quickStart: [Routine] { Array(routines.sorted { $0.updatedAt > $1.updatedAt }.prefix(3)) }

    private func prText(_ top: WorkoutMath.TopSet) -> String {
        top.bestKg > 0
            ? "\(WorkoutMath.formatWeight(kg: top.bestKg, unit: unit)) \(unit.display) × \(top.bestReps)"
            : "\(top.bestReps) reps"
    }

    // MARK: - Small label helpers

    /// Short plural discipline label for the ribbon ("2 lifts · 5 climbs · 1 run").
    static func shortLabel(_ d: WorkoutDiscipline, count: Int) -> String {
        let singular: String
        switch d {
        case .strength: singular = "lift"
        case .climb:    singular = "climb"
        case .run:      singular = "run"
        case .timed:    singular = "timed session"
        case .dance:    singular = "dance"
        case .other:    singular = "session"
        }
        return count == 1 ? singular : (singular == "dance" ? "dances" : singular + "s")
    }

    static func weekdayInitial(_ date: Date, cal: Calendar) -> String {
        let i = cal.component(.weekday, from: date) - 1   // 0=Sun
        return ["S", "M", "T", "W", "T", "F", "S"][max(0, min(6, i))]
    }
}

/// One recent-session feed card: a discipline accent edge-bar + glyph, the title + a type-adaptive 3-fact
/// rollup (`RecentSessions.Row.facts`), an optional coral PR pill, and the date · duration.
struct RecentSessionCard: View {
    let row: RecentSessions.Row

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(row.discipline.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: row.discipline.symbol).font(.subheadline).foregroundStyle(row.discipline.accent)
                    Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if row.isPR {
                        Text("PR").font(.caption2.weight(.heavy))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(SnappetColor.brand)
                            .background(SnappetColor.brand.opacity(0.15), in: Capsule())
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                if !row.facts.isEmpty {
                    StatRibbon(items: row.facts.enumerated().map { i, f in
                        StatRibbon.Item(text: f, tint: row.discipline.accent, emphasized: i == 0)
                    })
                }
                Text("\(row.date.formatted(.dateTime.weekday().month().day())) · \(row.durationMinutes) min")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, 11).padding(.vertical, 11).padding(.trailing, 12)
        }
        .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        .overlay(RoundedRectangle(cornerRadius: SnappetRadius.md).strokeBorder(SnappetColor.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
    }
}

/// A small stat tile (retained for any callers; the dashboard now leads with `DisciplineHero`).
struct WorkoutStatCard: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(SnappetColor.workout)
            Text(value).font(.title2.bold()).minimumScaleFactor(0.6).lineLimit(1)
                .monospacedDigit().contentTransition(.numericText()).animation(.snappy, value: value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }
}
