import SwiftUI
import HighlightEngine

/// A compact per-effort badge shared by the Kilter per-climb timeline and the WorkoutTracker per-set
/// tiles, so both surfaces render effort + recovery identically (one source of truth):
/// - a flame with the **peak** as %HRR when a real max-HR bound exists, else the raw peak bpm,
///   tinted by the peak's `HeartRateZone`;
/// - a **recovery dot** coloured by the bpm dropped after the peak (bigger drop = better recovery).
///
/// Renders nothing when the effort wasn't scored (`peakBpm == nil`) — i.e. HR-less sessions, the
/// watch path, or a set/climb with no usable window — so HR-less UI is unchanged. The bpm→zone
/// mapping is the pure `HeartRateZone`; this view holds no logic beyond formatting.
struct HREffortBadge: View {
    let effort: ClimbEffort
    /// Max HR for the %HRR→zone tint; defaults to the no-profile fallback (190).
    var maxHR: Double = HeartRateZone.defaultMaxHR

    var body: some View {
        if let peak = effort.peakBpm {
            let zone = HeartRateZone.forBpm(peak, maxHR: maxHR)
            HStack(spacing: 10) {
                Label {
                    Text(effort.peakHRR.map { "\(Int(($0 * 100).rounded()))% effort" }
                         ?? "\(Int(peak.rounded())) bpm peak")
                } icon: {
                    Image(systemName: "flame.fill")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(zone.color)
                if let drop = effort.hrRecovery60 ?? effort.hrRecovery30 {
                    HStack(spacing: 3) {
                        Circle().fill(Self.recoveryColor(drop)).frame(width: 7, height: 7)
                        Text("−\(Int(drop.rounded())) bpm rec.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("recovered \(Int(drop.rounded())) beats per minute after the peak")
                }
            }
        }
    }

    /// Bigger HR drop after the burn = better recovery (green); small = red. A relative within-session
    /// heuristic, not a clinical HR-recovery measure.
    static func recoveryColor(_ drop: Double) -> Color {
        switch drop {
        case ..<10: return .red
        case ..<25: return .orange
        default:    return .green
        }
    }
}
