import SwiftUI
import WidgetKit
import ActivityKit

/// Renders the **Pomodoro** Live Activity: the phase (Focus / Break) and its countdown on
/// the Lock Screen and in the Dynamic Island. The app side
/// (`PomodoroLiveActivityController`) starts/updates/ends it; this extension only renders
/// the shared `PomodoroActivityAttributes` — one source of truth for the contract.
///
/// Countdown and progress are `Text(timerInterval:)` / `ProgressView(timerInterval:)`
/// anchored on `phaseStartedAt...endDate`, so the system ticks them on the wall clock
/// with no background CPU.
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
                    phaseLabel(context)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(context)
                        .font(.title3.monospacedDigit().weight(.light))
                        .foregroundStyle(tint(context))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(timerInterval: context.state.phaseStartedAt...context.state.endDate,
                                 countsDown: true)
                        .tint(tint(context))
                }
            } compactLeading: {
                Image(systemName: symbolName(context))
                    .foregroundStyle(tint(context))
            } compactTrailing: {
                countdown(context)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44)
                    .foregroundStyle(tint(context))
            } minimal: {
                Image(systemName: symbolName(context))
                    .foregroundStyle(tint(context))
            }
            .keylineTint(tint(context))
        }
    }

    private func countdown(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> some View {
        Text(timerInterval: context.state.phaseStartedAt...context.state.endDate, countsDown: true)
    }

    private func phaseLabel(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> some View {
        Label(context.state.isFocus ? "Focus" : "Break", systemImage: symbolName(context))
            .foregroundStyle(tint(context))
    }

    private func symbolName(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> String {
        context.state.isFocus ? "brain.head.profile" : "cup.and.saucer.fill"
    }

    /// The user's accent while focusing, green on a break — matches the in-app ring (prompt 238 / 243).
    fileprivate static func tint(focus: Bool) -> Color { focus ? WidgetPalette.accentOnDark : WidgetPalette.fresh }

    private func tint(_ context: ActivityViewContext<PomodoroActivityAttributes>) -> Color {
        Self.tint(focus: context.state.isFocus)
    }
}

/// Lock Screen banner: phase label + big countdown over a wall-clock progress bar.
private struct PomodoroLockScreenView: View {
    let context: ActivityViewContext<PomodoroActivityAttributes>

    private var tint: Color { PomodoroLiveActivity.tint(focus: context.state.isFocus) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.state.isFocus ? "Focus" : "Break",
                      systemImage: context.state.isFocus ? "brain.head.profile" : "cup.and.saucer.fill")
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer()
                Text(timerInterval: context.state.phaseStartedAt...context.state.endDate,
                     countsDown: true)
                    .font(.title2.monospacedDigit().weight(.light))
                    .frame(maxWidth: 80, alignment: .trailing)
            }
            ProgressView(timerInterval: context.state.phaseStartedAt...context.state.endDate,
                         countsDown: true)
                .tint(tint)
                .labelsHidden()
        }
    }
}
