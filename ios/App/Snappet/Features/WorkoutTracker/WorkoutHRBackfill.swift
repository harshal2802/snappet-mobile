import Foundation

/// **Pure** decision for back-filling a finished gym session's heart rate from Apple Health (prompt 203).
///
/// Live HR only exists when an Apple Watch (or a BLE strap) streams it into the session. Anyone else — a
/// Fitbit / Google Health user, a Garmin, a Whoop — still ends up with their heart rate in Apple Health,
/// just later (when their app syncs). So after a session ends, read the HR samples Health holds for the
/// session window and keep them if they're denser than what the session has (`HRSeriesDensify.denser`).
/// That also densifies a watch session's thinned live relay, exactly as Kilter's post-hoc read does.
///
/// Skipped: active sessions, Apple Health imports (the importer already read HR), BLE sessions (already ~1 Hz
/// and carrying RR a Health read lacks), already-dense series, and sessions older than `lookbackDays` (a sync
/// that late won't come, and re-querying forever costs a HealthKit read per launch).
/// Foundation only → unit-tested in `WorkoutHRBackfillTests`.
enum WorkoutHRBackfill {
    static let lookbackDays: Double = 3
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
        guard !c.isImportedFromHealth, c.metricsSourceRaw != "ble" else { return false }
        guard now.timeIntervalSince(end) <= lookbackDays * 86_400 else { return false }
        return HRCadence.summarize(c.hrSeries).perSecond < denseEnough
    }

    /// The series to store, or `nil` when Health added nothing (so the caller doesn't save).
    static func merged(stored: [HRPoint], health: [HRPoint]) -> [HRPoint]? {
        let best = HRSeriesDensify.denser(live: stored, healthKit: health)
        return best.count > stored.count ? best : nil
    }
}
