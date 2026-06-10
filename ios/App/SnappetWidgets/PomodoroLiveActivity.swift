import SwiftUI
import WidgetKit
import ActivityKit

/// Renders the **Pomodoro focus-session** Live Activity: the current **phase label** and
/// a **countdown timer** on the Lock Screen and in the Dynamic Island (compact / minimal /
/// expanded). The app side (`PomodoroLiveActivityController`) starts/updates/ends it; this
/// extension only renders the shared `PomodoroActivityAttributes`.
///
/// The countdown is `Text(timerInterval: Date.distantPast...state.endDate, countsDown: true)`,
/// so the OS ticks it on the wall clock with no background CPU and it stays correct across
/// backgrounding. When paused, a static "Paused" label replaces the timer.
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
                        Text(context.state.phase)
                            .font(.title3.weight(.semibold))
                    } icon: {
                        Image(systemName: phaseIcon(context.state.phase))
                    }
                    .foregroundStyle(phaseTint(context.state.phase))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdownText(context)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.paused {
                        Label("Paused", systemImage: "pause.fill")
                            .font(.caption).foregroundStyle(.yellow)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill" : phaseIcon(context.state.phase))
                    .foregroundStyle(context.state.paused ? .yellow : phaseTint(context.state.phase))
            } compactTrailing: {
                countdownText(context)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : phaseIcon(context.state.phase))
                    .foregroundStyle(context.state.paused ? .yellow : phaseTint(context.state.phase))
            }
            .keylineTint(context.state.paused ? .yellow : phaseTint(context.state.phase))
        }
    }

    /// The countdown, or a "Paused" label when the session is paused.
    @ViewBuilder
    private func countdownText(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> some View {
        if context.state.paused {
            Text("Paused").foregroundStyle(.yellow)
        } else {
            Text(timerInterval: Date.distantPast...context.state.endDate, countsDown: true)
        }
    }

    private func phaseIcon(_ phase: String) -> String {
        phase == "Focus" ? "brain.head.profile" : "cup.and.saucer.fill"
    }

    // Mirror SnappetColor.pomodoro (tomato) and SnappetColor.habits (leaf-green).
    // Duplicated here because SnappetColor is app-target-only; the widget shares only Shared/.
    private func phaseTint(_ phase: String) -> Color {
        phase == "Focus"
            ? Color(.displayP3, red: 0.898, green: 0.282, blue: 0.239)
            : Color(.displayP3, red: 0.247, green: 0.616, blue: 0.333)
    }
}

/// The Lock Screen / banner presentation for a Pomodoro session.
private struct PomodoroLockScreenView: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    private var tint: Color {
        context.state.phase == "Focus"
            ? Color(.displayP3, red: 0.898, green: 0.282, blue: 0.239)
            : Color(.displayP3, red: 0.247, green: 0.616, blue: 0.333)
    }

    private var phaseIcon: String {
        context.state.phase == "Focus" ? "brain.head.profile" : "cup.and.saucer.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.state.phase, systemImage: phaseIcon)
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
            }
            HStack(alignment: .firstTextBaseline) {
                if context.state.paused {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.yellow)
                } else {
                    Text(timerInterval: Date.distantPast...context.state.endDate, countsDown: true)
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
        }
    }
}
