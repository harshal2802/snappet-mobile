import Foundation
import HighlightEngine

/// **Pure HRV reads for every heart-rate surface** (2026-10-26, user: "if a band supports HRV, make it available
/// on all the views"). HRV needs beat-to-beat (RR) timing, which only a trusted chest strap provides —
/// `BLEHeartRateMetricsSource` keeps RR from straps and drops it from optical bands (a Fitbit, an Apple Watch), so
/// every read here returns `.empty` / `nil` without one and the surfaces hide. RMSSD is a within-user trend.
///
/// - `rolling`: live, over the last minute of the buffer — the pager chip and the live metrics panel.
/// - `session`: across the whole session — session detail's Heart rate section.
/// - `perSet`: one figure per logged set — a gym set's REST before it (Phase 3), a racket game's whole window
///   (play + the change of ends; the gap before an untimed game isn't known).
enum HRVReads {
    /// Live HRV needs about a minute of beats to be stable.
    static let liveWindowSec: Double = 60

    /// HRV over the last `window` seconds of `samples` (ending at the newest sample).
    static func rolling(_ samples: [HRSample], window: Double = liveWindowSec) -> HRVMetrics {
        guard let end = samples.map(\.t).max() else { return .empty }
        return HRVMetrics.make(from: samples, start: end - window, end: end, minIntervals: 20)
    }

    /// HRV across a whole stored series.
    static func session(_ series: [HRPoint]) -> HRVMetrics {
        HRVMetrics.make(rrIntervalsMs: series.compactMap(\.rrIntervalsMs).flatMap { $0 }, minIntervals: 20)
    }

    /// Per logged set: a racket game's window, else the rest before the set (`WorkoutHRStats.setRestHRV`).
    static func perSet(for exercises: [SessionExercise], sessionStart: Date,
                       hr: [HRSample]) -> [WorkoutHRStats.SetRef: HRVMetrics] {
        guard hr.contains(where: { !($0.rrIntervalsMs ?? []).isEmpty }) else { return [:] }
        var out = WorkoutHRStats.setRestHRV(for: exercises, sessionStart: sessionStart, hr: hr)
        for ex in exercises where ex.discipline == .racket {
            for w in RacketStats.unitWindows(ex, sessionStart: sessionStart) {
                out[.init(exerciseID: ex.id, setIndex: w.index)] = HRVMetrics.make(from: hr, start: w.start, end: w.end)
            }
        }
        return out
    }

    /// Mean RMSSD over the sets that have one, or `nil`.
    static func meanRMSSD(_ metrics: [HRVMetrics]) -> Double? {
        let v = metrics.compactMap(\.rmssd)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
}
