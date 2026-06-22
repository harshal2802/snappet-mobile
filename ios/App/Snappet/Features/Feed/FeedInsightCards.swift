import Foundation

// MARK: - Recap Feed — cross-session insight cards (F6, pure)
//
// The Pillar-4 insight menu as composer recipes — each reads existing engine output (KilterAllTimeStats)
// or scans the plain logs; none re-derives stats and none edits the F0 ordering core. All are aggregates
// → contentId stays empty (per the H4 invariant). Deferred follow-ons (additive recipes): d3 discipline
// split, d4 90-day trend arrows, e4 effort-vs-grade, e5 HRV/recovery, restNudge, g1 project-cadence.

enum FeedInsightCards {

    static func cards(allTime: KilterAllTimeStats, logs: [KilterClimbLog],
                      now: Date, calendar: Calendar, anchor: Date) -> [FeedCard] {
        var out: [FeedCard] = []

        // c2 — Pyramid health: an easier row narrower than a harder one above it (top-heavy) to consolidate.
        if let weak = topHeavyGrade(allTime.pyramid) {
            let payload = PyramidHealthPayload(
                rows: allTime.pyramid.map(row(from:)), consolidateGrade: weak,
                note: "Your base is solid — a few more clean \(weak) sends round out the row below your max.")
            out.append(card("c2-health", .c2PyramidHealth, .trend, Salience.trend, anchor, .pyramidHealth(payload), .pyramidCard))
        }

        // c3 — Grade progression: >= 3 months of max-grade points.
        let prog = allTime.maxGradeProgression
        if prog.count >= 3, let first = prog.first, let last = prog.last {
            let payload = ProgressionPayload(points: prog.map { .init(label: $0.periodLabel, grade: $0.gradeLabel) },
                                             fromGrade: first.gradeLabel, toGrade: last.gradeLabel)
            out.append(card("c3-prog", .c3Progression, .trend, Salience.trend, anchor, .progression(payload), nil))
        }

        // c4 — Climbing level: gate on >= 20 sends (the engine computes a level for fewer too).
        if allTime.totalSends >= 20, let level = allTime.climbingLevelLabel {
            out.append(card("c4-level", .c4ClimbingLevel, .trend, Salience.trend, anchor,
                            .climbingLevel(ClimbingLevelPayload(level: level, maxGrade: allTime.maxGradeLabel)), nil))
        }

        // c5 — Angle distribution: sends at >= 2 angles.
        let angles = allTime.angleDistribution.filter { $0.sends > 0 }.sorted { $0.sends > $1.sends }
        if angles.count >= 2, let top = angles.first {
            let payload = AngleDistPayload(slices: angles.map { .init(angle: $0.angle, sends: $0.sends) }, topAngle: top.angle)
            out.append(card("c5-angle", .c5AngleDist, .trend, Salience.trend, anchor, .angleDist(payload), nil))
        }

        // d2 — This period vs last: two consecutive non-empty months.
        let months = allTime.monthRollups
        if months.count >= 2 {
            let cur = months[months.count - 1], prev = months[months.count - 2]
            if cur.sends > 0 || prev.sends > 0 {
                out.append(card("d2-pvl", .d2PeriodVsLast, .trend, Salience.trend, anchor,
                                .periodVsLast(PeriodVsLastPayload(currentLabel: cur.periodLabel, current: cur.sends, previous: prev.sends)), nil))
            }
        }

        // consistencyMap — >= 14 active days in the trailing 28.
        let consistency = consistencyWindow(logs: logs, now: now, calendar: calendar, days: 28)
        if consistency.activeDays >= 14 {
            out.append(card("consistency", .consistencyMap, .trend, Salience.consistency, anchor, .consistency(consistency), nil))
        }

        // onThisDay — a send on this month/day in a prior year (private memory).
        if let memory = onThisDay(logs: logs, now: now, calendar: calendar) {
            out.append(card("onthisday", .onThisDay, .memory, Salience.insightMemory, memory.anchor, .onThisDay(memory.payload), nil))
        }
        return out
    }

    // MARK: helpers

    private typealias Salience = FeedComposer.Salience

    private static func card(_ id: String, _ kind: FeedCardKind, _ category: FeedCategory, _ salience: Double,
                             _ anchor: Date, _ payload: FeedCardPayload, _ share: ShareTemplate?) -> FeedCard {
        .aggregate(id: id, kind: kind, category: category, salience: salience, anchor: anchor, payload: payload, share: share)
    }

    private static func row(from g: KilterSessionStats.GradeCount) -> PyramidRow {
        PyramidRow(grade: g.gradeLabel, difficulty: g.difficulty, sends: g.sends,
                   flashes: g.flashes, projects: g.projects, attemptsOnly: g.attemptsOnly)
    }

    /// Pyramid is easiest→hardest. A healthy pyramid's sends are non-increasing with grade; a top-heavy
    /// spot is an easier grade with FEWER sends than the harder grade above it → consolidate the easier one.
    private static func topHeavyGrade(_ pyramid: [KilterSessionStats.GradeCount]) -> String? {
        let withSends = pyramid.filter { $0.sends > 0 }
        guard withSends.count >= 3 else { return nil }
        for i in 0..<(pyramid.count - 1) where pyramid[i].sends > 0 && pyramid[i].sends < pyramid[i + 1].sends {
            return pyramid[i].gradeLabel
        }
        return nil
    }

    private static func consistencyWindow(logs: [KilterClimbLog], now: Date, calendar: Calendar, days: Int) -> ConsistencyPayload {
        let today = calendar.startOfDay(for: now)
        var perDay = Array(repeating: 0, count: days)
        for log in logs {
            let d = calendar.startOfDay(for: log.loggedAt)
            let delta = calendar.dateComponents([.day], from: d, to: today).day ?? -1
            if delta >= 0 && delta < days { perDay[days - 1 - delta] += 1 }
        }
        return ConsistencyPayload(activeDays: perDay.filter { $0 > 0 }.count, windowDays: days, perDay: perDay)
    }

    private static func onThisDay(logs: [KilterClimbLog], now: Date, calendar: Calendar)
        -> (payload: OnThisDayPayload, anchor: Date)? {
        let nowMD = calendar.dateComponents([.month, .day], from: now)
        let nowYear = calendar.component(.year, from: now)
        let candidates = logs
            .filter { $0.isSend }
            .filter {
                let c = calendar.dateComponents([.month, .day, .year], from: $0.loggedAt)
                return c.month == nowMD.month && c.day == nowMD.day && (c.year ?? nowYear) < nowYear
            }
            .sorted { $0.loggedAt > $1.loggedAt }     // most recent prior year first
        guard let m = candidates.first else { return nil }
        let years = nowYear - calendar.component(.year, from: m.loggedAt)
        let payload = OnThisDayPayload(yearsAgo: years, grade: m.gradeLabel,
                                       summary: "You sent \(m.climbName) (\(m.gradeLabel)) \(years) year\(years == 1 ? "" : "s") ago today.")
        return (payload, now)
    }
}
