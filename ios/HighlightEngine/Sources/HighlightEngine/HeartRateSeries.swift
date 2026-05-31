import Foundation

/// Resampled + smoothed heart-rate signal with the derived features the selectors
/// use: %heart-rate-reserve and rate-of-change. Pure value type, fully testable.
///
/// Implements the signal-processing from the deep research (#60 §4): resample to a
/// uniform grid → smooth → normalize to %HRR → derivative.
public struct HeartRateSeries: Sendable {
    public let dt: Double                  // grid spacing in seconds
    public let bpm: [Double]               // smoothed bpm on the uniform grid
    public let hrr: [Double]               // %heart-rate-reserve, 0...1
    public let slope: [Double]             // d(%HRR)/dt, normalized to 0...1 (positive only)
    public let restBpm: Double
    public let maxBpm: Double

    /// Sample the smoothed bpm at an arbitrary time (nearest grid point).
    public func bpm(at t: Double) -> Double { bpm[index(for: t)] }
    public func hrr(at t: Double) -> Double { hrr[index(for: t)] }
    public func slope(at t: Double) -> Double { slope[index(for: t)] }

    func index(for t: Double) -> Int {
        guard !bpm.isEmpty else { return 0 }
        return min(bpm.count - 1, max(0, Int((t / dt).rounded())))
    }
}

public extension HeartRateSeries {
    /// Build a series from raw samples.
    /// - restBpm/maxBpm: if nil, estimated from the data (p05 for rest, age-free
    ///   max via observed peak). Estimation is intentionally simple — the app
    ///   should pass real values when available.
    static func make(
        from samples: [HRSample],
        duration: Double,
        dt: Double = 1.0,
        smoothingWindowSec: Double,
        restBpm: Double?,
        maxBpm: Double?
    ) -> HeartRateSeries {
        let n = max(1, Int((duration / dt).rounded()))
        // ── 1. resample onto a uniform grid (linear interpolation / hold) ──
        let sorted = samples.sorted { $0.t < $1.t }
        var grid = [Double](repeating: 0, count: n)
        if sorted.isEmpty {
            grid = [Double](repeating: restBpm ?? 60, count: n)
        } else {
            var j = 0
            for i in 0..<n {
                let t = Double(i) * dt
                while j + 1 < sorted.count && sorted[j + 1].t <= t { j += 1 }
                if j + 1 < sorted.count {
                    let a = sorted[j], b = sorted[j + 1]
                    let span = max(1e-6, b.t - a.t)
                    let f = min(1, max(0, (t - a.t) / span))
                    grid[i] = a.bpm + f * (b.bpm - a.bpm)
                } else {
                    grid[i] = sorted[j].bpm
                }
            }
        }

        // ── 2. smooth (centered moving average) ──
        let w = max(1, Int((smoothingWindowSec / dt).rounded()))
        let smoothed = movingAverage(grid, window: w)

        // ── 3. rest/max estimation if not supplied ──
        let rest = restBpm ?? percentile(smoothed, 0.05)
        let mx = maxBpm ?? max(percentile(smoothed, 0.99), rest + 1)

        // ── 4. %HRR ──
        let denom = max(1e-6, mx - rest)
        let hrr = smoothed.map { v in min(1, max(0, (v - rest) / denom)) }

        // ── 5. derivative (central difference), normalized positive slope ──
        var raw = [Double](repeating: 0, count: n)
        for i in 1..<max(1, n - 1) {
            raw[i] = (hrr[i + 1] - hrr[i - 1]) / (2 * dt)
        }
        let maxSlope = max(raw.max() ?? 0, 1e-6)
        let slope = raw.map { max(0, $0 / maxSlope) }

        return HeartRateSeries(dt: dt, bpm: smoothed, hrr: hrr, slope: slope,
                               restBpm: rest, maxBpm: mx)
    }
}

// MARK: - Small numeric helpers (internal, tested via the public API)

func movingAverage(_ xs: [Double], window: Int) -> [Double] {
    guard window > 1, xs.count > 1 else { return xs }
    let half = window / 2
    var out = [Double](repeating: 0, count: xs.count)
    // prefix-sum for O(n)
    var prefix = [Double](repeating: 0, count: xs.count + 1)
    for i in 0..<xs.count { prefix[i + 1] = prefix[i] + xs[i] }
    for i in 0..<xs.count {
        let a = max(0, i - half)
        let b = min(xs.count - 1, i + half)
        out[i] = (prefix[b + 1] - prefix[a]) / Double(b - a + 1)
    }
    return out
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let idx = min(s.count - 1, max(0, Int((p * Double(s.count - 1)).rounded())))
    return s[idx]
}
