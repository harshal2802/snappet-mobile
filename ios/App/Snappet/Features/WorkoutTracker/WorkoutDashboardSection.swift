import SwiftUI
import Charts

/// The Dashboard section: resume-in-progress banner, headline stats, an 8-week volume chart,
/// personal records, quick-start routines, the **Video Studio** card (#74 — the module-level
/// entry into the multi-clip editor), and a cross-link to Workout Reels for anyone who came
/// looking for their Apple Watch workouts. The entry screen of the gym tracker.
struct WorkoutDashboardSection: View {
    let history: [WorkoutSession]
    let routines: [Routine]
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let activeSession: WorkoutSession?
    /// Recent media-bearing sessions the Video Studio card offers (#74); empty renders the card's
    /// how-to hint instead, so the studio is still discoverable before any video exists.
    let studioCandidates: [StudioEntry.Candidate]
    let resume: () -> Void
    let goToRoutines: () -> Void
    let goToBrowse: () -> Void
    let openRoutine: (Routine) -> Void
    let openProgress: (String) -> Void
    /// Open the Video Studio over the given session id (#74).
    let openStudio: (UUID) -> Void
    /// Jump to the Workout Reels module (#74 cross-link — the misdirected "where are my watch
    /// workouts?" tap lands here, especially on a fresh gym-tracker install).
    let openReels: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the weekly-volume bars' grow-in animation on appear.
    @State private var chartDrawn = false

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

                // Video Studio (#74): the module-level entry — recent sessions with video open
                // straight into the multi-clip editor; without any it explains how to get there.
                // Hidden on the empty state (nothing to cut and the screen already onboards).
                if !isEmptyState { studioSection }

                // Cross-link (#74): always last, including the empty state — a user who tapped
                // the gym tracker after an Apple Watch run has zero history and wants Reels.
                reelsCrossLink
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
                    // Bars grow up from the baseline on appear (issue #30 §5.6).
                    y: .value("Volume", chartDrawn || reduceMotion ? WorkoutMath.kgToUnit(point.volumeKg, unit) : 0)
                )
                .foregroundStyle(.orange)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear)) { _ in AxisGridLine(); AxisTick() } }
            .frame(height: 160)
            .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: chartDrawn)
            .onAppear { chartDrawn = true }
            .onDisappear { chartDrawn = false }
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
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
                            .foregroundStyle(.orange)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                if pr.exerciseId != personalRecords.last?.exerciseId { Divider() }
            }
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick start").font(.headline)
            ForEach(quickStart) { routine in
                Button { openRoutine(routine) } label: {
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
                .buttonStyle(.plain)
                if routine.id != quickStart.last?.id { Divider() }
            }
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The Video Studio card (#74): "Open in Studio" rows for the most recent sessions carrying
    /// tagged video, or a one-line how-to when none do yet — either way the editor is named on
    /// the module's front page instead of hiding four levels deep.
    private var studioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack").foregroundStyle(.orange)
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
                                Text(candidate.title).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary).lineLimit(1)
                                Text("\(candidate.startedAt.formatted(.dateTime.month().day())) · \(candidate.videoCount) clip\(candidate.videoCount == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Open in Studio").font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workout.studioCandidate")
                    if candidate.id != studioCandidates.last?.id { Divider() }
                }
            }
        }
        .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The "wrong module?" escape hatch (#74): the suite's other fitness card cuts highlight reels
    /// from completed Apple Watch workouts — name it here so the misdirected tap costs one more.
    private var reelsCrossLink: some View {
        Button(action: openReels) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run").foregroundStyle(SnappetColor.reels)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Looking for your Apple Watch workouts?")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("Highlight reels from watch workouts live in Workout Reels.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.openReels")
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
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }
}
