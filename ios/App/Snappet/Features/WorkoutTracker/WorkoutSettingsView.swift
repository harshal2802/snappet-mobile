import SwiftUI

/// The Settings section: preferred weight unit, a quick summary, and management of custom
/// exercises (browse → delete). Weight unit is the app-wide default for new routines/sessions.
struct WorkoutSettingsView: View {
    @Binding var unitRaw: String
    let customExercises: [CustomExercise]
    let history: [WorkoutSession]
    let open: (Exercise) -> Void
    let deleteCustom: (CustomExercise) -> Void

    @Environment(AppModel.self) private var app
    @State private var showingHRSource = false
    @AppStorage(WeightEntry.stepKey(for: .kg)) private var stepKg = 0.0
    @AppStorage(WeightEntry.stepKey(for: .lb)) private var stepLb = 0.0
    @AppStorage(KeepScreenAwakeMode.storageKey) private var keepAwakeRaw = KeepScreenAwakeMode.defaultMode.rawValue

    var body: some View {
        Form {
            Section("Preferences") {
                Picker("Weight unit", selection: $unitRaw) {
                    ForEach(WeightUnit.allCases) { Text($0.display.uppercased()).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                weightStepRow
            }

            Section {
                Picker("Keep screen on", selection: $keepAwakeRaw) {
                    ForEach(KeepScreenAwakeMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("settings.keepScreenAwake")
            } header: {
                Text("During a workout")
            } footer: {
                Text(KeepScreenAwakeMode.resolve(keepAwakeRaw).footer)
            }
            // The controller reads the stored mode at launch; push later changes to it live.
            .onChange(of: keepAwakeRaw) { _, raw in app.screenAwake.mode = KeepScreenAwakeMode.resolve(raw) }

            Section {
                Button {
                    showingHRSource = true
                } label: {
                    LabeledContent("Heart-rate source", value: app.liveWorkout.activeKind.title)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("openHeartRateSource")
            } header: {
                Text("Live metrics")
            } footer: {
                Text("Choose where live heart rate comes from during a workout — your Apple Watch or a Bluetooth heart-rate band.")
            }

            Section {
                NavigationLink {
                    UserHRProfileView()
                } label: {
                    LabeledContent("Heart-rate profile",
                                   value: app.userProfile.profile.resolvedMaxHR
                                       .map { "Max \(Int($0.rounded()))" } ?? "Not set")
                }
                .accessibilityIdentifier("openHRProfile")
            } header: {
                Text("Heart-rate profile")
            } footer: {
                Text("Personalizes heart-rate zones, % effort, and a calorie estimate across the app. Optional — without it, zones use a default ceiling.")
            }

            Section("Your data") {
                LabeledContent("Completed workouts", value: "\(history.count)")
                LabeledContent("Custom exercises", value: "\(customExercises.count)")
            }

            if !customExercises.isEmpty {
                Section("Custom exercises") {
                    ForEach(customExercises.sorted { $0.name < $1.name }) { custom in
                        Button { open(custom.asExercise) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(custom.name).font(.headline)
                                Text(custom.asExercise.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("customExerciseRow")
                    }
                    .onDelete { offsets in
                        let sorted = customExercises.sorted { $0.name < $1.name }
                        for i in offsets { deleteCustom(sorted[i]) }
                    }
                }
            }

            Section {
                guidePhotoRows
            } header: {
                Text("Guide photos")
            } footer: {
                Text("Start/end photos for the exercise catalog (Free Exercise DB, public domain). Downloaded once from the Snappet data host; nothing is uploaded, and they work offline.")
            }

            Section {
                LabeledContent("Exercise catalog", value: "873 exercises")
            } footer: {
                Text("Exercise data from the Free Exercise DB (yuhonas/free-exercise-db), bundled for offline use. Everything stays on your device.")
            }
        }
        .sheet(isPresented: $showingHRSource) {
            HeartRateSourcePicker()
        }
    }

    /// Download / status / remove for the guide-photo pack. Renders the same
    /// `ExercisePhotoInstaller.shared` phase as the exercise-detail CTA so the two can't drift.
    @ViewBuilder private var guidePhotoRows: some View {
        let installer = ExercisePhotoInstaller.shared
        switch installer.phase {
        case .working(let fraction):
            GuidePhotoInstallProgress(fraction: fraction)
        default:
            if let manifest = installer.installedManifest {
                LabeledContent("Installed",
                               value: "\(manifest.sizeLabel) · \(manifest.photoCount) photos")
                Button("Update photos") {
                    Task { await installer.install() }
                }
                .accessibilityIdentifier("updateGuidePhotos")
                // A failed UPDATE must be visible here too — the pack stays installed, but the
                // user needs to know the refresh didn't happen.
                GuidePhotoInstallError(phase: installer.phase)
                Button("Remove downloaded photos", role: .destructive) {
                    installer.remove()
                }
                .accessibilityIdentifier("removeGuidePhotos")
            } else {
                Button {
                    Task { await installer.install() }
                } label: {
                    Label("Download guide photos", systemImage: "photo.badge.arrow.down")
                }
                .accessibilityIdentifier("downloadGuidePhotosSettings")
                GuidePhotoInstallError(phase: installer.phase)
            }
        }
    }

    // MARK: - Weight ± step (prompt 139)

    private var unit: WeightUnit { WeightUnit(rawValue: unitRaw) ?? .kg }

    /// The step the − / + weight buttons use, per unit; you can always tap a weight to type it exactly.
    private var weightStepRow: some View {
        let binding = Binding<Double>(
            get: { WeightEntry.step(stored: unit == .lb ? stepLb : stepKg, unit: unit) },
            set: { if unit == .lb { stepLb = $0 } else { stepKg = $0 } })
        return VStack(alignment: .leading, spacing: 6) {
            Text("Weight ± step")
            Picker("Weight ± step", selection: binding) {
                ForEach(WeightEntry.stepChoices(for: unit), id: \.self) { Text(SetMeasure.formatWeight($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.weightStep")
            Text("How much − and + change a weight (\(unit.display)). Tap any weight to type an exact value.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
