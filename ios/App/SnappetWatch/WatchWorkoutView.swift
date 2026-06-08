import SwiftUI

/// The watch live-workout face. Starting is driven from the phone (A1's watch-trigger), so
/// there's no Start control here — the watch waits for the phone's `start` message, then shows
/// a **two-page** experience the user swipes between (vertical paging, the watchOS-native
/// workout idiom):
///
///   • **Metrics** — a big, zone-colored heart rate (reusing the shared `HeartRateZone` so the
///     wrist matches the phone overlay + Live Activity), the overall elapsed timer, active
///     energy, and the session-average HR. A "Paused" badge appears when the session is paused.
///   • **Controls** — Pause / Resume and End, so the workout can be driven from the wrist while
///     the phone is pocketed.
///
/// All on-wrist controls relay over `WCSession` (pause/resume/end), so the phone's overlay and
/// Live Activity stay in lock-step with the watch.
struct WatchWorkoutView: View {
    @Environment(WorkoutWatchManager.self) private var manager

    var body: some View {
        Group {
            if manager.isRunning {
                TabView {
                    MetricsPage(manager: manager)
                    ControlsPage(manager: manager)
                }
                .tabViewStyle(.verticalPage)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                ContentUnavailableView(
                    "No Workout",
                    systemImage: "applewatch",
                    description: Text("Start a routine on your iPhone to begin tracking here.")
                )
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: manager.isRunning)
        .animation(.snappy, value: manager.paused)
    }
}

/// Page 1 — the live metrics. Heart rate is the hero, tinted by its `HeartRateZone`.
private struct MetricsPage: View {
    let manager: WorkoutWatchManager

    private var zone: HeartRateZone {
        HeartRateZone.forBpm(manager.latestHR > 0 ? manager.latestHR : nil,
                             maxHR: manager.maxHR ?? HeartRateZone.defaultMaxHR)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "stopwatch")
                Text(timeString(manager.elapsed))
                    .font(.title3.monospacedDigit().weight(.semibold))
                if manager.paused {
                    Text("PAUSED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.25), in: Capsule())
                        .foregroundStyle(.yellow)
                }
            }
            .foregroundStyle(manager.paused ? .yellow : .orange)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(zone == .none ? .pink : zone.color)
                    .symbolEffect(.pulse, isActive: manager.latestHR > 0 && !manager.paused)
                Text(manager.latestHR > 0 ? "\(Int(manager.latestHR.rounded()))" : "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(zone == .none ? .primary : zone.color)
                Text("bpm").font(.caption).foregroundStyle(.secondary)
            }
            if zone != .none {
                Text(zone.pillLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(zone.color.opacity(0.18), in: Capsule())
                    .foregroundStyle(zone.color)
            }

            HStack(spacing: 14) {
                stat("\(Int(manager.energyKcal.rounded()))", "kcal")
                stat(manager.avgHR > 0 ? "\(Int(manager.avgHR.rounded()))" : "--", "avg")
            }
            .padding(.top, 2)
        }
        .padding()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.body.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let h = s / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Page 2 — pause/resume and end, driven on the wrist and relayed to the phone.
private struct ControlsPage: View {
    let manager: WorkoutWatchManager

    var body: some View {
        VStack(spacing: 12) {
            Button {
                if manager.paused { manager.resume() } else { manager.pause() }
            } label: {
                Label(manager.paused ? "Resume" : "Pause",
                      systemImage: manager.paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(manager.paused ? .green : .yellow)

            Button(role: .destructive) { manager.end() } label: {
                Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .padding()
    }
}
