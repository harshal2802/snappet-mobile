import SwiftUI
import Charts
import HighlightEngine

/// Heart-rate summary components shared by **both** session-detail surfaces — the WorkoutTracker gym
/// session and the Kilter board session (#78). Before this, the Kilter summary plotted the raw series
/// as a hardcoded pink line with a hidden axis while WorkoutTracker had the smoothed, zone-coloured,
/// axis-labelled chart; now they render identically from one definition. `HighlightEngine` stays
/// platform-free — the resample/smooth is reused, not reimplemented.

/// A Swift Charts line of bpm over session time. The raw `hrSeries` is resampled + smoothed via
/// `HighlightEngine.HeartRateSeries` so the line is clean rather than jagged. The x-axis is elapsed
/// minutes. The caller sets the frame height.
struct HeartRateChart: View {
    let series: [HRPoint]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the line draw-in: the plotted bpm animates from 0 → actual on first appear.
    @State private var drawn = false

    /// The smoothed (bpm, t-seconds) points the chart draws.
    private var smoothed: [(t: Double, bpm: Double)] {
        let samples = series.map { HRSample(t: $0.t, bpm: $0.bpm) }
        let duration = max(1, series.map(\.t).max() ?? 0)
        // Reuse the engine's resample→smooth (5 s window is gentle for a chart line).
        let hr = HeartRateSeries.make(from: samples, duration: duration, dt: 1.0,
                                      smoothingWindowSec: 5, restBpm: nil, maxBpm: nil)
        return hr.bpm.enumerated().map { (t: Double($0.offset) * hr.dt, bpm: $0.element) }
    }

    var body: some View {
        Chart(smoothed, id: \.t) { point in
            LineMark(
                x: .value("Time", point.t / 60),
                // The line rises from the baseline on appear (issue #30 §5.7); Reduce Motion
                // shows it fully drawn immediately.
                y: .value("BPM", drawn || reduceMotion ? point.bpm : 0)
            )
            // Semantic HR colour — the zone ramp's hot end (kept as the HR scale).
            .foregroundStyle(HeartRateZone.max.color)
            .interpolationMethod(.catmullRom)
        }
        .chartXAxisLabel("min")
        .chartYAxisLabel("bpm")
        .animation(Snappet.snappetAnimation(SnappetMotion.expressive, reduceMotion: reduceMotion), value: drawn)
        .onAppear { drawn = true }
        .onDisappear { drawn = false }
    }
}

/// A horizontal time-in-zone bar (proportional segments per zone, zone-tinted) + a legend listing each
/// used zone with its minutes. Reuses `HeartRateZone` for colors/labels.
struct ZoneBar: View {
    let stats: WorkoutHRStats

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the segment width grow-in on appear.
    @State private var drawn = false

    private var used: [(zone: HeartRateZone, seconds: Double)] {
        stats.orderedZoneSeconds.filter { $0.seconds > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(used, id: \.zone.rawValue) { item in
                        let fraction = drawn || reduceMotion ? item.seconds / stats.totalSeconds : 0
                        item.zone.color
                            .frame(width: max(1, geo.size.width * fraction))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .animation(Snappet.snappetAnimation(SnappetMotion.standard, reduceMotion: reduceMotion), value: drawn)
            }
            .frame(height: 12)
            .accessibilityIdentifier("hrZoneBar")
            .onAppear { drawn = true }
            .onDisappear { drawn = false }

            ForEach(used, id: \.zone.rawValue) { item in
                HStack(spacing: 6) {
                    Circle().fill(item.zone.color).frame(width: 8, height: 8)
                    Text(item.zone.pillLabel).font(.caption)
                    Spacer()
                    Text(Self.minutesLabel(item.seconds))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func minutesLabel(_ seconds: Double) -> String {
        let mins = seconds / 60
        return mins >= 1 ? "\(Int(mins.rounded())) min" : "\(Int(seconds.rounded()))s"
    }
}

/// A small "ⓘ" button that explains the **HRV** and **recovery-dot** colour codes in a popover (#78) —
/// the payoff of the fitness-band arc was illegible because the badges' red/orange/green were never
/// explained or labelled as within-session heuristics. Rendered in each summary's Heart-rate header, so
/// both surfaces that show `HRVBadge` / `HREffortBadge` get the same in-UI legend. The swatch colours
/// come straight from the badge thresholds, so the legend can't drift from the badges.
struct HRMetricsInfoButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle").font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("What the heart-rate colours mean")
        .accessibilityIdentifier("hr.legend.info")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                legendRow(title: "HRV", systemImage: "waveform.path.ecg",
                          detail: "Beat-to-beat variation while you rest. Higher = better recovery.",
                          swatches: [("rested", HRVBadge.recoveryColor(50)),
                                     ("ok", HRVBadge.recoveryColor(30)),
                                     ("taxed", HRVBadge.recoveryColor(10))])
                legendRow(title: "Recovery dot", systemImage: "arrow.down.heart",
                          detail: "How far your heart rate drops after a peak. Bigger drop = better recovery.",
                          swatches: [("strong", HREffortBadge.recoveryColor(30)),
                                     ("ok", HREffortBadge.recoveryColor(15)),
                                     ("weak", HREffortBadge.recoveryColor(5))])
                Text("Both are within-session trends to compare your own efforts — not clinical readings.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 320)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func legendRow(title: String, systemImage: String, detail: String,
                           swatches: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ForEach(swatches, id: \.0) { label, color in
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 9, height: 9)
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
