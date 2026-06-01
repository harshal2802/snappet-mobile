import SwiftUI

/// Minimal watch UI: current HR + elapsed + a Stop button. Starting is normally
/// driven from the phone (A1's watch-trigger), so there is no Start control here —
/// the watch waits for the phone's `start` message, then shows live metrics.
struct WatchWorkoutView: View {
    @Environment(WorkoutWatchManager.self) private var manager

    var body: some View {
        VStack(spacing: 12) {
            if manager.isRunning {
                VStack(spacing: 2) {
                    Text(timeString(manager.elapsed))
                        .font(.title2.monospacedDigit().weight(.semibold))
                    Text("Elapsed").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                    Text(manager.latestHR > 0 ? "\(Int(manager.latestHR.rounded()))" : "--")
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    Text("bpm").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(Int(manager.energyKcal.rounded())) kcal")
                    .font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { manager.end() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .tint(.red)
            } else {
                ContentUnavailableView(
                    "No Workout",
                    systemImage: "applewatch",
                    description: Text("Start a routine on your iPhone to begin tracking here.")
                )
            }
        }
        .padding()
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
