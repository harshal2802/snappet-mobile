import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The "Heart-rate source" picker (A3): lets the user choose where live HR comes from —
/// the **Apple Watch** (A1) or a **Bluetooth heart-rate band** (chest straps / Polar /
/// Garmin / any device exposing the standard Heart Rate Service, `0x180D`). Reachable as a
/// sheet from `WorkoutSettingsView`. Presented as a sheet so it may carry its own
/// `NavigationStack` (the module itself must not nest one).
///
/// User-friendly band connection (issue: "doesn't auto-detect a connected band; I had to do
/// it manually"):
///   • bands **already connected to iOS** (paired in Settings) are listed instantly via
///     `retrieveConnectedPeripherals` — they don't advertise, so a plain scan missed them;
///   • the band you used last is **remembered** and reconnects automatically (shown as
///     "Saved"), so most of the time there's nothing to tap at all;
///   • when Bluetooth is off / unauthorized the picker says so and offers a Settings jump,
///     instead of spinning forever.
struct HeartRateSourcePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var coordinator: LiveMetricsCoordinator { app.liveWorkout }
    private var ble: BLEHeartRateMetricsSource { coordinator.ble }

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

                bandsSection
                detailPreferenceSection
            }
            .navigationTitle("Heart-rate source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { ble.startScan() }
            .onDisappear { ble.stopScan() }
        }
    }

    // MARK: - Detail preference

    /// Opt-in to prefer a connected band for the most detailed clip HR (prompt 103). Off by default;
    /// only changes the automatic default (an explicit source tap still wins) and only when a band is known.
    @ViewBuilder
    private var detailPreferenceSection: some View {
        Section {
            Toggle(isOn: Binding(get: { coordinator.preferBandForDetail },
                                 set: { coordinator.preferBandForDetail = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prefer band for detailed clips").font(.headline)
                    Text("Use a connected heart-rate band when available").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("hrSourcePreferBand")
        } footer: {
            Text("A heart-rate band records about once a second — the most detailed heart rate for your clips. An Apple Watch records a bit less often, so Snappet also backfills watch sessions from Health when it can.")
        }
    }

    // MARK: - Bands section

    @ViewBuilder
    private var bandsSection: some View {
        Section {
            switch ble.availability {
            case .unauthorized:
                unavailableRow(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    title: "Bluetooth access is off",
                    message: "Allow Bluetooth for Snappet in Settings to connect a heart-rate band.",
                    actionTitle: "Open Settings")
            case .poweredOff:
                unavailableRow(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    title: "Bluetooth is turned off",
                    message: "Turn Bluetooth on in Control Center or Settings, then your band appears here automatically.",
                    actionTitle: "Open Settings")
            default:
                let devices = ble.displayDevices
                if devices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching for bands…").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("hrSourceScanning")
                } else {
                    ForEach(devices) { bleRow($0) }
                }
            }
        } header: {
            Text("Bluetooth heart-rate bands")
        } footer: {
            Text("Bands you've used before reconnect automatically. Tip: pair your band in Settings › Bluetooth and Snappet detects it here without scanning.")
        }
    }

    // MARK: - Rows

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
        let isActive = coordinator.activeKind == .ble && coordinator.ble.activeDeviceID == device.id
        return Button {
            coordinator.selectedSource = .ble
            coordinator.ble.connect(device)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill").foregroundStyle(SnappetColor.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text(subtitle(for: device)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("hrSourceBLEDevice")
        .swipeActions(edge: .trailing) {
            if ble.rememberedID == device.id {
                Button(role: .destructive) { ble.forget(device) } label: {
                    Label("Forget", systemImage: "trash")
                }
            }
        }
    }

    private func unavailableRow(icon: String, title: String, message: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
            #if canImport(UIKit)
            Button(actionTitle) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.callout.weight(.semibold))
            .padding(.top, 2)
            #endif
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("hrSourceBluetoothUnavailable")
    }

    // MARK: - Copy

    private var watchSubtitle: String {
        coordinator.watch.watchUsable ? "Paired and ready" : "No paired watch with Snappet installed"
    }

    /// The status line under a band row, combining its live connection state with whether it's
    /// the remembered ("Saved") band and/or one iOS already has connected.
    private func subtitle(for device: BLEDevice) -> String {
        let isTarget = coordinator.ble.activeDeviceID == device.id
        if isTarget {
            switch coordinator.ble.state {
            case .connecting: return "Connecting…"
            case .connected: return tag(device) ?? "Connected"
            case .streaming: return "Streaming heart rate"
            default: break
            }
        }
        return tag(device) ?? "Tap to connect"
    }

    /// A standing label for a band independent of the live connection attempt.
    private func tag(_ device: BLEDevice) -> String? {
        if ble.rememberedID == device.id { return "Saved · reconnects automatically" }
        if device.isSystemConnected { return "Connected via Bluetooth" }
        return nil
    }
}
