import SwiftUI
import Charts

/// Per-exercise progress: PR, total volume, session count, a best-set-over-time chart, and a
/// reverse-chronological log of each session's top set. Pushed from the dashboard / detail.
struct ExerciseProgressView: View {
    let exerciseId: String
    let resolver: ExerciseResolver
    let history: [WorkoutSession]
    let unit: WeightUnit

    private var name: String { resolver.name(for: exerciseId) }
    private var top: WorkoutMath.TopSet? { WorkoutMath.topSet(history: history, exerciseId: exerciseId) }
    private var totalKg: Double { WorkoutMath.totalVolumeKg(history: history, exerciseId: exerciseId) }
    private var sessionCount: Int { WorkoutMath.sessionCount(history: history, exerciseId: exerciseId) }

    /// Per-session best set (by weight×reps), oldest → newest.
    private var points: [SessionBest] {
        history.sorted { $0.startedAt < $1.startedAt }.compactMap { session -> SessionBest? in
            guard let ex = session.exercises.first(where: { $0.exerciseId == exerciseId }) else { return nil }
            var bestScore = 0.0
            var best: SetLog?
            for set in ex.sets where set.completedAt != nil {
                let reps = set.actualReps ?? 0
                guard reps > 0 else { continue }
                let kg = set.actualWeight.map { WorkoutMath.toKg($0, set.weightUnit) } ?? 1
                if kg * Double(reps) > bestScore { bestScore = kg * Double(reps); best = set }
            }
            guard let best else { return nil }
            return SessionBest(date: session.startedAt,
                               weightKg: best.actualWeight.map { WorkoutMath.toKg($0, best.weightUnit) } ?? 0,
                               reps: best.actualReps ?? 0)
        }
    }

    var body: some View {
        List {
            Section {
                if let top {
                    LabeledContent("Personal record", value: prText(top))
                    LabeledContent("Set on") { Text(top.date, format: .dateTime.month().day().year()) }
                }
                LabeledContent("Sessions", value: "\(sessionCount)")
                if totalKg > 0 {
                    LabeledContent("Total volume", value: WorkoutMath.formatVolume(kg: totalKg, unit: unit))
                }
            }

            if points.contains(where: { $0.weightKg > 0 }) {
                Section("Best set over time") {
                    Chart(points) { p in
                        LineMark(x: .value("Date", p.date),
                                 y: .value("Weight", WorkoutMath.kgToUnit(p.weightKg, unit)))
                            .foregroundStyle(.orange)
                        PointMark(x: .value("Date", p.date),
                                  y: .value("Weight", WorkoutMath.kgToUnit(p.weightKg, unit)))
                            .foregroundStyle(.orange)
                    }
                    .frame(height: 180)
                }
            }

            Section("Log") {
                ForEach(points.reversed()) { p in
                    HStack {
                        Text(p.date, format: .dateTime.month().day().year()).font(.subheadline)
                        Spacer()
                        Text(p.weightKg > 0
                             ? "\(WorkoutMath.formatWeight(kg: p.weightKg, unit: unit)) \(unit.display) × \(p.reps)"
                             : "\(p.reps) reps")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if sessionCount == 0 {
                ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line",
                    description: Text("Log this exercise in a workout to track progress."))
            }
        }
    }

    private func prText(_ top: WorkoutMath.TopSet) -> String {
        top.bestKg > 0
            ? "\(WorkoutMath.formatWeight(kg: top.bestKg, unit: unit)) \(unit.display) × \(top.bestReps)"
            : "\(top.bestReps) reps"
    }

    struct SessionBest: Identifiable {
        var id: Date { date }
        let date: Date
        let weightKg: Double
        let reps: Int
    }
}
