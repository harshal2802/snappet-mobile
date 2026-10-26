import Foundation

/// **Pure** decision for back-filling a finished gym session's heart rate from Apple Health (prompt 203).
///
/// Live HR only exists when an Apple Watch (or a BLE strap) streams it into the session. Anyone else — a
/// Fitbit / Google Health user, a Garmin, a Whoop — still ends up with their heart rate in Apple Health,
/// just later (when their app syncs). So after a session ends, read the HR samples Health holds for the
/// session window and keep them if they're denser than what the session has (`HRSeriesDensify.denser`).
/// That also densifies a watch session's thinned live relay, exactly as Kilter's post-hoc read does.
///
/// Skipped: active sessions, Apple Health imports (the importer already read HR), already-dense series, and
/// sessions older than `lookbackDays` (re-querying forever costs a HealthKit read per launch).
///
/// BLE sessions (~1 Hz, carrying RR a Health read lacks) keep every live sample; only their GAPS — the band
/// connected late, or dropped for a while — are filled from Health (2026-10-26: a tournament morning whose band
/// connected two hours in left two whole matches without HR).
/// Foundation only → unit-tested in `WorkoutHRBackfillTests`.
enum WorkoutHRBackfill {
    /// A week: a wearable's sync can lag a day or two, and a tournament is often reviewed days later.
    static let lookbackDays: Double = 7
    /// A BLE series silent for longer than this has a gap worth filling from Health.
    static let gapSeconds: Double = 60
    /// A series at ≥ 1 sample / 2 s is as dense as a Health read gets — leave it.
    static let denseEnough: Double = 0.5
    /// `WorkoutSession.metricsSourceRaw` for a session whose only HR came from Apple Health (no live source).
    static let healthSourceRaw = "appleHealth"

    struct Candidate: Equatable, Sendable {
        var startedAt: Date
        var completedAt: Date?
        var metricsSourceRaw: String?
        var isImportedFromHealth: Bool
        var hrSeries: [HRPoint]
    }

    static func wants(_ c: Candidate, now: Date) -> Bool {
        guard let end = c.completedAt, end > c.startedAt else { return false }
        guard !c.isImportedFromHealth else { return false }
        guard now.timeIntervalSince(end) <= lookbackDays * 86_400 else { return false }
        if c.metricsSourceRaw == "ble" { return !gaps(in: c.hrSeries, duration: end.timeIntervalSince(c.startedAt)).isEmpty }
        return HRCadence.summarize(c.hrSeries).perSecond < denseEnough
    }

    /// Stretches of the session (`t` from 0 to `duration`) with no sample for longer than `gapSeconds`.
    static func gaps(in series: [HRPoint], duration: Double) -> [ClosedRange<Double>] {
        let ts = series.map(\.t).sorted()
        var out: [ClosedRange<Double>] = []
        var last = 0.0
        for t in ts + [duration] {
            if t - last > gapSeconds { out.append(last...t) }
            last = max(last, t)
        }
        return out
    }

    /// The series to store, or `nil` when Health added nothing (so the caller doesn't save). `keepLive` (a BLE
    /// session): keep every live sample and add Health's only inside the gaps; otherwise the denser series wins.
    static func merged(stored: [HRPoint], health: [HRPoint], keepLive: Bool = false,
                       duration: Double? = nil) -> [HRPoint]? {
        if keepLive {
            let holes = gaps(in: stored, duration: duration ?? (health.map(\.t).max() ?? 0))
            let fill = health.filter { p in holes.contains { $0.lowerBound < p.t && p.t < $0.upperBound } }
            return fill.isEmpty ? nil : (stored + fill).sorted { $0.t < $1.t }
        }
        let best = HRSeriesDensify.denser(live: stored, healthKit: health)
        return best.count > stored.count ? best : nil
    }
}
