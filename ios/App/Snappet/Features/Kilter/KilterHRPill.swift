import SwiftUI

/// A compact heart-rate pill tinted by its `HeartRateZone` (shared with the Live Activity + watch
/// face). Used in the Kilter session HUD — the root active-session banner and the climb detail —
/// while live HR is being captured. Shows "—" before the first sample arrives.
struct KilterHRPill: View {
    let bpm: Double?
    /// Drop the " bpm" suffix where space is tight (the root banner).
    var compact: Bool = false

    private var zone: HeartRateZone { HeartRateZone.forBpm(bpm) }

    var body: some View {
        Label(bpm.map { "\(Int($0))\(compact ? "" : " bpm")" } ?? "—", systemImage: "heart.fill")
            .font(.subheadline.weight(.semibold)).monospacedDigit()
            .foregroundStyle(zone == .none ? AnyShapeStyle(.pink) : AnyShapeStyle(zone.color))
            .accessibilityLabel(bpm.map { "Heart rate \(Int($0)) beats per minute" } ?? "Heart rate unavailable")
    }
}
