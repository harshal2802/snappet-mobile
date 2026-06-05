import SwiftUI
import WidgetKit
import ActivityKit

/// Renders the **Kilter climbing-session** Live Activity: the **overall session timer**, the **live
/// heart rate**, and the **current climb / grade / climb count** on the Lock Screen and in the
/// Dynamic Island (compact / minimal / expanded). The app side (`KilterLiveActivityController`)
/// starts/updates/ends it; this extension only renders the shared `KilterActivityAttributes` — one
/// source of truth for the contract.
///
/// The overall timer is `Text(timerInterval:)` anchored on `state.startedAt`, so the system ticks it
/// on the wall clock with no background CPU and it stays correct across backgrounding.
struct KilterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KilterActivityAttributes.self) { context in
            KilterLockScreenView(context: context)
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
                    .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    heartLabel(context).font(.title3.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.currentClimbName)
                            .font(.headline).lineLimit(1)
                        HStack(spacing: 6) {
                            if !context.state.currentGrade.isEmpty {
                                Text(context.state.currentGrade)
                            }
                            Text("· \(context.state.climbCount) climbs · \(context.state.angle)°")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill" : "stopwatch")
                    .foregroundStyle(context.state.paused ? .yellow : .green)
            } compactTrailing: {
                timerText(context).font(.caption2.monospacedDigit()).frame(width: 44)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "figure.climbing")
                    .foregroundStyle(context.state.paused ? .yellow : .green)
            }
            .keylineTint(context.state.paused ? .yellow : .green)
        }
    }

    /// The overall timer, or a "Paused" label when the session is paused.
    @ViewBuilder private func timerText(_ context: ActivityViewContext<KilterActivityAttributes>) -> some View {
        if context.state.paused {
            Text("Paused")
        } else {
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
        }
    }

    /// Heart rate, tinted by its `HeartRateZone` (shared with the phone overlay + watch face).
    private func heartLabel(_ context: ActivityViewContext<KilterActivityAttributes>) -> some View {
        let zone = HeartRateZone.forBpm(context.state.hrBpm.map(Double.init))
        return Label {
            Text(context.state.hrBpm.map { "\($0)" } ?? "—")
        } icon: {
            Image(systemName: "heart.fill")
        }
        .foregroundStyle(zone == .none ? .pink : zone.color)
    }
}

/// The Lock Screen / banner presentation for a climbing session.
private struct KilterLockScreenView: View {
    let context: ActivityViewContext<KilterActivityAttributes>

    private var zone: HeartRateZone { HeartRateZone.forBpm(context.state.hrBpm.map(Double.init)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.boardName, systemImage: "figure.climbing")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                    .lineLimit(1)
                if context.state.paused {
                    Text("PAUSED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.25), in: Capsule())
                        .foregroundStyle(.yellow)
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
                    Text(context.state.currentClimbName).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        if !context.state.currentGrade.isEmpty {
                            Text(context.state.currentGrade)
                        }
                        Text("\(context.state.climbCount) climbs · \(context.state.angle)°")
                    }
                    .font(.caption).foregroundStyle(.secondary)
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
