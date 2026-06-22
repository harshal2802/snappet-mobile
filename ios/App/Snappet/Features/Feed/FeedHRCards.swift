import Foundation
import HighlightEngine

// MARK: - Recap Feed — HR-deepened card recipes (F2)
//
// e1 Session Effort / Zones, e2 Hardest-Effort Send, e3 Avg/Peak HR Trend — added as composer
// recipes (FeedComposer.compose registers them) WITHOUT touching F0's ordering core. Each gates on
// the SPECIFIC field it needs (hrSeries / per-climb timing) so it never composes when absent —
// graceful degradation by construction. Reads WorkoutHRStats / KilterSessionStats / ClimbEffort
// verbatim (never re-derives). HighlightEngine import lives here, not in the pure FeedComposer.

enum FeedHRCards {

    /// e1 (effort/zones) + e2 (hardest-effort send) per Kilter session that carries HR.
    static func cards(sessions: [KilterSessionInput], logs: [KilterClimbLog]) -> [FeedCard] {
        let bySession = Dictionary(grouping: logs.filter { $0.sessionId != nil }, by: { $0.sessionId! })
        var out: [FeedCard] = []
        for s in sessions {
            guard !s.hrSeries.isEmpty else { continue }                 // gate: HR present
            let slogs = bySession[s.id] ?? []
            let end = s.endedAt ?? slogs.map(\.loggedAt).max() ?? s.startedAt
            let contentId = FeedContentIdentity.kilterSession(id: s.id.uuidString)
            let ref = ActivityRef(objectKind: "kilterSession", ref: s.id.uuidString)
            let maxHR = s.maxHR ?? HeartRateZone.defaultMaxHR

            // e1 — effort / zones (Edwards TRIMP, time-in-zone) from WorkoutHRStats.
            if let hr = WorkoutHRStats.make(from: s.hrSeries, maxHR: maxHR) {
                let zones = hr.orderedZoneSeconds.map { ZoneSlice(zone: $0.zone.rawValue, seconds: $0.seconds) }
                let payload = EffortPayload(
                    title: s.title, zones: zones,
                    avgBpm: Int(hr.avgBpm.rounded()), maxBpm: Int(hr.maxBpm.rounded()),
                    trimp: Int(hr.edwardsTRIMP.rounded()), redlineSeconds: hr.redlineSeconds,
                    totalSeconds: hr.totalSeconds, durationSec: end.timeIntervalSince(s.startedAt))
                out.append(FeedCard(id: "e1-\(s.id.uuidString)", contentId: contentId, kind: .e1Effort,
                                    category: .effort, salience: FeedComposer.Salience.effort, anchorDate: end,
                                    sourceRefs: [ref], payload: .effort(payload), shareHint: nil))
            }

            // e2 — hardest-effort SEND (needs per-climb timing → ClimbEffort in the timeline).
            let samples = s.hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) }
            let stats = KilterSessionStats.make(from: slogs, start: s.startedAt, end: end,
                                                hrSeries: samples, maxHR: s.maxHR, restHR: s.restHR)
            let sendsWithEffort = stats.timeline.filter { $0.status.isSend && $0.peakBpm != nil }
            if let peak = sendsWithEffort.max(by: { effortScore($0) < effortScore($1) }) {
                let zone = HeartRateZone.forBpm(peak.peakBpm, maxHR: maxHR)
                let payload = HardestEffortPayload(
                    grade: peak.gradeLabel, climbName: peak.climbName,
                    peakBpm: Int((peak.peakBpm ?? 0).rounded()),
                    peakHRRPercent: peak.peakHRR.map { Int(($0 * 100).rounded()) },
                    zoneAtPeak: zone.rawValue, sendTimeOffsetSec: peak.restBefore ?? 0)
                out.append(FeedCard(id: "e2-\(s.id.uuidString)", contentId: contentId, kind: .e2HardestEffort,
                                    category: .effort, salience: FeedComposer.Salience.hardestEffort, anchorDate: end,
                                    sourceRefs: [ref], payload: .hardestEffort(payload), shareHint: nil))
            }
        }
        return out
    }

    /// e3 — avg/peak HR trend across the last sessions that carry HR (>= 3).
    static func trend(sessions: [KilterSessionInput]) -> [FeedCard] {
        let withHR = sessions.filter { !$0.hrSeries.isEmpty }.sorted { $0.startedAt < $1.startedAt }
        guard withHR.count >= 3 else { return [] }
        let points: [HRTrendPayload.Point] = withHR.compactMap { s in
            guard let hr = WorkoutHRStats.make(from: s.hrSeries, maxHR: s.maxHR ?? HeartRateZone.defaultMaxHR) else { return nil }
            return HRTrendPayload.Point(date: s.endedAt ?? s.startedAt,
                                        avgBpm: Int(hr.avgBpm.rounded()), maxBpm: Int(hr.maxBpm.rounded()))
        }
        guard points.count >= 3 else { return [] }
        let anchor = points.last?.date ?? .now
        return [FeedCard(id: "e3-hrtrend", contentId: "", kind: .e3HRTrend, category: .trend,
                         salience: FeedComposer.Salience.hrTrend, anchorDate: anchor,
                         sourceRefs: [ActivityRef(objectKind: "aggregate", ref: "hrTrend")],
                         payload: .hrTrend(HRTrendPayload(points: points)), shareHint: nil)]
    }

    /// Rank by %HRR when known, else peak BPM.
    private static func effortScore(_ t: KilterSessionStats.TimelineItem) -> Double {
        t.peakHRR ?? t.peakBpm ?? 0
    }
}
