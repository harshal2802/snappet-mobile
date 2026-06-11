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
                RecoveryUnavailableView(spec: ReelFlowPolicy.workoutsErrorSpec(message: msg),
                                        identifierPrefix: "workout") { action in
                    if action == .tryAgain { Task { await model.bootstrap() } }
                }
            case .ready:
                list
            }
        }
        .refreshable { await model.refreshWorkouts() }
    }

    private var list: some View {
        List {
            ForEach(model.workouts) { wk in
                Button { router.push(wk) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ReelFlowPolicy.activityIcon(for: wk.activity))
                            .font(.title3)
                            .foregroundStyle(SnappetColor.workout)
                            .frame(width: 40, height: 40)
                            .background(SnappetColor.workout.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wk.activity.rawValue.capitalized).font(.headline)
                            Text(wk.start, format: .dateTime.month().day().hour().minute())
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(durationText(wk.duration)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workoutReelRow")
            }

            // Cross-link (#74): the suite's *other* fitness module. Reels cuts videos from
            // completed Apple Watch workouts — anyone hunting for set logging / routines / PRs
            // tapped the wrong card, so name the right one instead of letting them dead-end.
            // Hidden while the list is empty: the recovery overlay renders over the list there.
            if !model.workouts.isEmpty {
                crossLinkSection
            }
        }
        .navigationDestination(for: WorkoutSummary.self) { ReelView(summary: $0) }
        .overlay {
            if model.workouts.isEmpty {
                if model.refreshing {
                    // An in-flight fetch (cold load or the Refresh button) must not read as a
                    // permission problem — spinner until the result is actually known (review fix).
                    ProgressView()
                } else {
                    // Health read-denial is invisible (not queryable), so the copy acknowledges it
                    // and offers a working path out — an explicit Refresh (the overlay swallows
                    // pull-to-refresh) plus Open Settings as a best-effort shortcut; the real
                    // Health toggle lives under Privacy & Security, which the copy names
                    // (issue #72 §2 + review fix).
                    RecoveryUnavailableView(spec: ReelFlowPolicy.workoutsEmptySpec(),
                                            identifierPrefix: "workout") { action in
                        if action == .refresh { Task { await model.refreshWorkouts() } }
                    }
                }
            }
        }
    }

    /// The "wrong module?" row pointing at the Gym Tracker (#74) — the suite's two fitness cards
    /// used to be near-identically named, so each module now names the other explicitly.
    private var crossLinkSection: some View {
        Section {
            Button { router.open(module: WorkoutTrackerModule.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "dumbbell.fill")
                        .foregroundStyle(SnappetColor.moduleAccent(WorkoutTrackerModule.id))
                    Text("Looking for set logging & routines? Open Gym Tracker")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workout.openGymTracker")
        } footer: {
            Text("Reels are cut from your Apple Watch workouts. Gym sessions you log by hand live in Gym Tracker.")
        }
    }

    private func durationText(_ s: Double) -> String {
        let m = Int(s) / 60
        return "\(m) min"
    }
}
