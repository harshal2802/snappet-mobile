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

    var body: some View {
        Form {
            Section("Preferences") {
                Picker("Weight unit", selection: $unitRaw) {
                    ForEach(WeightUnit.allCases) { Text($0.display.uppercased()).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

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
                LabeledContent("Exercise catalog", value: "873 exercises")
            } footer: {
                Text("Exercise data from the Free Exercise DB (yuhonas/free-exercise-db), bundled for offline use. Everything stays on your device.")
            }
        }
        .sheet(isPresented: $showingHRSource) {
            HeartRateSourcePicker()
        }
    }
}
