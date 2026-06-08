import SwiftUI
import WidgetKit
import ActivityKit

/// Renders the WorkoutTracker Live Activity (live-workout-studio A2): the **overall workout
/// timer**, the **live heart rate**, and the **current exercise / set** on the Lock Screen and
/// in the Dynamic Island (compact / minimal / expanded). The app side
/// (`LiveActivityController`) starts/updates/ends it; this extension only renders the shared
/// `WorkoutActivityAttributes` — one source of truth for the contract.
///
/// The overall timer is `Text(timerInterval:)` anchored on `state.startedAt`, so the system
/// ticks it on the wall clock with no background CPU and it stays correct across backgrounding.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.5))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        timerText(context).font(.title3.monospacedDigit().weight(.semibold))
                    } icon: {
                        Image(systemName: "stopwatch")
                    }
                    .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    heartLabel(context).font(.title3.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.exerciseName)
                            .font(.headline).lineLimit(1)
                        if !context.state.setProgress.isEmpty {
                            Text(context.state.setProgress)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill" : "stopwatch")
                    .foregroundStyle(context.state.paused ? .yellow : .orange)
            } compactTrailing: {
                timerText(context).font(.caption2.monospacedDigit()).frame(width: 44)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "figure.run")
                    .foregroundStyle(context.state.paused ? .yellow : .orange)
            }
            .keylineTint(context.state.paused ? .yellow : .orange)
        }
    }

    /// The overall timer, or a "Paused" label when the workout is paused (so the
    /// notification-area status matches the wrist + phone rather than ticking on while paused).
    @ViewBuilder private func timerText(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        if context.state.paused {
            Text("Paused")
        } else {
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
        }
    }

    /// Heart rate, tinted by its `HeartRateZone` (shared with the phone overlay + watch face).
    private func heartLabel(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> some View {
        let zone = HeartRateZone.forBpm(context.state.hrBpm.map(Double.init),
                                         maxHR: context.attributes.maxHR ?? HeartRateZone.defaultMaxHR)
        return Label {
            Text(context.state.hrBpm.map { "\($0)" } ?? "—")
        } icon: {
            Image(systemName: "heart.fill")
        }
        .foregroundStyle(zone == .none ? .pink : zone.color)
    }
}

/// The Lock Screen / banner presentation. Shared helpers kept private to the file.
private struct LockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    private var zone: HeartRateZone { HeartRateZone.forBpm(context.state.hrBpm.map(Double.init),
                                         maxHR: context.attributes.maxHR ?? HeartRateZone.defaultMaxHR) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.routineName, systemImage: "dumbbell.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    .lineLimit(1)
                if context.state.paused {
                    Text("PAUSED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.25), in: Capsule())
                        .foregroundStyle(.yellow)
                }
                if context.state.recoveryReady {
                    Label("Recovered", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.22), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                Label {
                    Text(context.state.hrBpm.map { "\($0) bpm" } ?? "—")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "heart.fill")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(zone == .none ? .pink : zone.color)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.exerciseName).font(.headline).lineLimit(1)
                    if !context.state.setProgress.isEmpty {
                        Text(context.state.setProgress)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if context.state.paused {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.headline.weight(.bold)).foregroundStyle(.yellow)
                } else {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                        .font(.title.monospacedDigit().weight(.bold))
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}
