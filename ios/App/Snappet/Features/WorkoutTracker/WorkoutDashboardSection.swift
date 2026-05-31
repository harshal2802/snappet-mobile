import SwiftUI
import Charts

/// The Dashboard section: resume-in-progress banner, headline stats, an 8-week volume chart,
/// personal records, and quick-start routines. The entry screen of the workout app.
struct WorkoutDashboardSection: View {
    let history: [WorkoutSession]
    let routines: [Routine]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let activeSession: WorkoutSession?
    let resume: () -> Void
    let goToRoutines: () -> Void
    let goToBrowse: () -> Void

    private var isEmptyState: Bool { history.isEmpty && activeSession == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let activeSession {
                    resumeBanner(activeSession)
                }

                if isEmptyState {
                    emptyState
                } else {
                    statGrid
                    // Only chart weeks that actually have volume — a bodyweight-only history is all
                    // zeroes, and an all-zero chart renders as an empty, broken-looking frame.
                    if weeklyVolume.contains(where: { $0.volumeKg > 0 }) { volumeChart }
                    if !personalRecords.isEmpty { recordsSection }
                }

                // The empty state already points to routines/exercises; don't also show the
                // quick-start list under it (two ways to pick a routine on one screen).
                if !quickStart.isEmpty && !isEmptyState { quickStartSection }
            }
            .padding()
            .padding(.bottom, 24) // clear the suite's floating tab bar
        }
    }

    // MARK: - Banner / empty

    private func resumeBanner(_ session: WorkoutSession) -> some View {
        Button(action: resume) {
            HStack(spacing: 14) {
                Image(systemName: "figure.run.circle.fill").font(.largeTitle).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workout in progress").font(.headline)
                    Text("\(session.routineName) · \(session.completedSetCount) sets logged")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Resume").fontWeight(.semibold).foregroundStyle(.orange)
            }
            .padding()
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dumbbell.fill").font(.system(size: 48)).foregroundStyle(.orange)
            Text("Let's get moving").font(.title3.bold())
            Text("Pick a starter routine or browse 870+ exercises to build your own.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Browse routines", action: goToRoutines).buttonStyle(.borderedProminent).tint(.orange)
                Button("Exercises", action: goToBrowse).buttonStyle(.bordered).tint(.orange)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    // MARK: - Stats

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            WorkoutStatCard(value: "\(history.count)", label: "Workouts", systemImage: "checkmark.seal.fill")
            WorkoutStatCard(value: "\(currentStreak)", label: "Day streak", systemImage: "flame.fill")
            WorkoutStatCard(value: "\(thisWeekCount)", label: "This week", systemImage: "calendar")
            WorkoutStatCard(value: WorkoutMath.formatVolume(kg: totalVolumeKg, unit: unit),
                     label: "Total volume", systemImage: "scalemass.fill")
        }
    }

    private var volumeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Weekly volume").font(.headline)
            Chart(weeklyVolume, id: \.weekStart) { point in
                BarMark(
                    x: .value("Week", point.weekStart, unit: .weekOfYear),
                    y: .value("Volume", WorkoutMath.kgToUnit(point.volumeKg, unit))
                )
                .foregroundStyle(.orange)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisGridLine(); AxisTick() } }
            .frame(height: 160)
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal records").font(.headline)
            ForEach(personalRecords, id: \.exerciseId) { pr in
                NavigationLink(value: ProgressRoute(exerciseId: pr.exerciseId)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolver.name(for: pr.exerciseId)).font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary).lineLimit(1)
                            Text("\(WorkoutMath.sessionCount(history: history, exerciseId: pr.exerciseId)) sessions")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(prText(pr.top)).font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
                if pr.exerciseId != personalRecords.last?.exerciseId { Divider() }
            }
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick start").font(.headline)
            ForEach(quickStart) { routine in
                NavigationLink(value: routine) {
                    HStack {
                        Image(systemName: routine.sport?.symbol ?? "list.bullet").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(routine.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(routine.exercises.count) exercises").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
                if routine.id != quickStart.last?.id { Divider() }
            }
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Derived data

    private struct WeeklyPoint { let weekStart: Date; let volumeKg: Double }
    private struct PRItem { let exerciseId: String; let top: WorkoutMath.TopSet }

    private var thisWeekCount: Int {
        let cal = Calendar.current
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: .now)?.start else { return 0 }
        return history.filter { $0.startedAt >= weekStart }.count
    }

    private var totalVolumeKg: Double {
        history.reduce(0) { $0 + WorkoutMath.sessionVolumeKg($1) }
    }

    /// Consecutive calendar days ending today (or yesterday) with at least one workout.
    private var currentStreak: Int {
        let cal = Calendar.current
        let days = Set(history.map { cal.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }
        let today = cal.startOfDay(for: .now)
        var cursor = days.contains(today) ? today : (cal.date(byAdding: .day, value: -1, to: today) ?? today)
        guard days.contains(cursor) else { return 0 }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
    }

    private var weeklyVolume: [WeeklyPoint] {
        guard !history.isEmpty else { return [] }
        let cal = Calendar.current
        var buckets: [Date: Double] = [:]
        for session in history {
            guard let weekStart = cal.dateInterval(of: .weekOfYear, for: session.startedAt)?.start else { continue }
            buckets[weekStart, default: 0] += WorkoutMath.sessionVolumeKg(session)
        }
        // Last 8 weeks, oldest → newest.
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

    private var quickStart: [Routine] {
        Array(routines.sorted { $0.updatedAt > $1.updatedAt }.prefix(3))
    }

    private func prText(_ top: WorkoutMath.TopSet) -> String {
        top.bestKg > 0
            ? "\(WorkoutMath.formatWeight(kg: top.bestKg, unit: unit)) \(unit.display) × \(top.bestReps)"
            : "\(top.bestReps) reps"
    }
}

/// A small stat tile used on the dashboard.
struct WorkoutStatCard: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(.orange)
            Text(value).font(.title2.bold()).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
