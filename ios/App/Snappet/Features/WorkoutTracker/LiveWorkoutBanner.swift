import SwiftUI

/// The persistent "a workout is running" banner shown in the WorkoutTracker home while the live
/// player is minimized (background-workout ask). It keeps live metrics in front of the user —
/// the routine name, the self-ticking overall timer, and a zone-colored live HR — even after
/// they've navigated back out of the full-screen player, and tapping it brings the player back.
///
/// Pure presentation: it's handed already-resolved values (the bpm→zone mapping is the shared,
/// unit-tested `HeartRateZone`) plus a `resume` action, so it carries no workout logic. The
/// overall timer is `Text(timerInterval:)` so it self-updates off the wall clock with no
/// background CPU, exactly like the player header and the Live Activity.
struct LiveWorkoutBanner: View {
    let routineName: String
    let startedAt: Date
    /// Latest heart rate (bpm), or `nil` before the first sample / when no source is connected.
    let bpm: Int?
    let paused: Bool
    let resume: () -> Void

    private var zone: HeartRateZone { HeartRateZone.forBpm(bpm.map(Double.init)) }

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 12) {
                Image(systemName: paused ? "pause.circle.fill" : "figure.run.circle.fill")
                    .font(.title2)
                    .foregroundStyle(paused ? .yellow : .orange)
                    .symbolEffect(.pulse, isActive: !paused)

                VStack(alignment: .leading, spacing: 1) {
                    Text(routineName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if paused {
                            Text("Paused")
                                .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                        } else {
                            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text("· Tap to resume")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(zone == .none ? .pink : zone.color)
                        .symbolEffect(.pulse, isActive: bpm != nil && !paused)
                    Text(bpm.map { "\($0)" } ?? "—")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(zone == .none ? .primary : zone.color)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder((paused ? Color.yellow : Color.orange).opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("liveWorkoutBanner")
        .accessibilityLabel("Workout in progress: \(routineName)")
        .accessibilityHint("Double-tap to return to the workout")
    }
}
