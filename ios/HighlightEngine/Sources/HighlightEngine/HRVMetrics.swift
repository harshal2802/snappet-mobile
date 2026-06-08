import Foundation

/// On-device heart-rate **variability** over a window of RR-intervals — the recovery-quality signal
/// that beat-to-beat timing gives and a bpm series can't (fitness-band Phase 3). Pure, platform-free
/// value type (engine constraint), so RMSSD/SDNN/pNN50 are unit-tested with `swift test`, no device.
///
/// RR-intervals (ms between consecutive beats) ride the `0x2A37` packet and are captured on
/// `HRSample.rrIntervalsMs` — but **only from a trusted chest strap** (the BLE source gates this;
/// optical sensors / the Apple-Watch path carry no RR). So `.empty` is the honest, common state:
/// HR-less sessions, untrusted bands, or a rest window with too few beats all render nothing.
///
/// - `rmssd`: root-mean-square of successive RR differences (ms) — the standard short-window
///   parasympathetic / recovery marker; higher = better rested.
/// - `sdnn`: standard deviation of the RR intervals (ms) — overall variability.
/// - `pnn50`: fraction (0…1) of successive RR pairs differing by > 50 ms.
public struct HRVMetrics: Sendable, Equatable {
    public let rmssd: Double?
    public let sdnn: Double?
    public let pnn50: Double?
    /// How many usable (in-range) RR intervals went into the figures — for honest "n beats" context.
    public let beatCount: Int

    /// No usable RR for this window — the all-`nil` state the UI hides on.
    public static let empty = HRVMetrics(rmssd: nil, sdnn: nil, pnn50: nil, beatCount: 0)

    public init(rmssd: Double?, sdnn: Double?, pnn50: Double?, beatCount: Int) {
        self.rmssd = rmssd
        self.sdnn = sdnn
        self.pnn50 = pnn50
        self.beatCount = beatCount
    }

    /// Physiologically plausible RR band (ms): ~30–200 bpm. Out-of-range values are dropped artifacts
    /// (a missed/merged/ectopic beat) that would otherwise dominate RMSSD.
    static let plausibleRR: ClosedRange<Double> = 300...2000

    /// Compute HRV over a flat RR-interval array (ms). Filters implausible RR, then needs at least
    /// `minIntervals` survivors (≥ 2 successive pairs make RMSSD/pNN50 meaningful; default 5 for
    /// stability). Fewer → `.empty`.
    public static func make(rrIntervalsMs: [Double], minIntervals: Int = 5) -> HRVMetrics {
        let rr = rrIntervalsMs.filter { plausibleRR.contains($0) }
        guard rr.count >= max(2, minIntervals) else { return .empty }

        let mean = rr.reduce(0, +) / Double(rr.count)
        let variance = rr.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rr.count)
        let sdnn = variance.squareRoot()

        var sumSqDiff = 0.0
        var nn50 = 0
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            sumSqDiff += d * d
            if abs(d) > 50 { nn50 += 1 }
        }
        let pairs = rr.count - 1
        let rmssd = (sumSqDiff / Double(pairs)).squareRoot()
        let pnn50 = Double(nn50) / Double(pairs)

        return HRVMetrics(rmssd: rmssd, sdnn: sdnn, pnn50: pnn50, beatCount: rr.count)
    }

    /// Gather every sample's RR that falls in `[start, end]` (seconds on the session timeline) and
    /// compute HRV — the sibling of `ClimbEffort.make`, used to score a rest window between efforts.
    /// `.empty` when no sample in the window carried trusted RR.
    public static func make(from samples: [HRSample], start: Double, end: Double,
                            minIntervals: Int = 5) -> HRVMetrics {
        guard end >= start else { return .empty }
        let rr = samples
            .filter { $0.t >= start && $0.t <= end }
            .compactMap(\.rrIntervalsMs)
            .flatMap { $0 }
        return make(rrIntervalsMs: rr, minIntervals: minIntervals)
    }
}
