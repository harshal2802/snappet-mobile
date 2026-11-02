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
    /// "See all" beside Recent sessions → the History section (prompt 217; the action was empty).
    let goToHistory: () -> Void
    let openRoutine: (Routine) -> Void
    let openProgress: (String) -> Void
    let openStudio: (UUID) -> Void
    /// Deep-link into a completed session's detail (the recent-feed rows). (#181)
    let openSession: (UUID) -> Void
    /// Start a freeform Quick Session — the type-aware Start CTA. (#181)
    let startQuick: () -> Void
    /// Open the smart-planning screen — the "Plan a session" entry (workout-redesign E7). (#187)
    let openPlan: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chartDrawn = false

    private var isEmptyState: Bool { history.isEmpty && activeSession == nil }
    private var stats: WorkoutDashboardStats { WorkoutDashboardStats.make(history: history) }
    private var recents: [RecentSessions.Row] { RecentSessions.rows(history: history, unit: unit, limit: 5) }
    /// The discipline that themes the hero + Start CTA (the user's recent go-to; ember default).
    private var heroDiscipline: WorkoutDiscipline { stats.dominantRecentDiscipline ?? .strength }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let activeSession { resumeBanner(activeSession) }

                if isEmptyState {
                    emptyState
                } else {
                    heroCard
                    startCTA
                    planEntry
                    if !recents.isEmpty { recentSection }
                    if weeklyVolume.contains(where: { $0.volumeKg > 0 }) { volumeChart }
                    if !personalRecords.isEmpty { recordsSection }
                }

                if !quickStart.isEmpty && !isEmptyState { quickStartSection }
                if !isEmptyState { studioSection }
                // The old "Workout Reels" cross-link is gone with the tile (highlights P3): Apple
                // Watch workouts now land in History + the Clips feed automatically, and highlight
                // reels are an action on every session detail.
            }
            .padding()
            .padding(.bottom, 24)
        }
        .background(SnappetColor.paper)
    }

    // MARK: - Resume banner (discipline-aware)

    private func resumeBanner(_ session: WorkoutSession) -> some View {
        let discipline = WorkoutDashboardStats.dominantDiscipline(of: session) ?? .strength
        return Button(action: resume) {
            HStack(spacing: 12) {
                Image(systemName: discipline.symbol).font(.system(size: 18)).foregroundStyle(SnappetColor.ink)
                    .frame(width: 36, height: 36)
                    .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workout in progress").snappetTitle()
                    Text("\(session.routineName) · \(discipline.label) · \(session.completedSetCount) logged")
                        .snappetDetail().lineLimit(1)
                }
                Spacer()
                Text("Resume").font(.system(size: 14, weight: .semibold)).foregroundStyle(SnappetColor.onBrand)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(SnappetColor.brand, in: Capsule())
            }
            .snappetPanel(glow: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.resumeBanner")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dumbbell").font(.system(size: 40, weight: .light)).foregroundStyle(SnappetColor.textSecondary)
            Text("Let's get moving").snappetTitle()
            Text("Pick a starter routine or browse 870+ exercises to build your own.")
                .snappetDetail().multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button("Browse routines", action: goToRoutines).buttonStyle(.snappetPrimary)
                Button(action: goToBrowse) {
                    Text("Exercises").font(.system(size: 15, weight: .medium)).snappetPill(selected: false, large: true)
                }
                .buttonStyle(.plain)
            }
            // The planner works from a cold start (candidates come from the catalog, focusing untrained
            // muscles for variety) — so invite a beginner to plan a first session here too (#187, E7).
            planEntry.padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    // MARK: - Hero (score-first: active days this week) + per-discipline ribbon + 7-day strip

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Active days this week").snappetLabel()
            SnappetMetric(value: "\(stats.weeklyActiveDays)", unit: stats.weeklyActiveDays == 1 ? "day" : "days")
            Text(stats.currentStreak > 0 ? "\(stats.currentStreak)-day streak · you're on track" : "Start a streak today")
                .snappetDetail()
            if !stats.disciplineCounts.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { disciplinePills }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { disciplinePills } }
                }
                .padding(.top, 8)
            }
            weekStrip.padding(.top, 10)
        }
        .snappetPanel()
    }

    @ViewBuilder private var disciplinePills: some View {
        ForEach(stats.disciplineCounts, id: \.discipline) { c in
            Label("\(c.count) \(Self.shortLabel(c.discipline, count: c.count))", systemImage: c.discipline.symbol)
                .font(.system(size: 12)).padding(.horizontal, -3).padding(.vertical, -2)
                .snappetPill(selected: false)
        }
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
                        .fill(did ? SnappetColor.brand : SnappetColor.hairline)
                        .frame(width: 8, height: 8)
                    Text(Self.weekdayInitial(day, cal: cal))
                        .font(.system(size: 10, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? SnappetColor.ink : SnappetColor.textTertiary)
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
        }
        .buttonStyle(SnappetWidePrimaryStyle())
        .accessibilityIdentifier("workout.dashboardStart")
    }

    // MARK: - Smart-planning entry (#187 — E7)

    /// A calm "Plan a session" row that opens the smart planner — a verb read of today + an editable
    /// suggested session. Not a coral CTA (Start owns that); a quiet wayfinding row on `surfaceMuted`.
    private var planEntry: some View {
        Button(action: openPlan) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 14)).foregroundStyle(SnappetColor.ink)
                    .frame(width: 32, height: 32)
                    .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plan a session").font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink)
                    Text("A suggested workout for what you've rested").snappetDetail()
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SnappetColor.textTertiary)
            }
            .snappetPanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.dashboardPlan")
    }

    // MARK: - Recent sessions feed (#181 — the previously-missing surface)

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent sessions").snappetTitle()
                Spacer()
                Button("See all ›", action: goToHistory)
                    .font(SnappetType.detail).foregroundStyle(SnappetColor.brand)
                    .accessibilityIdentifier("workout.recentSeeAll")
            }
            .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(recents) { row in
                    if row.id != recents.first?.id { Divider().overlay(SnappetColor.hairline) }
                    Button { openSession(row.id) } label: { RecentSessionCard(row: row) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workout.recentSession")
                }
            }
            .padding(.horizontal, SnappetSpacing.lg).padding(.vertical, 2)
            .background(SnappetColor.surface, in: RoundedRectangle(cornerRadius: SnappetRadius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SnappetRadius.panel, style: .continuous).strokeBorder(SnappetColor.hairline))
        }
    }

    // MARK: - Weekly volume chart (carried over; strength volume)

    private var volumeChart: some View {
        let thisWeek = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start
        let current = weeklyVolume.first { $0.weekStart == thisWeek }?.volumeKg ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack { Text("Weekly volume").snappetLabel(); Spacer(); Text("this week").snappetLabel() }
            SnappetMetric(value: WorkoutMath.kgToUnit(current, unit).formatted(.number.precision(.fractionLength(0))),
                          unit: unit == .kg ? "kg" : "lb")
            Chart(weeklyVolume, id: \.weekStart) { point in
                BarMark(
                    x: .value("Week", point.weekStart, unit: .weekOfYear),
                    y: .value("Volume", chartDrawn || reduceMotion ? WorkoutMath.kgToUnit(point.volumeKg, unit) : 0),
                    width: .ratio(0.6)
                )
                .foregroundStyle(point.weekStart == thisWeek ? SnappetColor.brand : SnappetColor.hairline)
                .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        .font(.system(size: 9.5)).foregroundStyle(SnappetColor.textTertiary)
                }
            }
            .frame(height: 90)
            .padding(.top, 6)
            .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: chartDrawn)
            .onAppear { chartDrawn = true }
            .onDisappear { chartDrawn = false }
        }
        .snappetPanel()
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal records").snappetLabel()
            ForEach(personalRecords, id: \.exerciseId) { pr in
                Button { openProgress(pr.exerciseId) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolver.name(for: pr.exerciseId)).font(.system(size: 15, weight: .medium))
                                .foregroundStyle(SnappetColor.ink).lineLimit(1)
                            Text("\(WorkoutMath.sessionCount(history: history, exerciseId: pr.exerciseId)) sessions")
                                .snappetDetail()
                        }
                        Spacer()
                        Text(prText(pr.top)).font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundStyle(SnappetColor.ink)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SnappetColor.textTertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if pr.exerciseId != personalRecords.last?.exerciseId { Divider().overlay(SnappetColor.hairline) }
            }
        }
        .snappetPanel()
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick start").snappetLabel()
            ForEach(quickStart) { routine in
                Button { openRoutine(routine) } label: {
                    HStack {
                        Image(systemName: routine.sport?.symbol ?? "list.bullet").font(.system(size: 14))
                            .foregroundStyle(SnappetColor.ink)
                            .frame(width: 32, height: 32)
                            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(routine.name).font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                            Text("\(routine.exercises.count) exercise\(routine.exercises.count == 1 ? "" : "s")").snappetDetail()
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SnappetColor.textTertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if routine.id != quickStart.last?.id { Divider().overlay(SnappetColor.hairline) }
            }
        }
        .snappetPanel()
    }

    private var studioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Video Studio").snappetLabel()
            if studioCandidates.isEmpty {
                Text("Film your sets, add the clips to a finished workout, and cut them into a shareable edit here.")
                    .snappetDetail()
            } else {
                ForEach(studioCandidates) { candidate in
                    Button { openStudio(candidate.sessionID) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.title).font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                                Text("\(candidate.startedAt.formatted(.dateTime.month().day())) · \(candidate.videoCount) clip\(candidate.videoCount == 1 ? "" : "s")")
                                    .snappetDetail()
                            }
                            Spacer()
                            Text("Open in Studio").font(SnappetType.detail).foregroundStyle(SnappetColor.brand)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SnappetColor.textTertiary)
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workout.studioCandidate")
                    if candidate.id != studioCandidates.last?.id { Divider().overlay(SnappetColor.hairline) }
                }
            }
        }
        .snappetPanel()
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
            ? "\(WorkoutMath.setWeight(kg: top.bestKg, unit: unit)) × \(top.bestReps)"
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
        case .racket:   singular = "match"
        }
        return count == 1 ? singular : (singular == "dance" ? "dances" : singular == "match" ? "matches" : singular + "s")
    }

    static func weekdayInitial(_ date: Date, cal: Calendar) -> String {
        let i = cal.component(.weekday, from: date) - 1   // 0=Sun
        return ["S", "M", "T", "W", "T", "F", "S"][max(0, min(6, i))]
    }
}

/// One recent-session row (prompt 217): a neutral glyph tile, the title + an outlined PR tag, the type-adaptive
/// facts (`RecentSessions.Row.facts`) as one grey line, and the date · duration.
struct RecentSessionCard: View {
    let row: RecentSessions.Row

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.discipline.symbol).font(.system(size: 14)).foregroundStyle(SnappetColor.ink)
                .frame(width: 32, height: 32)
                .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 15, weight: .medium)).foregroundStyle(SnappetColor.ink).lineLimit(1)
                    if row.isPR {
                        Text("PR").font(.system(size: 10.5)).foregroundStyle(SnappetColor.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(SnappetColor.hairline))
                    }
                }
                if !row.facts.isEmpty {
                    Text(row.facts.joined(separator: " · ")).snappetDetail().lineLimit(1)
                }
                Text("\(row.date.formatted(.dateTime.weekday().month().day())) · \(row.durationMinutes) min")
                    .font(SnappetType.label).foregroundStyle(SnappetColor.textTertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SnappetColor.textTertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
