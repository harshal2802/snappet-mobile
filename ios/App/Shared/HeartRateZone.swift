import SwiftUI

/// A heart-rate training zone, derived purely from a bpm value and a configurable max HR.
///
/// This is a **plain value type** — no HealthKit, no device, no `MetricsSource` — so the
/// bpm→zone mapping (and its boundaries / no-data case) is unit-testable in `SnappetTests`
/// with no simulator. The A4 live-metrics overlay maps `app.liveWorkout.latestHR` through
/// `HeartRateZone.forBpm(_:maxHR:)` to render a colored, labelled HR pill
/// (live-workout-studio A4). `Color` is the only SwiftUI surface used, and it's a value type,
/// so this stays trivially testable.
///
/// **Lives in `Shared/`** (compiled into the phone app, the watchOS companion, and the widget
/// extension — see `project.yml`) so the watch HR face and the Live Activity render the *same*
/// zone color/label as the phone overlay, with one source of truth for the bpm→zone mapping.
///
/// **Why a fixed default max HR (`defaultMaxHR = 190`)**: it's the fallback when the user hasn't
/// filled an HR profile. Since fitness-band Phase 2 a `UserHRProfile` resolves a real max HR
/// (a measured override, else the Tanaka estimate `208 − 0.7·age`) and callers pass it in via
/// `maxHR:` — sessions stamp `maxHR`/`restHR` and personalize zones/%HRR/effort/calories. With no
/// profile, `resolvedMaxHR` is `nil` → callers fall back to this `190` and behave exactly as before.
/// 190 is a reasonable mid-range adult ceiling — meaningful *relative* zone color without pretending
/// to be a personalized prescription. The zone math is unchanged either way; the zones are the common
/// 5-zone %-of-max model (recovery / easy / aerobic / threshold / max).
enum HeartRateZone: Int, CaseIterable, Equatable, Sendable {
    /// No HR sample / no source connected — the overlay shows its "no source" state instead
    /// of a colored zone. Distinct from "a real bpm that happens to be very low".
    case none = 0
    /// Zone 1 — < 60% max. Recovery / very light.
    case recovery = 1
    /// Zone 2 — 60–70% max. Easy / fat-burn.
    case easy = 2
    /// Zone 3 — 70–80% max. Aerobic / endurance.
    case aerobic = 3
    /// Zone 4 — 80–90% max. Threshold / hard.
    case threshold = 4
    /// Zone 5 — ≥ 90% max. Maximum / anaerobic.
    case max = 5

    /// The default max HR used when no user HR profile exists yet (see the type doc-comment
    /// for *why* this is a fixed constant rather than `220 − age`).
    static let defaultMaxHR: Double = 190

    /// Map a bpm to a zone given a max HR. `bpm == nil` (or a non-positive `maxHR`) → `.none`,
    /// so a missing sample never renders as a misleading "zone 1". Boundaries are inclusive at
    /// the lower bound (e.g. exactly 60% max is `.easy`), matching the common convention.
    static func forBpm(_ bpm: Double?, maxHR: Double = defaultMaxHR) -> HeartRateZone {
        guard let bpm, bpm > 0, maxHR > 0 else { return .none }
        let pct = bpm / maxHR
        switch pct {
        case ..<0.60: return .recovery
        case ..<0.70: return .easy
        case ..<0.80: return .aerobic
        case ..<0.90: return .threshold
        default:      return .max
        }
    }

    /// A short label for the HR pill ("Z2 · Easy"-style short form lives in `pillLabel`).
    var label: String {
        switch self {
        case .none:      return "—"
        case .recovery:  return "Recovery"
        case .easy:      return "Easy"
        case .aerobic:   return "Aerobic"
        case .threshold: return "Threshold"
        case .max:       return "Max"
        }
    }

    /// A compact label for the overlay pill, e.g. "Z3 · Aerobic". `.none` has no zone number.
    var pillLabel: String {
        self == .none ? label : "Z\(rawValue) · \(label)"
    }

    /// The zone color for the HR pill. A cool→hot ramp (blue→green→orange→red); `.none` is
    /// secondary/gray so the pill reads as inert when there's no source.
    var color: Color {
        switch self {
        case .none:      return .secondary
        case .recovery:  return .blue
        case .easy:      return .teal
        case .aerobic:   return .green
        case .threshold: return .orange
        case .max:       return .red
        }
    }
}
