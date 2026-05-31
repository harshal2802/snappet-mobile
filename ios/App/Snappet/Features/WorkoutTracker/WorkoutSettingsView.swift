import SwiftUI

/// The Settings section: preferred weight unit, a quick summary, and management of custom
/// exercises (browse → delete). Weight unit is the app-wide default for new routines/sessions.
struct WorkoutSettingsView: View {
    @Binding var unitRaw: String
    let customExercises: [CustomExercise]
    let history: [WorkoutSession]
    let deleteCustom: (CustomExercise) -> Void

    var body: some View {
        Form {
            Section("Preferences") {
                Picker("Weight unit", selection: $unitRaw) {
                    ForEach(WeightUnit.allCases) { Text($0.display.uppercased()).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

            Section("Your data") {
                LabeledContent("Completed workouts", value: "\(history.count)")
                LabeledContent("Custom exercises", value: "\(customExercises.count)")
            }

            if !customExercises.isEmpty {
                Section("Custom exercises") {
                    ForEach(customExercises.sorted { $0.name < $1.name }) { custom in
                        NavigationLink(value: custom.asExercise) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(custom.name).font(.headline)
                                Text(custom.asExercise.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
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
    }
}
