import SwiftUI
import WidgetKit
import ActivityKit

/// The household power hour on the Lock Screen and in the Dynamic Island (household prompt 04, wireframe
/// frame 7). The countdown is `Text(timerInterval:)`, ticked by the OS; the count is whatever the app last
/// synced.
struct PowerHourLiveActivity: Widget {
    private static let sage = Color(red: 0.66, green: 0.78, blue: 0.31)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PowerHourActivityAttributes.self) { context in
            PowerHourLockScreenView(context: context)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Power hour", systemImage: "sparkles").foregroundStyle(Self.sage).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Self.sage)
                        .frame(maxWidth: 80)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.countLine(context.state)).font(.subheadline)
                        ProgressView(value: Double(min(context.state.done, max(1, context.state.target))),
                                     total: Double(max(1, context.state.target)))
                            .tint(Self.sage)
                    }
                }
            } compactLeading: {
                Image(systemName: "sparkles").foregroundStyle(Self.sage)
            } compactTrailing: {
                Text("\(context.state.done)").font(.caption2.monospacedDigit().weight(.bold)).foregroundStyle(Self.sage)
            } minimal: {
                Text("\(context.state.done)").font(.caption2.weight(.bold)).foregroundStyle(Self.sage)
            }
            .keylineTint(Self.sage)
        }
    }

    fileprivate static func countLine(_ s: PowerHourActivityAttributes.ContentState) -> String {
        let chores = s.target > 0 ? "\(s.done) of \(s.target) chores" : "\(s.done) chore\(s.done == 1 ? "" : "s")"
        return s.people > 1 ? "\(chores) · \(s.people) of you" : chores
    }
}

private struct PowerHourLockScreenView: View {
    let context: ActivityViewContext<PowerHourActivityAttributes>
    private let sage = Color(red: 0.66, green: 0.78, blue: 0.31)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Power hour · \(context.attributes.householdName)", systemImage: "sparkles")
                    .font(.subheadline.weight(.bold)).foregroundStyle(sage)
                Spacer()
                Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
            }
            Text(PowerHourLiveActivity.countLine(context.state)).font(.subheadline)
            ProgressView(value: Double(min(context.state.done, max(1, context.state.target))),
                         total: Double(max(1, context.state.target)))
                .tint(sage)
            Text("\(context.attributes.petName) is getting excited").font(.caption).foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
    }
}
