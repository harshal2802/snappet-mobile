import SwiftUI

/// Detail for a completed session: summary stats plus every exercise and the sets logged.
struct SessionDetailView: View {
    let session: WorkoutSession
    let resolver: ExerciseResolver
    let unit: WeightUnit

    var body: some View {
        List {
            Section {
                LabeledContent("Date") {
                    Text(session.startedAt, format: .dateTime.weekday().month().day().hour().minute())
                }
                LabeledContent("Duration", value: "\(max(1, Int(session.duration / 60))) min")
                LabeledContent("Sets completed", value: "\(session.completedSetCount)")
                let vol = WorkoutMath.sessionVolumeKg(session)
                if vol > 0 {
                    LabeledContent("Total volume", value: WorkoutMath.formatVolume(kg: vol, unit: unit))
                }
            }

            ForEach(session.exercises) { ex in
                Section {
                    if ex.skipped {
                        Text("Skipped").foregroundStyle(.secondary).italic()
                    } else {
                        ForEach(Array(ex.sets.enumerated()), id: \.offset) { idx, set in
                            SetLogRow(index: idx + 1, set: set, unit: unit)
                        }
                    }
                } header: {
                    Text(resolver.name(for: ex.exerciseId, override: ex.displayName))
                }
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SetLogRow: View {
    let index: Int
    let set: SetLog
    let unit: WeightUnit

    var body: some View {
        HStack {
            Text("Set \(index)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if set.completedAt != nil {
                Text(detailText).font(.subheadline.monospacedDigit())
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private var detailText: String {
        let reps = set.actualReps.map { "\($0) reps" } ?? "done"
        if let w = set.actualWeight, w > 0 {
            let kg = WorkoutMath.toKg(w, set.weightUnit)
            return "\(WorkoutMath.formatWeight(kg: kg, unit: unit)) \(unit.display) × \(set.actualReps ?? 0)"
        }
        return reps
    }
}
