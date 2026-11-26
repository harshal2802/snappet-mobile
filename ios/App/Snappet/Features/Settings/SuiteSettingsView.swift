import SwiftUI

/// Settings (prompt 212) — what Home's avatar opens: the app-wide things that don't belong to one mini-app.
/// Appearance (accent + System/Dark/Light), your heart-rate profile and sources (the Gym Tracker's settings, where
/// they live today), and Cloud & Backup.
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
                        Label("Cloud & Backup", systemImage: "externaldrive")
                    }
                    .accessibilityIdentifier("settings.backup")
                }
                #if DEBUG
                // Debug builds only (prompt 304): renders the Studio's golden scenes on this device.
                Section {
                    NavigationLink {
                        StudioSelfCheckView()
                    } label: {
                        Label("Studio render check", systemImage: "checkmark.rectangle.stack")
                    }
                    .accessibilityIdentifier("settings.studioSelfCheck")
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Debug builds only.")
                }
                #endif
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
