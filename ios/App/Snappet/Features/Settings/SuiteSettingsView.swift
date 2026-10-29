import SwiftUI

/// Settings (prompt 212) — what Home's avatar opens: the app-wide things that don't belong to one mini-app.
/// Appearance (accent + System/Dark/Light), your heart-rate profile and sources (the Gym Tracker's settings, where
/// they live today), and Back up & restore.
struct SuiteSettingsView: View {
    @Environment(SuiteRouter.self) private var router
    @Environment(StoreHealth.self) private var storeHealth
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SnappetAccent.defaultsKey) private var accentRaw = SnappetAccent.default.rawValue
    @State private var showingBackup = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AppearanceSettingsView(standalone: false)
                    } label: {
                        LabeledContent {
                            Text(SnappetAccent.resolve(accentRaw).label)
                        } label: {
                            Label("Appearance", systemImage: "paintpalette")
                        }
                    }
                    .accessibilityIdentifier("settings.appearance")
                    Button {
                        dismiss()
                        router.open(module: WorkoutTrackerModule.id)
                        router.push(WorkoutSettingsRoute())
                    } label: {
                        Label("Heart rate & devices", systemImage: "heart.text.square")
                    }
                    .accessibilityIdentifier("settings.heartRate")
                } footer: {
                    Text("Heart rate & devices: your max / resting heart rate, Apple Watch, a Bluetooth band, Apple Health.")
                }
                Section {
                    Button { showingBackup = true } label: {
                        Label("Back up & restore", systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier("settings.backup")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
            .sheet(isPresented: $showingBackup) { BackupView(storeIsFallback: storeHealth.mode != .ok) }
        }
    }
}
