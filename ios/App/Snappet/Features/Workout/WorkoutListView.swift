import SwiftUI
import HighlightEngine

struct WorkoutListView: View {
    @Environment(AppModel.self) private var model
    @Environment(SuiteRouter.self) private var router

    var body: some View {
        Group {
            switch model.phase {
            case .onboarding, .loading:
                ProgressView("Loading…")
            case .error(let msg):
                ContentUnavailableView("Something went wrong", systemImage: "exclamationmark.triangle",
                    description: Text(msg))
            case .ready:
                list
            }
        }
        .refreshable { await model.refreshWorkouts() }
    }

    private var list: some View {
        List(model.workouts) { wk in
            Button { router.push(wk) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wk.activity.rawValue.capitalized).font(.headline)
                    Text(wk.start, format: .dateTime.month().day().hour().minute())
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(durationText(wk.duration)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workoutReelRow")
        }
        .navigationDestination(for: WorkoutSummary.self) { ReelView(summary: $0) }
        .overlay {
            if model.workouts.isEmpty {
                ContentUnavailableView("No workouts yet",
                    systemImage: "figure.run",
                    description: Text("Track a workout on your Apple Watch, then pull to refresh."))
            }
        }
    }

    private func durationText(_ s: Double) -> String {
        let m = Int(s) / 60
        return "\(m) min"
    }
}
