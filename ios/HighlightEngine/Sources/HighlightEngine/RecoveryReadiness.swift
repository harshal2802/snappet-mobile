import Foundation

/// Live "recovery ready" assessment — is the user rested enough for the next burn (the next climb /
/// the next set)? Pure, platform-free value type (engine constraint), so the readiness decision is
/// unit-tested with `swift test`, no device. The apps compute it live from the latest bpm + the
/// user's profile bounds and surface a nudge on the HUD / Live Activity / watch / widget
/// (fitness-band Phase 4).
///
/// **Gating is structural:** readiness needs the profile's rest + max HR bounds (Phase 2). Without
/// them it's `.unknown` and every surface hides the nudge — identically in both apps, so a user
/// without a profile sees today's behavior. HRV rebound (Phase 3) is an optional *sharpener*, never
/// required.
public struct RecoveryReadiness: Sendable, Equatable {
    public enum State: String, Sendable {
        /// No profile bounds / no live HR → the nudge is hidden.
        case unknown
        /// HR still elevated above the ready threshold — keep resting.
        case recovering
        /// HR has dropped back near rest — good to go for the next effort.
        case ready
    }

    public let state: State
    /// How recovered toward rest, 0…1 (1 = at/below resting HR). `0` for `.unknown`.
    public let fraction: Double

    public static let unknown = RecoveryReadiness(state: .unknown, fraction: 0)

    public init(state: State, fraction: Double) {
        self.state = state
        self.fraction = fraction
    }

    /// Evaluate readiness from the current bpm against the user's rest/max HR.
    ///
    /// - currentBpm: the latest live heart rate (`nil`/≤0 → `.unknown`).
    /// - restBpm / maxBpm: the profile's bounds; **both required** (`max > rest`) or `.unknown`.
    /// - rrReboundFraction: optional 0…1 — how far recent RR-HRV has rebounded toward its rested
    ///   baseline (Phase 3). When known, it eases the bpm threshold a touch (a well-recovered HRV
    ///   calls "ready" slightly sooner); ignored when `nil`.
    /// - readyHRRThreshold: the %HRR at/below which the user is "ready" (default 0.40 — i.e. HR back
    ///   under 40% of heart-rate reserve).
    ///
    /// Ready when current `%HRR ≤ eased threshold`, else `recovering`. `fraction = 1 − %HRR`.
    public static func evaluate(currentBpm: Double?, restBpm: Double?, maxBpm: Double?,
                                rrReboundFraction: Double? = nil,
                                readyHRRThreshold: Double = 0.40) -> RecoveryReadiness {
        guard let cur = currentBpm, cur > 0,
              let rest = restBpm, let mx = maxBpm, mx > rest else { return .unknown }
        let hrr = min(1, max(0, (cur - rest) / (mx - rest)))
        let fraction = 1 - hrr
        // A rebounded HRV eases the threshold by up to +0.10 (ready a touch sooner).
        let eased = readyHRRThreshold + 0.10 * min(1, max(0, rrReboundFraction ?? 0))
        return RecoveryReadiness(state: hrr <= eased ? .ready : .recovering, fraction: fraction)
    }
}
