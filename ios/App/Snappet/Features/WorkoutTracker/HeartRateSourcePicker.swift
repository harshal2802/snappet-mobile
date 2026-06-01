import SwiftUI

/// The "Heart-rate source" picker (A3): lets the user choose where live HR comes from —
/// the **Apple Watch** (A1) or a scanned **BLE heart-rate band** (chest straps / Polar /
/// Garmin / any device exposing the standard Heart Rate Service, `0x180D`). Reachable as a
/// sheet from `WorkoutSettingsView`. Presented as a sheet so it may carry its own
/// `NavigationStack` (the module itself must not nest one).
///
/// Picking a row sets the coordinator's `selectedSource`; tapping a discovered band also
/// connects it. Scanning starts when this screen appears (which triggers the one-time
/// Bluetooth permission prompt) and stops when it leaves.
struct HeartRateSourcePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private var coordinator: LiveMetricsCoordinator { app.liveWorkout }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sourceRow(kind: .appleWatch,
                              subtitle: watchSubtitle,
                              identifier: "hrSourceAppleWatch")
                } header: {
                    Text("Source")
                } footer: {
                    Text("Live heart rate during a workout can come from your Apple Watch or a Bluetooth heart-rate band (chest straps, Polar, Garmin, and similar). Everything stays on your device — no accounts, no cloud.")
                }

                Section {
                    if coordinator.discoveredBLE.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Scanning for bands…").foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("hrSourceScanning")
                    } else {
                        ForEach(coordinator.discoveredBLE) { device in
                            bleRow(device)
                        }
                    }
                } header: {
                    Text("Bluetooth heart-rate bands")
                }
            }
            .navigationTitle("Heart-rate source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { coordinator.ble.startScan() }
            .onDisappear { coordinator.ble.stopScan() }
        }
    }

    private var watchSubtitle: String {
        coordinator.watch.watchUsable ? "Paired and ready" : "No paired watch with Snappet installed"
    }

    private func sourceRow(kind: MetricsSourceKind, subtitle: String, identifier: String) -> some View {
        Button {
            coordinator.selectedSource = kind
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if coordinator.activeKind == kind {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func bleRow(_ device: BLEDevice) -> some View {
        Button {
            coordinator.selectedSource = .ble
            coordinator.ble.connect(device)
        } label: {
            HStack {
                Image(systemName: "heart.fill").foregroundStyle(SnappetColor.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    if coordinator.ble.connectedName == device.name {
                        Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if coordinator.activeKind == .ble, coordinator.ble.connectedName == device.name {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hrSourceBLEDevice")
    }

    private var stateLabel: String {
        switch coordinator.ble.state {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .streaming: return "Streaming heart rate"
        default: return "Selected"
        }
    }
}
