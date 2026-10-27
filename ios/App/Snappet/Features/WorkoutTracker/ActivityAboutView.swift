import SwiftUI

/// The Activity page's **About** tab for anything that isn't a catalog move (Library redesign L2, prompt 184): the
/// facts of your latest instance — a climb's type, grade, gym, wall, colour, setter and set date; a hold's protocol;
/// a run's distance; a festival's sets — plus when you first and last did it. (A catalog lift's About is its how-to,
/// `ExerciseDetailView`.)
struct ActivityAboutView: View {
    let key: ActivityKey
    let title: String
    let history: [WorkoutSession]
    let unit: WeightUnit
    /// A created activity you haven't logged yet (prompt 186): its details come from the template.
    var template: LibraryTemplate? = nil

    private var identity: ActivityIdentity { ActivityIdentity(sessions: history) }

    /// Every instance, oldest → newest.
    private var instances: [(exercise: SessionExercise, session: WorkoutSession)] {
        let ids = identity
        var out: [(exercise: SessionExercise, session: WorkoutSession)] = []
        for s in history.sorted(by: { $0.startedAt < $1.startedAt }) where !s.isActive {
            for ex in s.exercises where ids.matches(key, ex) && ex.sets.contains(where: { $0.completedAt != nil }) {
                out.append((exercise: ex, session: s))
            }
        }
        return out
    }

    var body: some View {
        let all = instances
        List {
            if let latest = all.last?.exercise ?? template?.exercise {
                Section("Details") {
                    details(latest, all: all)
                    if all.isEmpty, let m = template?.targetDistanceMeters, m > 0 {
                        LabeledContent("Distance", value: SetMeasure.formatDistance(m, unit: unit == .lb ? .mi : .km))
                    }
                }
            }
            if key.exerciseId == ActivityIdentity.festivalExerciseId, !all.isEmpty {
                Section("Sets you were at · \(all.count)") {
                    ForEach(Array(all.reversed().enumerated()), id: \.offset) { _, i in
                        HStack {
                            Text(i.exercise.displayName ?? "Set").lineLimit(1)
                            Spacer()
                            Text(SetMeasure.formatDuration(i.exercise.sets.compactMap(\.durationSec).reduce(0, +)))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let first = all.first?.session.startedAt, let last = all.last?.session.startedAt {
                Section("History") {
                    LabeledContent("First done") { Text(first, format: .dateTime.day().month(.abbreviated).year()) }
                    LabeledContent("Last done") { Text(last, format: .dateTime.day().month(.abbreviated).year()) }
                    LabeledContent("Sessions", value: "\(Set(all.map(\.session.id)).count)")
                }
            }
            if all.isEmpty {
                Text(template == nil ? "Log \(title) in a session and its details show up here."
                                     : "Not done yet — Log it now when you start it.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("activity.about")
    }

    @ViewBuilder
    private func details(_ ex: SessionExercise, all: [(exercise: SessionExercise, session: WorkoutSession)]) -> some View {
        LabeledContent("Type", value: ex.discipline == .climb ? ex.climbType.label : ex.discipline.label)
        switch ex.discipline {
        case .climb:
            if let g = ex.climbGradeLabel, !g.isEmpty { LabeledContent("Grade", value: g) }
            // A board climb (prompt 189) carries the board as its "gym" and the angle as its "wall".
            let board = LibraryCatalog.isKilter(key)
            if let gym = ex.gym, !gym.isEmpty { LabeledContent(board ? "Board" : "Gym", value: gym) }
            if let wall = ex.wall, !wall.isEmpty { LabeledContent(board ? "Last angle" : "Wall", value: wall) }
            if let c = ex.climbColor { LabeledContent("Colour", value: c.label) }
            if let setter = ex.setter, !setter.isEmpty { LabeledContent("Setter", value: setter) }
            if let start = identity.setStart[key] {
                LabeledContent("Set") { Text(start, format: .dateTime.day().month(.abbreviated).year()) }
            }
        case .timed:
            if let cat = ex.timedCategory.flatMap(TimedExerciseCategory.init(rawValue:)) {
                LabeledContent("Category", value: cat.display)
            }
            if let spec = ex.timedSpec { LabeledContent("Protocol", value: spec.summary) }
        case .run:
            let meters = all.map { RunStats.totalDistanceMeters($0.exercise) }
            if let longest = meters.max(), longest > 0 {
                LabeledContent("Longest", value: SetMeasure.formatDistance(longest, unit: unit == .lb ? .mi : .km))
            }
            let total = meters.reduce(0, +)
            if total > 0 {
                LabeledContent("Total", value: SetMeasure.formatDistance(total, unit: unit == .lb ? .mi : .km))
            }
        case .racket:
            let r = RacketStats.record(all.map(\.exercise))
            if r.played > 0 { LabeledContent("Record", value: r.label) }
            if let sport = all.first?.exercise.racketSport { LabeledContent("Sport", value: sport.label) }
            let time = all.flatMap(\.exercise.sets).compactMap(\.durationSec).reduce(0, +)
            if time > 0 { LabeledContent("Time played", value: SetMeasure.formatDuration(time)) }
        case .dance, .other:
            let time = all.flatMap(\.exercise.sets).compactMap(\.durationSec).reduce(0, +)
            if time > 0 { LabeledContent("Total time", value: SetMeasure.formatDuration(time)) }
        case .strength:
            EmptyView()
        }
    }
}
