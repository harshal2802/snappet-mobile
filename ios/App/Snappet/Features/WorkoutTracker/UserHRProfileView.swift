import SwiftUI

/// Editor for the on-device `UserHRProfile` (fitness-band Phase 2): age, biological sex, weight,
/// resting HR, and an optional measured max-HR override. Reachable from Settings; the profile is
/// app-global (shared by WorkoutTracker + Kilter), so there's one editor.
///
/// All fields are optional — leaving them blank keeps the app's bpm-only defaults (the gating
/// invariant). A "Use Health data" button prefills blank fields from HealthKit without clobbering
/// anything the user typed. The draft is held locally and written back to `AppModel.userProfile` on
/// every change, so an open session summary's personalized zones update live.
struct UserHRProfileView: View {
    @Environment(AppModel.self) private var app

    @State private var ageText = ""
    @State private var restingText = ""
    @State private var maxText = ""
    @State private var weightText = ""
    @State private var sex: BiologicalSex = .unspecified
    @State private var prefilling = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Age") {
                    TextField("years", text: $ageText)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("profileAge")
                }
                Picker("Sex", selection: $sex) {
                    ForEach(BiologicalSex.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Weight") {
                    TextField("kg", text: $weightText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("profileWeight")
                }
            } header: {
                Text("You")
            } footer: {
                Text("Used on-device to personalize heart-rate zones, % effort, and a calorie estimate. Your profile never leaves this device.")
            }

            Section {
                LabeledContent("Resting HR") {
                    TextField("bpm", text: $restingText)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("profileRestingHR")
                }
                LabeledContent("Max HR") {
                    TextField("bpm (optional)", text: $maxText)
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("profileMaxHR")
                }
            } header: {
                Text("Heart rate")
            } footer: {
                Text("Leave Max HR blank to estimate it from your age (208 − 0.7 × age). Enter it if you've measured your true max.")
            }

            Section {
                Button {
                    Task { await prefill() }
                } label: {
                    HStack {
                        Label("Use Health data", systemImage: "heart.text.square")
                        if prefilling { Spacer(); ProgressView() }
                    }
                }
                .disabled(prefilling)
                .accessibilityIdentifier("profilePrefill")
            } footer: {
                Text("Fills any blank fields above from Apple Health (age, sex, weight, resting heart rate). Won't overwrite values you've entered.")
            }
        }
        .navigationTitle("Heart-rate profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: ageText) { save() }
        .onChange(of: restingText) { save() }
        .onChange(of: maxText) { save() }
        .onChange(of: weightText) { save() }
        .onChange(of: sex) { save() }
    }

    private func load() {
        let p = app.userProfile.profile
        ageText = p.age.map(String.init) ?? ""
        restingText = p.restingHR.map(String.init) ?? ""
        maxText = p.maxHROverride.map(String.init) ?? ""
        weightText = p.weightKg.map { String(format: "%g", $0) } ?? ""
        sex = p.sex
    }

    private func save() {
        app.userProfile.update(UserHRProfile(
            age: Int(ageText.trimmingCharacters(in: .whitespaces)),
            restingHR: Int(restingText.trimmingCharacters(in: .whitespaces)),
            maxHROverride: Int(maxText.trimmingCharacters(in: .whitespaces)),
            weightKg: Double(weightText.trimmingCharacters(in: .whitespaces)),
            sex: sex))
    }

    private func prefill() async {
        prefilling = true
        defer { prefilling = false }
        // Make sure the read scopes are authorized (no-op if already granted), then merge into blanks.
        try? await app.health.requestAuthorization()
        let prefill = await app.health.profilePrefill()
        app.userProfile.update(app.userProfile.profile.merging(prefill: prefill))
        load()   // reflect the merged values back into the fields
    }
}
