import Foundation
import HighlightEngine

/// **Pure** merge of the two live HR transports (Apple Watch + BLE band) into one timeline-ordered
/// sample buffer. Foundation/HighlightEngine only — unit-testable with no device.
///
/// The live coordinator forwards only the *active* source's `samples`, so when a workout switches
/// transport mid-session (e.g. the watch drops and the band takes over) the flush would otherwise see
/// only the new source's buffer and lose the earlier one (the `active-source-switch` finding). For the
/// in-editor live fallback we instead merge **both** buffers: samples share one origin
/// (`LiveMetricsContext.startedAt` == `session.startedAt`), so they live on the same `t` axis and can
/// be unioned, de-duplicated by `t`, and sorted.
enum LiveHRMerge {

    /// Merge two same-timeline sample buffers: union, sort by `t`, and collapse near-duplicate
    /// timestamps (within `epsilon` seconds) keeping the richer sample (the one carrying RR intervals,
    /// so HRV survives). Either side may be empty.
    static func merge(_ a: [HRSample], _ b: [HRSample], epsilon: Double = 0.25) -> [HRSample] {
        let all = (a + b).sorted { $0.t < $1.t }
        guard let firstSample = all.first else { return [] }
        var out: [HRSample] = [firstSample]
        for s in all.dropFirst() {
            if let last = out.last, abs(s.t - last.t) <= epsilon {
                // Same instant from both transports — prefer the sample that carries RR intervals.
                let lastHasRR = (last.rrIntervalsMs?.isEmpty == false)
                let curHasRR = (s.rrIntervalsMs?.isEmpty == false)
                if curHasRR && !lastHasRR { out[out.count - 1] = s }
            } else {
                out.append(s)
            }
        }
        return out
    }
}
