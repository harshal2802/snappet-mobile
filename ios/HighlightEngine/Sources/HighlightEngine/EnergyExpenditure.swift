import Foundation

/// HR-based energy expenditure (kcal) from a heart-rate series — pure, platform-free math, so it is
/// unit-tested with `swift test`, no device. The app's `UserHRProfile` feeds it the scalars; the
/// engine never sees an app type.
///
/// Uses the **Keytel et al. (2005)** regression of energy expenditure on heart rate, sex, age, and
/// weight — the standard published HR→kcal estimator. It is an *estimate*, not a clinical/measured
/// figure (a watch's `activeEnergyBurned` is measured and preferred — callers gate this to the BLE
/// path, where the band reports no energy and we otherwise show `0`).
public enum EnergyExpenditure {

    /// Keytel kcal **per minute** for an instantaneous HR. Clamped at `0` so a low-HR/short-sample
    /// regression that goes slightly negative never subtracts from the running total.
    /// - male: the regression has only male/female terms; callers with an unspecified sex should not
    ///   call this (the profile gates energy off entirely in that case).
    public static func keytelKcalPerMinute(bpm: Double, ageYears: Double, weightKg: Double, male: Bool) -> Double {
        let raw: Double = male
            ? (-55.0969 + 0.6309 * bpm + 0.1988 * weightKg + 0.2017 * ageYears)
            : (-20.4022 + 0.4472 * bpm - 0.1263 * weightKg + 0.0740 * ageYears)
        return max(0, raw / 4.184)   // kJ/min → kcal/min
    }

    /// Total kcal over a session's bpm series. Each sample's rate "owns" the interval until the next
    /// sample (left-edge dwell, the same attribution as `WorkoutHRStats` time-in-zone), capped at
    /// `durationSec` so a trailing sample can't bill past the session end. Returns `nil` for an empty
    /// series or a non-positive duration (nothing to estimate → the UI hides the figure).
    ///
    /// - Parameters:
    ///   - samples: the HR series (any order; `t` seconds from session start).
    ///   - durationSec: the session length, the right edge of the last sample's interval.
    public static func keytelKcal(samples: [HRSample], durationSec: Double,
                                  ageYears: Double, weightKg: Double, male: Bool) -> Double? {
        let sorted = samples.sorted { $0.t < $1.t }
        guard durationSec > 0, !sorted.isEmpty else { return nil }
        var total = 0.0
        for i in sorted.indices {
            let next = i + 1 < sorted.count ? sorted[i + 1].t : durationSec
            let dwell = max(0, min(next, durationSec) - sorted[i].t)
            guard dwell > 0 else { continue }
            total += keytelKcalPerMinute(bpm: sorted[i].bpm, ageYears: ageYears,
                                         weightKg: weightKg, male: male) * (dwell / 60)
        }
        return total
    }
}
