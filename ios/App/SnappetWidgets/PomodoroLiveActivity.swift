import SwiftUI
import WidgetKit
import ActivityKit

/// Renders the **Pomodoro focus-timer** Live Activity: the **phase countdown**, and the
/// **phase label** (Focus / Break) on the Lock Screen and in the Dynamic Island (compact /
/// minimal / expanded). The app side (`PomodoroLiveActivityController`) starts/updates/ends it;
/// this extension only renders the shared `PomodoroActivityAttributes`.
///
/// The countdown is `Text(timerInterval:)` anchored on `state.endDate`, so the system ticks it
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
                        countdownText(context)
                            .font(.title3.monospacedDigit().weight(.semibold))
                    } icon: {
                        Image(systemName: "timer")
                    }
                    .foregroundStyle(phaseTint(context))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(context.state.phaseLabel,
                          systemImage: context.state.isFocus ? "brain.head.profile" : "cup.and.saucer.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(phaseTint(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.isFocus ? "Stay focused" : "Rest up")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if context.state.paused {
                            Text("PAUSED")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.yellow.opacity(0.25), in: Capsule())
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill" : "timer")
                    .foregroundStyle(context.state.paused ? .yellow : phaseTint(context))
            } compactTrailing: {
                countdownText(context)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill"
                      : (context.state.isFocus ? "brain.head.profile" : "cup.and.saucer.fill"))
                    .foregroundStyle(context.state.paused ? .yellow : phaseTint(context))
            }
            .keylineTint(context.state.paused ? .yellow : phaseTint(context))
        }
    }

    /// The countdown timer, or a static remaining-time string when paused.
    @ViewBuilder
    private func countdownText(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> some View {
        if context.state.paused {
            let m = context.state.remainingSeconds / 60
            let s = context.state.remainingSeconds % 60
            Text(String(format: "%02d:%02d", m, s))
        } else {
            Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
        }
    }

    private func phaseTint(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> Color {
        context.state.isFocus ? Color(red: 0.898, green: 0.282, blue: 0.239) : Color(red: 0.247, green: 0.616, blue: 0.333)
    }
}

/// The Lock Screen / banner presentation for a Pomodoro focus session.
private struct PomodoroLockScreenView: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    private var tint: Color {
        context.state.isFocus
            ? Color(red: 0.898, green: 0.282, blue: 0.239)
            : Color(red: 0.247, green: 0.616, blue: 0.333)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.state.phaseLabel,
                      systemImage: context.state.isFocus ? "brain.head.profile" : "cup.and.saucer.fill")
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
                timerDisplay
            }
        }
    }

    @ViewBuilder private var timerDisplay: some View {
        if context.state.paused {
            let m = context.state.remainingSeconds / 60
            let s = context.state.remainingSeconds % 60
            Text(String(format: "%02d:%02d", m, s))
                .font(.title.monospacedDigit().weight(.bold))
                .foregroundStyle(.primary)
        } else {
            Text(timerInterval: Date.now...context.state.endDate, countsDown: true)
                .font(.title.monospacedDigit().weight(.bold))
                .foregroundStyle(.primary)
        }
    }
}
