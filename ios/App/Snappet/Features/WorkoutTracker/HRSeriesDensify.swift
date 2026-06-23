import Foundation

/// **Pure** chooser between a session's live-relay HR series and a post-hoc HealthKit read of the SAME
/// session window — the testable core of the watch-HR densification (HR-granularity epic / prompt 102).
///
/// The Apple-Watch live `WCSession` relay surfaces HR only ~every 5–15 s, but the on-wrist
/// `HKWorkoutSession` stores the full series (~1 per 1–5 s). Both are the *same* heart rate — one
/// relayed-and-thinned, one stored-and-complete — so the right move is to keep the **denser whole
/// series**, not union two copies of the same beats (which would double-count and jitter the chart).
///
/// Only the watch path is densified by the caller; BLE stays on its own ~1 Hz buffer (which also carries
/// RR that a HealthKit `heartRate` read lacks). Foundation only → unit-tested with no device.
enum HRSeriesDensify {

    /// The series to persist: HealthKit when it is strictly denser (more samples), else the live buffer.
    /// Empty HealthKit (read failed / not synced / BLE-only) → keep `live`; empty `live` → take HealthKit.
    /// A tie keeps `live` (no reason to churn the stored series for equal density).
    static func denser(live: [HRPoint], healthKit: [HRPoint]) -> [HRPoint] {
        if healthKit.isEmpty { return live }
        if live.isEmpty { return healthKit }
        return healthKit.count > live.count ? healthKit : live
    }
}
