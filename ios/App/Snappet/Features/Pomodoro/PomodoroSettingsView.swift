import SwiftUI

/// Sheet for adjusting focus and break lengths. Changes are bound directly to the
/// timer's config; `onChange` lets the root reset an idle timer so new lengths apply.
struct PomodoroSettingsView: View {
    @Binding var focusMinutes: Int
    @Binding var breakMinutes: Int
    var onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let focusRange = 5...90
    private let breakRange = 1...30

    var body: some View {
        NavigationStack {
            Form {
                Section("Focus") {
                    Stepper(value: $focusMinutes, in: focusRange, step: 5) {
                        HStack {
                            Text("Length")
                            Spacer()
                            // Identified value text so UI tests can read the persisted length directly
                            // (a stepper's inner label isn't reliably queryable on-device).
                            Text("\(focusMinutes) min")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("pomodoro.focusValue")
                        }
                    }
                    .onChange(of: focusMinutes) { onChange() }
                    .accessibilityIdentifier("pomodoro.focusStepper")
                }
                Section("Break") {
                    Stepper(value: $breakMinutes, in: breakRange, step: 1) {
                        HStack {
                            Text("Length")
                            Spacer()
                            Text("\(breakMinutes) min")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("pomodoro.breakValue")
                        }
                    }
                    .onChange(of: breakMinutes) { onChange() }
                    .accessibilityIdentifier("pomodoro.breakStepper")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
