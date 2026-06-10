import SwiftUI
import WidgetKit
import ActivityKit

/// Renders the Pomodoro focus session Live Activity: the **phase label** (Focus / Break) and a
/// **countdown to the next phase end** on the Lock Screen and in the Dynamic Island (compact /
/// minimal / expanded). The app side (`PomodoroLiveActivityController`) starts/updates/ends it;
/// this extension only renders the shared `PomodoroActivityAttributes` — one source of truth.
///
/// The countdown is `Text(timerInterval:)` anchored on `phaseEndDate`, so the system ticks it
/// on the wall clock with no background CPU and it stays correct across backgrounding.
struct PomodoroLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomodoroActivityAttributes.self) { context in
            PomodoroLockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.5))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        countdownText(context).font(.title3.monospacedDigit().weight(.semibold))
                    } icon: {
                        Image(systemName: phaseIcon(context))
                    }
                    .foregroundStyle(phaseColor(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.phaseLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(phaseColor(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.paused ? "Timer paused" : "Stay focused")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill" : phaseIcon(context))
                    .foregroundStyle(context.state.paused ? .yellow : phaseColor(context))
            } compactTrailing: {
                countdownText(context).font(.caption2.monospacedDigit()).frame(width: 44)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "timer")
                    .foregroundStyle(context.state.paused ? .yellow : phaseColor(context))
            }
            .keylineTint(context.state.paused ? .yellow : phaseColor(context))
        }
    }

    /// Countdown to phase end, or "Paused" when the timer is stopped.
    @ViewBuilder private func countdownText(
        _ context: ActivityViewContext<PomodoroActivityAttributes>
    ) -> some View {
        if context.state.paused {
            Text("Paused")
        } else {
            Text(timerInterval: Date.now...context.state.phaseEndDate, countsDown: true)
        }
    }

    private func phaseColor(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> Color {
        context.state.phaseLabel == "Focus" ? .red : .green
    }

    private func phaseIcon(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> String {
        context.state.phaseLabel == "Focus" ? "brain.head.profile" : "cup.and.saucer.fill"
    }
}

/// The Lock Screen / banner presentation for a Pomodoro session.
private struct PomodoroLockScreenView: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    private var color: Color {
        context.state.phaseLabel == "Focus" ? .red : .green
    }
    private var icon: String {
        context.state.phaseLabel == "Focus" ? "brain.head.profile" : "cup.and.saucer.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.state.phaseLabel, systemImage: icon)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(color)
                    .lineLimit(1)
                if context.state.paused {
                    Text("PAUSED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.25), in: Capsule())
                        .foregroundStyle(.yellow)
                }
                Spacer()
            }
            if context.state.paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.title.monospacedDigit().weight(.bold)).foregroundStyle(.yellow)
            } else {
                Text(timerInterval: Date.now...context.state.phaseEndDate, countsDown: true)
                    .font(.title.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
            }
        }
    }
}
