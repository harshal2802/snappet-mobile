import Foundation

// MARK: - Recap Feed — discipline/trend cards (F6 follow-on, pure)
//
// Two additive cross-session recipes that sit alongside FeedInsightCards. Both are
// aggregates (no single source activity) → contentId stays "" with an "aggregate"
// ActivityRef (the H4 invariant). Pure Foundation only (no SwiftUI/SwiftData) so they
// unit-test without a simulator and the Kotlin port mirrors them 1:1.
//
//   d3 disciplineSplit — share of sessions across disciplines (climbing vs strength vs …),
//                        eligible only with >= 2 distinct disciplines.
//   d4 trendArrows     — 90-day rolling volume vs baseline: mean sends of the OLDER half of
//                        the weekly buckets vs the NEWER half, eligible only with >= 90 days
//                        of history and two non-empty halves.
//
// Eligibility gates mean a card is simply never produced when its trigger is absent
// (degrade-by-absence) — no placeholder/empty cards ever reach the feed.

enum FeedTrendCards {

    /// Salience tiers live in the keystone (FeedComposer.Salience); aliased here for readability.
    private enum Salience {
        static let disciplineSplit = FeedComposer.Salience.disciplineSplit
        static let trendArrows = FeedComposer.Salience.trendArrows
    }

    static func cards(allTime: KilterAllTimeStats,
                      kilterSessions: [KilterSessionInput],
                      workoutSessions: [WorkoutSessionInput],
                      logs: [KilterClimbLog],
                      now: Date, calendar: Calendar, anchor: Date) -> [FeedCard] {
        var out: [FeedCard] = []

        if let split = disciplineSplit(kilterSessions: kilterSessions, workoutSessions: workoutSessions) {
            out.append(card("d3-split", .d3DisciplineSplit, .trend, Salience.disciplineSplit, anchor,
                            .disciplineSplit(split), nil))
        }

        if let arrows = trendArrows(allTime: allTime, logs: logs, now: now) {
            out.append(card("d4-arrows", .d4TrendArrows, .trend, Salience.trendArrows, anchor,
                            .trendArrows(arrows), nil))
        }

        return out
    }

    // MARK: - d3 discipline split

    /// Counts sessions per discipline: every kilter session = "Climbing"; each *completed* workout
    /// session = its dominant exercise discipline (majority of non-skipped exercises, default "strength").
    /// Eligible only when >= 2 distinct disciplines appear. Slices are descending by count (ties → label asc).
    static func disciplineSplit(kilterSessions: [KilterSessionInput],
                                workoutSessions: [WorkoutSessionInput]) -> DisciplineSplitPayload? {
        var counts: [String: Int] = [:]
        for _ in kilterSessions { counts["Climbing", default: 0] += 1 }
        for w in workoutSessions where w.completedAt != nil {
            counts[dominantDiscipline(w.exercises), default: 0] += 1
        }
        guard counts.count >= 2 else { return nil }

        let slices = counts
            .map { DisciplineSplitPayload.Slice(label: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
        guard let top = slices.first else { return nil }
        return DisciplineSplitPayload(slices: slices, topLabel: top.label)
    }

    /// Majority discipline of a workout's non-skipped exercises (default "strength").
    /// Ties resolve to the lexicographically-smaller raw (deterministic).
    private static func dominantDiscipline(_ exercises: [WorkoutExerciseInput]) -> String {
        let raws = exercises.filter { !$0.skipped }.compactMap { $0.disciplineRaw }
        guard !raws.isEmpty else { return "strength" }
        let counts = Dictionary(grouping: raws, by: { $0 }).mapValues(\.count)
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? "strength"
    }

    // MARK: - d4 trend arrows

    /// Builds a "weekly volume" arrow from `allTime.sendsPerWeek`: split the buckets into an OLDER half
    /// and a NEWER half, compare their mean sends. Eligible only when there are >= 90 days of history
    /// (earliest log.loggedAt <= now - 90d) and both halves are non-empty.
    static func trendArrows(allTime: KilterAllTimeStats, logs: [KilterClimbLog], now: Date) -> TrendArrowsPayload? {
        // History gate: need >= 90 days since the earliest logged climb.
        guard let earliest = logs.map(\.loggedAt).min() else { return nil }
        let ninetyDays: TimeInterval = 90 * 24 * 3600
        guard earliest <= now.addingTimeInterval(-ninetyDays) else { return nil }

        let buckets = allTime.sendsPerWeek
        guard buckets.count >= 2 else { return nil }

        // Split chronological buckets (oldest→newest) into older / newer halves.
        let mid = buckets.count / 2
        let older = Array(buckets.prefix(mid))
        let newer = Array(buckets.suffix(buckets.count - mid))
        guard !older.isEmpty, !newer.isEmpty else { return nil }

        let oldMean = Double(older.reduce(0) { $0 + $1.sends }) / Double(older.count)
        let newMean = Double(newer.reduce(0) { $0 + $1.sends }) / Double(newer.count)

        let deltaPct: Int
        if oldMean == 0 {
            deltaPct = newMean > 0 ? 100 : 0
        } else {
            deltaPct = Int((newMean - oldMean) / oldMean * 100.0)
        }
        let arrow = TrendArrowsPayload.Arrow(label: "Weekly volume", deltaPct: deltaPct, improving: newMean >= oldMean)
        return TrendArrowsPayload(arrows: [arrow])
    }

    // MARK: - card builder

    private static func card(_ id: String, _ kind: FeedCardKind, _ category: FeedCategory, _ salience: Double,
                             _ anchor: Date, _ payload: FeedCardPayload, _ share: ShareTemplate?) -> FeedCard {
        FeedCard(id: id, contentId: "", kind: kind, category: category, salience: salience, anchorDate: anchor,
                 sourceRefs: [ActivityRef(objectKind: "aggregate", ref: id)], payload: payload, shareHint: share)
    }
}
