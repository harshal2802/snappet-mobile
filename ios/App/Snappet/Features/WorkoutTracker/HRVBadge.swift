import SwiftUI
import HighlightEngine

/// A compact per-rest **HRV** badge shared by the Kilter per-climb timeline and the WorkoutTracker
/// per-set tiles (fitness-band Phase 3), so both surfaces render recovery-quality identically — the
/// sibling of `HREffortBadge`. Shows RMSSD (ms) tinted by how rested the gap looked (higher RMSSD =
/// better parasympathetic recovery), with the beat count for honest context.
///
/// Renders **nothing** when there's no usable HRV (`rmssd == nil`) — i.e. HR-less sessions, the watch
/// path, an optical / untrusted band (RR is dropped at capture), or a rest window with too few beats.
/// So every non-chest-strap surface is unchanged. The math is the pure `HRVMetrics`; this view only
/// formats. RMSSD is a within-user trend, not a clinical reading.
struct HRVBadge: View {
    let hrv: HRVMetrics

    var body: some View {
        if let rmssd = hrv.rmssd {
            HStack(spacing: 3) {
                Image(systemName: "waveform.path.ecg").font(.caption2)
                Text("\(Int(rmssd.rounded())) ms HRV")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
            }
            .foregroundStyle(Self.recoveryColor(rmssd))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Self.recoveryColor(rmssd).opacity(0.15), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("heart-rate variability \(Int(rmssd.rounded())) milliseconds over \(hrv.beatCount) beats of rest")
            .accessibilityIdentifier("hrvBadge")
        }
    }

    /// Higher RMSSD during rest = better recovery (green); low = still taxed (orange/red). A relative
    /// within-session heuristic, not a clinical HRV category.
    static func recoveryColor(_ rmssd: Double) -> Color {
        switch rmssd {
        case ..<20: return .red
        case ..<40: return .orange
        default:    return .green
        }
    }
}
