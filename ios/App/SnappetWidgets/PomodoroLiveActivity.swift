import SwiftUI
import WidgetKit
import ActivityKit

/// Renders the **Pomodoro focus session** Live Activity: the **phase countdown**, the **phase
/// label** (Focus / Break), and a **Paused** badge when the timer is paused, on the Lock Screen
/// and in the Dynamic Island (compact / minimal / expanded). The app side
/// (`PomodoroLiveActivityController`) starts/updates/ends it; this extension only renders the
/// shared `PomodoroActivityAttributes` — one source of truth for the contract.
///
/// The phase countdown is `Text(timerInterval: now...phaseEndDate, countsDown: true)`, so the
/// system ticks it on the wall clock with no background CPU and it stays correct across
/// backgrounding.
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
                        Image(systemName: context.state.phaseLabel == "Focus" ? "timer" : "cup.and.saucer.fill")
                    }
                    .foregroundStyle(context.state.phaseLabel == "Focus" ? Color.red : Color.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.paused {
                        Label("Paused", systemImage: "pause.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.yellow)
                    } else {
                        Text("\(context.attributes.focusMinutes) min")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text(context.state.phaseLabel)
                            .font(.headline)
                        if context.state.paused {
                            Text("· Paused")
                                .font(.subheadline).foregroundStyle(.yellow)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill"
                      : (context.state.phaseLabel == "Focus" ? "timer" : "cup.and.saucer.fill"))
                    .foregroundStyle(context.state.paused ? .yellow
                                     : (context.state.phaseLabel == "Focus" ? .red : .green))
            } compactTrailing: {
                countdownText(context).font(.caption2.monospacedDigit()).frame(width: 44)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "timer")
                    .foregroundStyle(context.state.paused ? .yellow : .red)
            }
            .keylineTint(context.state.paused ? .yellow
                         : (context.state.phaseLabel == "Focus" ? .red : .green))
        }
    }

    /// The phase countdown, or a "Paused" label when the timer is paused.
    @ViewBuilder
    private func countdownText(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> some View {
        if context.state.paused {
            Text("Paused")
        } else {
            Text(timerInterval: Date.now...context.state.phaseEndDate, countsDown: true)
        }
    }
}

/// The Lock Screen / banner presentation for a Pomodoro session.
private struct PomodoroLockScreenView: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    private var isFocus: Bool { context.state.phaseLabel == "Focus" }
    private var tint: Color { isFocus ? .red : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.state.phaseLabel,
                      systemImage: isFocus ? "timer" : "cup.and.saucer.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                if context.state.paused {
                    Text("PAUSED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.25), in: Capsule())
                        .foregroundStyle(.yellow)
                }
                Spacer()
                Text("\(context.attributes.focusMinutes) min focus")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                if context.state.paused {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.title.weight(.bold)).foregroundStyle(.yellow)
                } else {
                    Text(timerInterval: Date.now...context.state.phaseEndDate, countsDown: true)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
        }
    }
}
