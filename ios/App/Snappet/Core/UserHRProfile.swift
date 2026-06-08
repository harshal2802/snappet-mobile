import Foundation
import Observation
import HighlightEngine

/// Biological sex, for the HR-based calorie estimate. The Keytel regression has only male/female
/// terms, so an `unspecified` sex gates the energy estimate off entirely (honest, never a guess).
enum BiologicalSex: String, Codable, Sendable, CaseIterable, Identifiable {
    case unspecified, female, male
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unspecified: return "Prefer not to say"
        case .female:      return "Female"
        case .male:        return "Male"
        }
    }
}

/// A small, on-device, **app-agnostic** heart-rate profile — the keystone that replaces the single
/// hardcoded `HeartRateZone.defaultMaxHR = 190` so zones, `%HRR`, per-set/per-climb effort, and the
/// HR-based calorie estimate personalize to the user in **both** WorkoutTracker and Kilter.
///
/// A pure `Codable` value type (no platform deps beyond the engine's pure math) so its derivations
/// are unit-tested in `SnappetTests` with no device. Persisted by `UserProfileStore`; the resolved
/// `maxHR` also travels to the watch + widget as a wire field. The profile is the user's and never
/// leaves the device (on-device-only stance).
///
/// **Gating is the whole point:** every field is optional, and `resolvedMaxHR` is `nil` until the
/// user provides an age or a measured max — so with no profile the app behaves *exactly* as the
/// Phase-1 bpm-only defaults, identically in both apps (the roadmap's symmetric-gating invariant).
struct UserHRProfile: Codable, Equatable, Sendable {
    /// Age in years (manual, or derived from HealthKit date-of-birth). Drives the max-HR estimate.
    var age: Int?
    /// Resting heart rate (bpm), the lower bound for `%HRR`. `nil` → the engine estimates it.
    var restingHR: Int?
    /// A measured/known max HR (bpm). Wins over the age estimate when set (some users have tested it).
    var maxHROverride: Int?
    /// Body mass in kilograms, for the Keytel calorie estimate.
    var weightKg: Double?
    /// Biological sex, for the Keytel calorie estimate (`unspecified` → no estimate).
    var sex: BiologicalSex

    static let empty = UserHRProfile(age: nil, restingHR: nil, maxHROverride: nil,
                                     weightKg: nil, sex: .unspecified)

    /// The personalized max HR when the profile carries enough to compute one: an explicit override,
    /// else the **Tanaka** age estimate `208 − 0.7·age` (the current physiological standard, more
    /// accurate than the older `220 − age`; decisions.md 2026-06-08). `nil` when neither is known, so
    /// callers fall back to `HeartRateZone.defaultMaxHR` and `%HRR` stays the honest bpm-only state.
    var resolvedMaxHR: Double? {
        if let m = maxHROverride, m > 0 { return Double(m) }
        if let age, age > 0, age < 120 { return 208 - 0.7 * Double(age) }
        return nil
    }

    /// Resting HR as a `Double` bound for `%HRR`, when known and positive.
    var restingBound: Double? {
        guard let restingHR, restingHR > 0 else { return nil }
        return Double(restingHR)
    }

    /// Whether the profile carries everything the Keytel kcal estimate needs (age, weight, and a
    /// male/female sex). Energy is gated off when any is missing — symmetrically in both apps.
    var canEstimateEnergy: Bool {
        guard let age, age > 0, let weightKg, weightKg > 0 else { return false }
        return sex == .male || sex == .female
    }

    /// HR-based energy estimate (kcal) over a session's persisted bpm series, or `nil` when the
    /// profile lacks the inputs — a pure pass-through to the engine's `EnergyExpenditure` (Keytel).
    /// Callers gate this to **BLE** sessions (the watch measures real energy; never override it).
    func estimatedKcal(forSeries series: [HRPoint], durationSec: Double) -> Double? {
        guard canEstimateEnergy, let age, let weightKg else { return nil }
        return EnergyExpenditure.keytelKcal(
            samples: series.map { HRSample(t: $0.t, bpm: $0.bpm) },
            durationSec: durationSec, ageYears: Double(age), weightKg: weightKg, male: sex == .male)
    }

    /// Merge non-nil prefill values (e.g. from HealthKit) into **blank** fields only — a user-typed
    /// value is never clobbered. `sex` is filled only when currently `.unspecified`.
    func merging(prefill: UserHRProfile) -> UserHRProfile {
        var out = self
        if out.age == nil { out.age = prefill.age }
        if out.restingHR == nil { out.restingHR = prefill.restingHR }
        if out.maxHROverride == nil { out.maxHROverride = prefill.maxHROverride }
        if out.weightKg == nil { out.weightKg = prefill.weightKg }
        if out.sex == .unspecified { out.sex = prefill.sex }
        return out
    }
}

/// The single, app-wide store for the `UserHRProfile`, owned by `AppModel` and shared by both apps.
/// Persists to `UserDefaults` as JSON (the profile is tiny + read often; a SwiftData model would be
/// overkill and the value isn't queried/related). `@Observable` so editing it live-updates any open
/// summary's personalized zones.
@MainActor
@Observable
final class UserProfileStore {
    private static let key = "snappet.userHRProfile"
    private(set) var profile: UserHRProfile

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(UserHRProfile.self, from: data) {
            profile = decoded
        } else {
            profile = .empty
        }
    }

    private let defaults: UserDefaults

    /// Replace the profile and persist it.
    func update(_ profile: UserHRProfile) {
        self.profile = profile
        if let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
