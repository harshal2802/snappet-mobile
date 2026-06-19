import SwiftUI
import HighlightEngine

/// **The shared type-adaptive session recap scaffold** (workout-redesign E0). Extracted verbatim from
/// `FreeformDoneSummaryView` so the post-Finish summary AND the completed-session detail (E2) render the
/// SAME hero + per-discipline cards instead of two divergent surfaces. The scaffold has slots:
///   • **Hero** — `SessionRecapHero` renders three type-chosen stat cells (`SessionRecap.heroCells`).
///   • **Cards** — `SessionRecapCards` renders the discipline-adaptive secondary viz + breakdown
///     (climbing pyramid/timeline/effort · timed rows · running rows + zones · strength PRs/volume).
/// The seal/celebration, the Studio CTA, and the action bar stay with each host (they differ between the
/// Finish screen and the detail screen). Pure SwiftUI over value reads — no SwiftData fetch in here.
enum SessionRecap {

    /// The three hero cells, adapting to the session's dominant kind. Moved unchanged from
    /// `FreeformDoneSummaryView.heroCells` so both hosts pick the identical hero metric. Honest
    /// degradation: climbing with no timed climb shows "Climbs" (count), not a faked "On the wall" time.
    static func heroCells(stats: FreeformSummary.Stats,
                          climbStats: KilterSessionStats,
                          session: WorkoutSession,
                          unit: WeightUnit,
                          milestones: [FreeformSummary.Milestone]) -> [FreeformSummary.Stat] {
        typealias Stat = FreeformSummary.Stat
        switch stats.dominant {
        case .climbing:
            let s = climbStats
            let wall = s.timeline.compactMap(\.timeOnClimb).reduce(0, +)
            let third: Stat = wall > 0
                ? Stat(value: SetMeasure.formatDuration(wall), label: "On the wall")
                : Stat(value: "\(s.totalClimbs)", label: "Climbs")
            return [Stat(value: "\(s.sends)", label: "Sends"),
                    Stat(value: s.hardestSendGrade ?? "—", label: "Hardest"),
                    third]
        case .timed:
            return [Stat(value: SetMeasure.formatDuration(FreeformSummary.holdTimeSeconds(session)), label: "Hold time"),
                    Stat(value: bestHoldLabel(session), label: "Best"),
                    stats.sets]
        case .lifting:
            return [stats.headline, stats.sets, Stat(value: "\(prCount(milestones))", label: "PRs")]
        case .running:
            let t = runTotals(session)
            let du = distanceUnit(unit)
            let pace = (t.meters > 0 && t.seconds > 0)
                ? SetMeasure.formatPace(secPerKm: t.seconds / (t.meters / 1000), unit: du) : "—"
            return [Stat(value: SetMeasure.formatDistance(t.meters, unit: du), label: "Distance"),
                    Stat(value: pace, label: "Pace"),
                    stats.duration]
        case .dance, .other:
            return [stats.headline, stats.duration, stats.sets]
        case .none:
            return [stats.duration, stats.sets, stats.headline]
        }
    }

    // MARK: - Pure shared derivations (used by heroCells + the cards)

    static func distanceUnit(_ unit: WeightUnit) -> DistanceUnit { unit == .lb ? .mi : .km }

    /// Session-wide running totals (Σ distance / Σ time across all completed run legs).
    static func runTotals(_ session: WorkoutSession) -> (meters: Double, seconds: Double) {
        var m = 0.0, s = 0.0
        for ex in session.exercises where ex.discipline == .run {
            for set in ex.sets where set.completedAt != nil {
                m += set.distanceMeters ?? 0
                s += set.durationSec ?? 0
            }
        }
        return (m, s)
    }

    static func bestHoldLabel(_ session: WorkoutSession) -> String {
        let best = session.exercises
            .filter { $0.kind == .duration && $0.discipline != .run }
            .flatMap { $0.sets.filter { $0.completedAt != nil } }
            .compactMap(\.durationSec)
            .max() ?? 0
        return best > 0 ? SetMeasure.formatDuration(best) : "—"
    }

    static func prCount(_ milestones: [FreeformSummary.Milestone]) -> Int {
        milestones.reduce(0) { count, m in
            if case .personalRecord = m { return count + 1 }
            return count
        }
    }
}

/// The hero strip — three type-adaptive stat cells. Renders whatever `SessionRecap.heroCells` produced.
struct SessionRecapHero: View {
    let cells: [FreeformSummary.Stat]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(cells.indices, id: \.self) { i in
                cell(cells[i])
            }
        }
    }

    private func cell(_ stat: FreeformSummary.Stat) -> some View {
        VStack(spacing: 4) {
            Text(stat.value).font(.title2.bold().monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(stat.label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
    }
}

/// The discipline-adaptive cards (secondary viz + breakdown). Moved verbatim from
/// `FreeformDoneSummaryView` so the recap renders identically wherever it's hosted. `milestones` drives
/// the strength "Personal records" card (the Finish screen passes its computed list; a past-session host
/// may pass `[]`). `maxHR` gates the HR Effort block.
struct SessionRecapCards: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    let maxHR: Double
    var milestones: [FreeformSummary.Milestone] = []
    /// Whether to render the HR Effort block (climb/run). The Finish summary shows it here (default);
    /// the session detail passes `false` because it already has a dedicated Heart-rate section (E2).
    var showsHR: Bool = true

    private var stats: FreeformSummary.Stats { FreeformSummary.stats(for: session, unit: unit) }
    private var dominant: FreeformSummary.Dominant { stats.dominant }

    private var climbStats: KilterSessionStats {
        FreeformClimbStats.stats(for: session, now: .now,
                                 hrSeries: session.hrSeries.map {
                                     HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs)
                                 })
    }
    private var hrStats: WorkoutHRStats? {
        guard !session.hrSeries.isEmpty else { return nil }
        return WorkoutHRStats.make(from: session.hrSeries, maxHR: maxHR)
    }

    var body: some View {
        switch dominant {
        case .climbing: climbingCards
        case .timed:    timedCards
        case .lifting:  strengthCards
        case .running:  runningCards
        case .dance, .other: timedCards
        case .none:     EmptyView()
        }
    }

    @ViewBuilder private var climbingCards: some View {
        let s = climbStats
        VStack(alignment: .leading, spacing: 10) {
            ClimbSummarySectionTitle("Effort", systemImage: "figure.climbing")
            recapRow("Sends per hour", s.sendsPerHour > 0 ? String(format: "%.1f", s.sendsPerHour) : "—")
            recapRow("Total attempts", "\(s.totalAttempts)")
            if let median = s.medianTimeOnClimb {
                recapRow("Median time on climb", SetMeasure.formatDuration(median))
            }
        }
        .padding()
        .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))

        ClimbGradePyramid(pyramid: s.pyramid)
        ClimbTimelineList(timeline: s.timeline)
        if showsHR, let hrStats { ClimbEffortSection(hr: hrStats) }
    }

    @ViewBuilder private var timedCards: some View {
        let rows = timedExerciseRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ClimbSummarySectionTitle("Exercises", systemImage: "timer")
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: "timer").font(.caption).foregroundStyle(SnappetColor.workout)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(row.sets) \(row.sets == 1 ? "set" : "sets") · \(SetMeasure.formatDuration(row.tut)) total")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let best = row.best, best > 0 {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(SetMeasure.formatDuration(best))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                Text("best").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("freeform.summaryTimedRow")
                }
            }
            .padding()
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }
    }

    @ViewBuilder private var runningCards: some View {
        let rows = runExerciseRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ClimbSummarySectionTitle("Runs", systemImage: "figure.run")
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: "figure.run").font(.caption).foregroundStyle(SnappetColor.budget)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text("\(row.legs) \(row.legs == 1 ? "leg" : "legs") · \(SetMeasure.formatDistance(row.meters, unit: SessionRecap.distanceUnit(unit)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let pace = row.pace {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(SetMeasure.formatPace(secPerKm: pace, unit: SessionRecap.distanceUnit(unit)))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                Text("pace").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("freeform.summaryRunRow")
                }
            }
            .padding()
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }
        if showsHR, let hrStats { ClimbEffortSection(hr: hrStats) }
    }

    @ViewBuilder private var strengthCards: some View {
        let prs = milestones.compactMap { milestone -> (id: String, value: String)? in
            guard case let .personalRecord(exerciseId, bestKg, reps) = milestone else { return nil }
            let weight = WorkoutMath.formatVolume(kg: bestKg, unit: unit)
            return (exerciseId, "\(reps) × \(weight)")
        }
        if !prs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ClimbSummarySectionTitle("Personal records", systemImage: "trophy.fill")
                ForEach(prs, id: \.id) { pr in
                    recapRow(resolver.name(for: pr.id), pr.value)
                }
            }
            .padding()
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }

        let volumes = liftingVolumeRows
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ClimbSummarySectionTitle("Volume", systemImage: "scalemass.fill")
                ForEach(volumes) { row in
                    recapRow(row.name, "\(row.sets) \(row.sets == 1 ? "set" : "sets") · \(WorkoutMath.formatVolume(kg: row.volumeKg, unit: unit))")
                }
            }
            .padding()
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }
    }

    private func recapRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: - Per-exercise rows (need the resolver for names)

    private struct TimedRow: Identifiable { let id: UUID; let name: String; let sets: Int; let tut: TimeInterval; let best: TimeInterval? }
    private var timedExerciseRows: [TimedRow] {
        session.exercises.compactMap { ex -> TimedRow? in
            guard ex.kind == .duration, ex.discipline != .run else { return nil }
            let completed = ex.sets.filter { $0.completedAt != nil }
            guard !completed.isEmpty else { return nil }
            let durations = completed.compactMap(\.durationSec)
            return TimedRow(id: ex.id, name: resolver.name(for: ex.exerciseId, override: ex.displayName),
                            sets: completed.count, tut: durations.reduce(0, +), best: durations.max())
        }
    }

    private struct RunRow: Identifiable { let id: UUID; let name: String; let legs: Int; let meters: Double; let pace: Double? }
    private var runExerciseRows: [RunRow] {
        session.exercises.compactMap { ex -> RunRow? in
            guard ex.discipline == .run else { return nil }
            let completed = ex.sets.filter { $0.completedAt != nil }
            guard !completed.isEmpty else { return nil }
            return RunRow(id: ex.id, name: resolver.name(for: ex.exerciseId, override: ex.displayName),
                          legs: completed.count, meters: RunStats.totalDistanceMeters(ex), pace: RunStats.avgPaceSecPerKm(ex))
        }
    }

    private struct VolumeRow: Identifiable { let id: UUID; let name: String; let sets: Int; let volumeKg: Double }
    private var liftingVolumeRows: [VolumeRow] {
        session.exercises.compactMap { ex -> VolumeRow? in
            guard ex.kind == .repsWeight else { return nil }
            let completed = ex.sets.filter { $0.completedAt != nil }
            guard !completed.isEmpty else { return nil }
            let volume = completed.reduce(0.0) { sum, set in
                guard let reps = set.actualReps, let weight = set.actualWeight else { return sum }
                return sum + WorkoutMath.toKg(weight, set.weightUnit) * Double(reps)
            }
            return VolumeRow(id: ex.id, name: resolver.name(for: ex.exerciseId, override: ex.displayName),
                             sets: completed.count, volumeKg: volume.rounded())
        }
    }
}
