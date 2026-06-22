import Foundation
import HighlightEngine

// MARK: - Recap Feed — effort/recovery insight recipes (F6, iOS-only, HR-gated)
//
// e4 EffortEfficiency · e5 HRVRecovery · restNudge. These are the HR/RR-derived members of the
// cross-session insight menu. Every recipe gates on the SPECIFIC field it needs:
//   • e4   — a grade sent across >= 3 sessions that carry `hrSeries` (per-send peak BPM trend).
//   • e5   — at least one session whose `hrSeries` carries `rrIntervalsMs` (on-device RMSSD).
//   • rest — >= 4 consecutive recent calendar days with a threshold+ (Z4/Z5) session.
// When the trigger field is absent the card is simply never produced (degrade-by-absence), so an
// HR-less corpus yields nothing here. Numbers are SURFACED from the existing pure engines
// (`KilterSessionStats`, `HRVMetrics`, `WorkoutHRStats`, `HeartRateZone`) — never re-derived.
//
// PURE Foundation: no SwiftUI / SwiftData. The `HighlightEngine` import (HRSample / HRVMetrics)
// lives here, not in the platform-shared FeedComposer core.

enum FeedEffortInsights {

    static func cards(kilterSessions: [KilterSessionInput],
                      logs: [KilterClimbLog],
                      now: Date,
                      calendar: Calendar,
                      anchor: Date) -> [FeedCard] {
        // Clamp the aggregate anchor so a card never out-floats a strictly-newer trigger.
        let safeAnchor = min(anchor, now)
        var out: [FeedCard] = []
        out += effortEfficiencyCards(sessions: kilterSessions, logs: logs, anchor: safeAnchor)
        out += hrvRecoveryCards(sessions: kilterSessions, anchor: safeAnchor)
        out += restNudgeCards(sessions: kilterSessions, calendar: calendar, now: now)
        return out
    }

    // MARK: e4 — same grade at a lower HR than before (a real efficiency gain)

    /// For each grade label, gather one peak-BPM datapoint per HR-carrying session that has a SEND at
    /// that grade. A grade needs >= 3 such sessions. Compare the AVERAGE peak BPM of the oldest third
    /// of those sessions vs the newest third; emit only when `newAvg < oldAvg`. The grade with the most
    /// datapoints wins (ties → broken deterministically). contentId "" (aggregate).
    private static func effortEfficiencyCards(sessions: [KilterSessionInput],
                                              logs: [KilterClimbLog],
                                              anchor: Date) -> [FeedCard] {
        let bySession = Dictionary(grouping: logs.filter { $0.sessionId != nil }, by: { $0.sessionId! })

        // datapoints[grade] = chronological [(sessionStart, peakBpm)] across HR-carrying sessions.
        struct Point { let start: Date; let peak: Double }
        var datapoints: [String: [Point]] = [:]

        for s in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard !s.hrSeries.isEmpty else { continue }                 // gate: HR present
            let slogs = bySession[s.id] ?? []
            guard !slogs.isEmpty else { continue }
            let end = s.endedAt ?? slogs.map(\.loggedAt).max() ?? s.startedAt
            let samples = s.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
            let stats = KilterSessionStats.make(from: slogs, start: s.startedAt, end: end,
                                                hrSeries: samples, maxHR: s.maxHR, restHR: s.restHR)
            // Per grade in this session: the peak BPM of the hardest-effort SEND at that grade.
            var perGradePeak: [String: Double] = [:]
            for item in stats.timeline where item.status.isSend {
                guard let peak = item.peakBpm else { continue }         // gate: this send was HR-scored
                perGradePeak[item.gradeLabel] = max(perGradePeak[item.gradeLabel] ?? 0, peak)
            }
            for (grade, peak) in perGradePeak {
                datapoints[grade, default: []].append(Point(start: s.startedAt, peak: peak))
            }
        }

        // Pick the grade with the most data (then by label for determinism) that has >= 3 sessions.
        let eligible = datapoints.filter { $0.value.count >= 3 }
        guard let chosen = eligible.max(by: { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key
        }) else { return [] }

        let series = chosen.value.sorted { $0.start < $1.start }
        let third = max(1, series.count / 3)
        let oldest = series.prefix(third)
        let newest = series.suffix(third)
        let oldAvg = oldest.map(\.peak).reduce(0, +) / Double(oldest.count)
        let newAvg = newest.map(\.peak).reduce(0, +) / Double(newest.count)

        // Gate on the UNROUNDED averages so a sub-1-BPM real gain (159.4 → 158.9) isn't lost to rounding;
        // round only for the display payload.
        guard newAvg < oldAvg else { return [] }                       // gate: a real efficiency gain

        let payload = EffortEfficiencyPayload(gradeBand: chosen.key,
                                              oldAvgBpm: Int(oldAvg.rounded()), newAvgBpm: Int(newAvg.rounded()))
        return [.aggregate(id: "e4-efficiency-\(chosen.key)", ref: "effortEfficiency",
                           kind: .e4EffortEfficiency, category: .effort,
                           salience: FeedComposer.Salience.effortEfficiency, anchor: anchor,
                           payload: .effortEfficiency(payload))]
    }

    // MARK: e5 — HRV / recovery (RR-gated)

    /// If any session's `hrSeries` carries `rrIntervalsMs`, compute on-device RMSSD over that session's
    /// full window. Picks the most recent such session. Only emits when RMSSD resolves. contentId "".
    private static func hrvRecoveryCards(sessions: [KilterSessionInput], anchor: Date) -> [FeedCard] {
        let withRR = sessions
            .filter { s in s.hrSeries.contains { ($0.rrIntervalsMs?.isEmpty == false) } } // gate: RR present
            .sorted { $0.startedAt < $1.startedAt }
        guard let s = withRR.last else { return [] }

        let samples = s.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
        let end = s.hrSeries.map(\.t).max() ?? 0
        let metrics = HRVMetrics.make(from: samples, start: 0, end: end)
        guard let rmssd = metrics.rmssd else { return [] }             // gate: RMSSD resolved

        let payload = HRVRecoveryPayload(rmssd: Int(rmssd.rounded()),
                                         note: "Higher RMSSD = better recovered.")
        return [.aggregate(id: "e5-hrv", ref: "hrvRecovery",
                           kind: .e5HRVRecovery, category: .effort,
                           salience: FeedComposer.Salience.hrvRecovery, anchor: anchor,
                           payload: .hrvRecovery(payload))]
    }

    // MARK: restNudge — protective "go gentler" suggestion

    /// Count consecutive recent calendar days, ending at the latest day that had a HARD session,
    /// where each day had at least one session whose max BPM lands in threshold+ (Z4/Z5). >= 4 such
    /// consecutive days → a protective rest nudge (never shame). contentId "" (aggregate).
    private static func restNudgeCards(sessions: [KilterSessionInput], calendar: Calendar, now: Date) -> [FeedCard] {
        // Which calendar days had a "hard" (threshold+) session?
        var hardDays = Set<Date>()
        var latestHard: Date?
        for s in sessions {
            guard !s.hrSeries.isEmpty else { continue }                // a hard day needs HR evidence
            let maxHR = s.maxHR ?? HeartRateZone.defaultMaxHR
            guard let hr = WorkoutHRStats.make(from: s.hrSeries, maxHR: maxHR) else { continue }
            let zone = HeartRateZone.forBpm(hr.maxBpm, maxHR: maxHR)
            guard zone.rawValue >= HeartRateZone.threshold.rawValue else { continue }   // gate: Z4+
            let day = calendar.startOfDay(for: s.startedAt)
            hardDays.insert(day)
            if latestHard == nil || day > latestHard! { latestHard = day }
        }
        guard let latest = latestHard else { return [] }

        // Walk back day by day from the latest hard day while each day is also hard.
        var streak = 0
        var cursor: Date? = latest
        while let day = cursor, hardDays.contains(day) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        guard streak >= 4 else { return [] }                           // gate: >= 4 hard days straight

        let note = "\(streak) hard days straight — a rest day keeps you primed."
        let anchor = min(latest, now)                                  // never in the future
        return [.aggregate(id: "rest-nudge-\(Int(latest.timeIntervalSince1970))", ref: "restNudge",
                           kind: .restNudge, category: .effort,
                           salience: FeedComposer.Salience.restNudge, anchor: anchor,
                           payload: .restNudge(RestNudgePayload(hardDays: streak, note: note)))]
    }
}
