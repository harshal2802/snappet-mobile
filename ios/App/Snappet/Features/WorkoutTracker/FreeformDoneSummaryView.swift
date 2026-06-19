import SwiftUI
import SwiftData
import HighlightEngine

/// The **type-adaptive completion summary** (Quick Session redesign Phase 7) — the post-workout recap the
/// freeform player shows on Finish. It replaces the old fixed three-stat done-screen with a SCROLLABLE
/// recap whose hero strip and cards adapt to the session's `FreeformSummary.dominant(for:)` kind:
///
/// - **Climbing** → hero Sends · Hardest · On-the-wall(time) (degrades to "Climbs" when no climb was
///   timed); the full grade pyramid + sends/hr · median · tries, the per-climb timeline (top N,
///   expandable), and — only when the session carries HR — the Effort zone-bar. The pyramid / zone-bar /
///   timeline are the SHARED `ClimbGradePyramid` / `ClimbEffortSection` / `ClimbTimelineList`, the exact
///   views the live `LiveClimbStatsSheet` shows (no duplication).
/// - **Timed** → hero Hold time · Best · Sets; per-exercise rows (name · sets · TUT · best hold).
/// - **Strength** → hero Volume · Sets · PRs; the session's PRs list + per-exercise volume.
///
/// Honest degradation: figures come ONLY from the pure `FreeformSummary` + `FreeformClimbStats` (no model
/// migration), and a card is omitted rather than faked when its data is absent (no per-climb timing → no
/// "on the wall" hero / time column; no HR → no Effort block). The milestone seal/headline +
/// `CelebrationBurst`, the Done / View detail / Keep going / Discard actions, and the "Turn N clips into a
/// reel" Studio CTA (when video clips exist) all carry over from the old screen with the same a11y ids.
struct FreeformDoneSummaryView: View {
    @Bindable var session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit
    /// Milestones reached this session (computed by the player against prior history before presenting).
    let milestones: [FreeformSummary.Milestone]
    /// The zone ceiling for the Effort block — the session's snapshot, else the live profile, else default.
    let maxHR: Double

    let onDone: () -> Void
    let onViewDetail: () -> Void
    let onKeepGoing: () -> Void
    let onDiscard: () -> Void
    /// Open the whole-session project in the shared Studio editor (the "Turn N clips into a reel" CTA).
    let onOpenStudio: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.modelContext) private var context

    @State private var doneBounce = 0
    @State private var celebrationTrigger = 0
    @State private var showingDiscard = false
    @ScaledMetric(relativeTo: .largeTitle) private var sealSize: CGFloat = 64

    /// Video clips filmed during this session — gate the "Turn N clips into a reel" CTA. Counted on
    /// appear (the recap is read-only, so a one-shot count is enough); device-only clips are 0 on the sim.
    @State private var videoClipCount = 0

    private var stats: FreeformSummary.Stats { FreeformSummary.stats(for: session, unit: unit) }
    private var dominant: FreeformSummary.Dominant { stats.dominant }

    /// Climbing stats with HR (for the Effort block) — computed once per presentation.
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
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 20) {
                    seal
                    heroStrip
                    adaptiveCards
                    if videoClipCount > 0 { studioCTA }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            actionBar
        }
        .padding(.vertical)
        .celebrates(on: celebrationTrigger)
        .confirmationDialog("Discard this workout?", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("Discard (don't save)", role: .destructive) { onDiscard() }
            Button("Keep going", role: .cancel) { onKeepGoing() }
        }
        .onAppear {
            doneBounce += 1
            if !milestones.isEmpty { celebrationTrigger += 1 }
            videoClipCount = countVideoClips()
        }
    }

    // MARK: - Top bar (Keep going)

    private var topBar: some View {
        HStack {
            Button("Keep going") { onKeepGoing() }
                .accessibilityIdentifier("freeform.keepGoing")
            Spacer()
        }
        .padding(.horizontal)
    }

    // MARK: - Seal + milestone headline

    private var seal: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: sealSize))
                .foregroundStyle(SnappetColor.workout)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : doneBounce)
            Text("Workout Complete").font(.title.bold())
            Text(session.routineName).foregroundStyle(.secondary)
            if let milestone = milestones.first {
                Text(FreeformSummary.milestoneHeadline(milestone))
                    .font(.headline)
                    .foregroundStyle(SnappetColor.workout)
                    .accessibilityIdentifier("freeform.milestone")
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Hero strip (3 type-adaptive cells)

    private var heroStrip: some View {
        HStack(spacing: 12) {
            ForEach(heroCells.indices, id: \.self) { i in
                heroCell(heroCells[i])
            }
        }
    }

    /// The three hero cells, adapting to the dominant kind. Honest degradation: climbing with no timed
    /// climb shows "Climbs" (count) rather than a faked "On the wall" time.
    private var heroCells: [FreeformSummary.Stat] {
        switch dominant {
        case .climbing:
            let s = climbStats
            let wall = s.timeline.compactMap(\.timeOnClimb).reduce(0, +)
            let third: FreeformSummary.Stat = wall > 0
                ? FreeformSummary.Stat(value: SetMeasure.formatDuration(wall), label: "On the wall")
                : FreeformSummary.Stat(value: "\(s.totalClimbs)", label: "Climbs")
            return [
                FreeformSummary.Stat(value: "\(s.sends)", label: "Sends"),
                FreeformSummary.Stat(value: s.hardestSendGrade ?? "—", label: "Hardest"),
                third,
            ]
        case .timed:
            return [
                FreeformSummary.Stat(value: SetMeasure.formatDuration(FreeformSummary.holdTimeSeconds(session)),
                                     label: "Hold time"),
                FreeformSummary.Stat(value: bestHoldLabel, label: "Best"),
                stats.sets,
            ]
        case .lifting:
            return [stats.headline, stats.sets, FreeformSummary.Stat(value: "\(prCount)", label: "PRs")]
        case .running:
            let t = runTotals
            let pace = (t.meters > 0 && t.seconds > 0)
                ? SetMeasure.formatPace(secPerKm: t.seconds / (t.meters / 1000), unit: distanceUnit) : "—"
            return [
                FreeformSummary.Stat(value: SetMeasure.formatDistance(t.meters, unit: distanceUnit), label: "Distance"),
                FreeformSummary.Stat(value: pace, label: "Pace"),
                stats.duration,
            ]
        case .dance, .other:
            return [stats.headline, stats.duration, stats.sets]
        case .none:
            return [stats.duration, stats.sets, stats.headline]
        }
    }

    private func heroCell(_ stat: FreeformSummary.Stat) -> some View {
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

    // MARK: - Adaptive cards

    @ViewBuilder
    private var adaptiveCards: some View {
        switch dominant {
        case .climbing: climbingCards
        case .timed:    timedCards
        case .lifting:  strengthCards
        case .running:  runningCards
        case .dance, .other: timedCards   // open-effort entities are .duration → the timed recap fits
        case .none:     EmptyView()
        }
    }

    // MARK: Climbing cards

    @ViewBuilder
    private var climbingCards: some View {
        let s = climbStats
        // Sends/hr · median · tries — the secondary climbing figures.
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
        if let hrStats { ClimbEffortSection(hr: hrStats) }
    }

    // MARK: Timed cards

    /// Per-exercise rows for a timed session (name · sets · TUT · best hold). Reads each `.duration`
    /// exercise's completed sets — no math beyond Σ/max of `durationSec`.
    @ViewBuilder
    private var timedCards: some View {
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

    // MARK: Running cards (Workout-Type Parity)

    /// Per-run rows (name · legs · distance · avg pace) + the time-in-zone Effort block when the session
    /// carries HR. Reuses the pure RunStats + the type-agnostic ClimbEffortSection (HR zones).
    @ViewBuilder
    private var runningCards: some View {
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
                            Text("\(row.legs) \(row.legs == 1 ? "leg" : "legs") · \(SetMeasure.formatDistance(row.meters, unit: distanceUnit))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let pace = row.pace {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(SetMeasure.formatPace(secPerKm: pace, unit: distanceUnit))
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
        if let hrStats { ClimbEffortSection(hr: hrStats) }
    }

    // MARK: Strength cards

    @ViewBuilder
    private var strengthCards: some View {
        // PRs reached this session (weighted), with their best set.
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

        // Per-exercise volume.
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

    // MARK: - Studio CTA

    private var studioCTA: some View {
        Button { onOpenStudio() } label: {
            HStack(spacing: 10) {
                Image(systemName: "film.stack")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn \(videoClipCount) \(videoClipCount == 1 ? "clip" : "clips") into a reel")
                        .font(.subheadline.weight(.semibold))
                    Text("Open in Studio").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(SnappetColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SnappetRadius.md))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("freeform.summaryReel")
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 12) {
            Button { onDone() } label: {
                Text("Done").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(SnappetColor.workout)
            .accessibilityIdentifier("freeform.done")

            Button { onViewDetail() } label: {
                Text("View detail").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("freeform.viewDetail")

            Button("Discard workout", role: .destructive) { showingDiscard = true }
                .font(.footnote)
                .accessibilityIdentifier("freeform.discard")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Rows + derivations

    private func recapRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    /// One per-exercise timed recap row.
    private struct TimedRow: Identifiable {
        let id: UUID
        let name: String
        let sets: Int
        let tut: TimeInterval
        let best: TimeInterval?
    }

    private var timedExerciseRows: [TimedRow] {
        session.exercises.compactMap { ex -> TimedRow? in
            // Run entities are also .duration but recap as runs (excluded here so a dance/timed recap
            // doesn't list a run leg as a timed hold).
            guard ex.kind == .duration, ex.discipline != .run else { return nil }
            let completed = ex.sets.filter { $0.completedAt != nil }
            guard !completed.isEmpty else { return nil }
            let durations = completed.compactMap(\.durationSec)
            return TimedRow(id: ex.id,
                            name: resolver.name(for: ex.exerciseId, override: ex.displayName),
                            sets: completed.count,
                            tut: durations.reduce(0, +),
                            best: durations.max())
        }
    }

    // MARK: Running derivations (Workout-Type Parity)

    /// Distance unit for the recap, derived from the weight-unit preference (lb→mi), matching the player.
    private var distanceUnit: DistanceUnit { unit == .lb ? .mi : .km }

    /// Session-wide running totals (Σ distance / Σ time across all completed run legs) — the hero figures.
    private var runTotals: (meters: Double, seconds: Double) {
        var m = 0.0, s = 0.0
        for ex in session.exercises where ex.discipline == .run {
            for set in ex.sets where set.completedAt != nil {
                m += set.distanceMeters ?? 0
                s += set.durationSec ?? 0
            }
        }
        return (m, s)
    }

    private struct RunRow: Identifiable {
        let id: UUID
        let name: String
        let legs: Int
        let meters: Double
        let pace: Double?
    }

    private var runExerciseRows: [RunRow] {
        session.exercises.compactMap { ex -> RunRow? in
            guard ex.discipline == .run else { return nil }
            let completed = ex.sets.filter { $0.completedAt != nil }
            guard !completed.isEmpty else { return nil }
            return RunRow(id: ex.id,
                          name: resolver.name(for: ex.exerciseId, override: ex.displayName),
                          legs: completed.count,
                          meters: RunStats.totalDistanceMeters(ex),
                          pace: RunStats.avgPaceSecPerKm(ex))
        }
    }

    private var bestHoldLabel: String {
        let best = session.exercises
            .filter { $0.kind == .duration }
            .flatMap { $0.sets.filter { $0.completedAt != nil } }
            .compactMap(\.durationSec)
            .max() ?? 0
        return best > 0 ? SetMeasure.formatDuration(best) : "—"
    }

    private struct VolumeRow: Identifiable {
        let id: UUID
        let name: String
        let sets: Int
        let volumeKg: Double
    }

    private var liftingVolumeRows: [VolumeRow] {
        session.exercises.compactMap { ex -> VolumeRow? in
            guard ex.kind == .repsWeight else { return nil }
            let completed = ex.sets.filter { $0.completedAt != nil }
            guard !completed.isEmpty else { return nil }
            let volume = completed.reduce(0.0) { sum, set in
                guard let reps = set.actualReps, let weight = set.actualWeight else { return sum }
                return sum + WorkoutMath.toKg(weight, set.weightUnit) * Double(reps)
            }
            return VolumeRow(id: ex.id,
                             name: resolver.name(for: ex.exerciseId, override: ex.displayName),
                             sets: completed.count, volumeKg: volume.rounded())
        }
    }

    private var prCount: Int {
        milestones.reduce(0) { count, m in
            if case .personalRecord = m { return count + 1 }
            return count
        }
    }

    /// Count video clips filmed in this session (the reel CTA gate). Device-only clips are 0 on the sim.
    private func countVideoClips() -> Int {
        let sid = session.id
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        return media.filter { $0.kind == .video }.count
    }
}
