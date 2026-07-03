import SwiftUI
import SwiftData

/// Full detail for one exercise: metadata, targeted muscles, step-by-step instructions, and
/// a link to the user's progress on it. Custom exercises gain Edit/Delete actions.
struct ExerciseDetailView: View {
    let exercise: Exercise
    let history: [WorkoutSession]
    let unit: WeightUnit

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SuiteRouter.self) private var router
    @State private var editing = false
    @State private var confirmingDelete = false

    private var top: WorkoutMath.TopSet? { WorkoutMath.topSet(history: history, exerciseId: exercise.id) }
    private var sessionCount: Int { WorkoutMath.sessionCount(history: history, exerciseId: exercise.id) }

    var body: some View {
        List {
            guidePhotoSection

            Section {
                LabeledContent("Category", value: exercise.category.display)
                LabeledContent("Level", value: exercise.level.display)
                if let equipment = exercise.equipment {
                    LabeledContent("Equipment", value: equipment.display)
                }
                if let force = exercise.force { LabeledContent("Force", value: force.display) }
                if let mechanic = exercise.mechanic { LabeledContent("Mechanic", value: mechanic.display) }
            }

            if !exercise.primaryMuscles.isEmpty || !exercise.secondaryMuscles.isEmpty {
                Section("Muscles") {
                    if !exercise.primaryMuscles.isEmpty {
                        muscleRow("Primary", exercise.primaryMuscles, SnappetColor.workout)
                    }
                    if !exercise.secondaryMuscles.isEmpty {
                        muscleRow("Secondary", exercise.secondaryMuscles, .secondary)
                    }
                }
            }

            if sessionCount > 0 {
                Section("Your progress") {
                    if let top {
                        LabeledContent("Best set", value: bestSetText(top))
                    }
                    LabeledContent("Sessions", value: "\(sessionCount)")
                    Button { router.push(ProgressRoute(exerciseId: exercise.id)) } label: {
                        Label("View progress", systemImage: "chart.xyaxis.line")
                    }
                }
            }

            if !exercise.instructions.isEmpty {
                Section("Instructions") {
                    ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(SnappetColor.workout)
                                .frame(width: 20, alignment: .trailing)
                            Text(step).font(.callout)
                        }
                    }
                }
            }

            if exercise.isCustom {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete Exercise", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if exercise.isCustom {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }
                }
            }
        }
        .sheet(isPresented: $editing) {
            ExerciseEditorView(existing: customModel())
        }
        .alert("Delete this exercise?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteCustom() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Routines that reference it will keep the name but lose the link.")
        }
    }

    /// Guide photos (downloaded pack): pager when installed + this exercise has photos, a
    /// download CTA when the pack is missing (never for custom exercises — they have no
    /// upstream photos). Both surfaces share `ExercisePhotoInstaller.shared` with Settings.
    @ViewBuilder private var guidePhotoSection: some View {
        let installer = ExercisePhotoInstaller.shared
        if installer.isInstalled {
            let count = ExercisePhotoStore.shared.photoCount(exerciseId: exercise.id)
            if count > 0 {
                Section {
                    GuidePhotoPager(exerciseId: exercise.id, count: count)
                        .listRowInsets(EdgeInsets())
                }
            }
        } else if !exercise.isCustom {
            Section {
                downloadCTA(installer)
            } footer: {
                Text("Photos stay on this device and work offline. Manage them in Workout Settings.")
            }
        }
    }

    @ViewBuilder private func downloadCTA(_ installer: ExercisePhotoInstaller) -> some View {
        switch installer.phase {
        case .working(let fraction):
            GuidePhotoInstallProgress(fraction: fraction)
        default:
            Button {
                Task { await installer.install() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "photo.badge.arrow.down")
                        .font(.title3).foregroundStyle(SnappetColor.workout)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download guide photos").foregroundStyle(SnappetColor.workout)
                        Text("Start/end photos for the whole catalog · one-time")
                            .font(.caption).foregroundStyle(.secondary)
                        GuidePhotoInstallError(phase: installer.phase)
                    }
                }
            }
            .accessibilityIdentifier("downloadGuidePhotos")
        }
    }

    private func muscleRow(_ title: String, _ muscles: [Muscle], _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(muscles.map(\.display).joined(separator: ", "))
                .font(.callout).foregroundStyle(tint == .secondary ? .secondary : .primary)
        }
    }

    private func bestSetText(_ top: WorkoutMath.TopSet) -> String {
        if top.bestKg > 0 {
            return "\(WorkoutMath.formatWeight(kg: top.bestKg, unit: unit)) \(unit.display) × \(top.bestReps)"
        }
        return "\(top.bestReps) reps"
    }

    private func customModel() -> CustomExercise? {
        let id = exercise.id
        let descriptor = FetchDescriptor<CustomExercise>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func deleteCustom() {
        if let model = customModel() {
            context.delete(model)
            try? context.save()
        }
        dismiss()
    }
}
