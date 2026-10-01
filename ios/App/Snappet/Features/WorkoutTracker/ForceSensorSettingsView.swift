import SwiftUI

/// Workout → Settings → Force sensor (prompt 145, wireframe frame 11): pair a Tindeq Progressor once,
/// zero it, choose how it drives reps, and keep your max (measured with the Max pull test or typed in).
struct ForceSensorSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("force.autoReps") private var autoReps = true
    @AppStorage("force.loadedKg") private var loadedKg = 5.0
    @AppStorage("force.warnBelow") private var warnBelow = true

    private var sensor: any ForceSensorSource { app.forceSensor }

    var body: some View {
        @Bindable var maxes = app.forceMax
        Form {
            Section {
                if sensor.state.isConnected {
                    LabeledContent {
                        Text("Connected").foregroundStyle(.green)
                    } label: {
                        Label(sensor.connectedName ?? "Tindeq Progressor", systemImage: "bolt.fill")
                    }
                    .accessibilityIdentifier("forceSensor.connected")
                    if let battery = sensor.batteryPercent {
                        LabeledContent("Battery", value: "\(battery)%\(sensor.isLowPower ? " · low" : "")")
                    }
                    LabeledContent("Reading now",
                                   value: "\(SetMeasure.formatWeight(((sensor.latestKg ?? 0) * 10).rounded() / 10)) kg")
                        .accessibilityIdentifier("forceSensor.reading")
                    Button("Zero (tare) — with nothing on it") { sensor.tare(); Haptics.tap() }
                        .accessibilityIdentifier("forceSensor.tare")
                } else {
                    availabilityRow
                    ForEach(sensor.discovered) { device in
                        Button {
                            sensor.connect(device)
                        } label: {
                            LabeledContent(device.name, value: sensor.state == .connecting ? "Connecting…" : "Connect")
                        }
                    }
                    if sensor.discovered.isEmpty, sensor.availability == .ready {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Looking for a Tindeq Progressor… turn it on (press its button).")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Sensor")
            } footer: {
                Text("It connects when a hang protocol starts. It only talks to your phone; force data stays on this device. Close the Tindeq app first — a sensor connects to one app at a time.")
            }

            Section("When connected") {
                Toggle("Start & stop reps automatically", isOn: $autoReps)
                    .accessibilityIdentifier("forceSensor.autoReps")
                Stepper(value: $loadedKg, in: 1...30, step: 1) {
                    LabeledContent("Counts as loaded above", value: "\(Int(loadedKg)) kg")
                }
                Toggle("Warn when below target", isOn: $warnBelow)
            }

            Section {
                maxRow("Two hands", value: $maxes.both, id: "forceSensor.maxBoth")
                maxRow("Left hand", value: $maxes.left, id: "forceSensor.maxLeft")
                maxRow("Right hand", value: $maxes.right, id: "forceSensor.maxRight")
            } header: {
                Text("Your max")
            } footer: {
                Text("Protocols set to “% of max” aim for these. Run the Max pull test with the sensor to measure them, or type them in.")
            }

            if sensor.hasRememberedSensor {
                Section {
                    Button("Forget this sensor", role: .destructive) { sensor.forget() }
                        .accessibilityIdentifier("forceSensor.forget")
                }
            }
        }
        .navigationTitle("Force sensor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if sensor.state.isConnected { sensor.startMeasuring() }
            else {
                sensor.startScan()
                if sensor.hasRememberedSensor { sensor.connectRemembered() }
            }
        }
        .onChange(of: sensor.state) { _, s in if s == .connected { sensor.startMeasuring() } }
        .onDisappear {
            sensor.stopMeasuring()
            sensor.stopScan()
        }
    }

    @ViewBuilder private var availabilityRow: some View {
        switch sensor.availability {
        case .unauthorized:
            Button("Allow Bluetooth in Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        case .poweredOff:
            Label("Bluetooth is off", systemImage: "antenna.radiowaves.left.and.right.slash")
        case .unknown, .ready:
            EmptyView()
        }
    }

    private func maxRow(_ label: String, value: Binding<Double?>, id: String) -> some View {
        let binding = Binding<Double>(get: { value.wrappedValue ?? 0 }, set: { value.wrappedValue = $0 > 0 ? $0 : nil })
        return HStack {
            Text(label)
            Spacer()
            TypeableWeightValue(weight: binding, unit: .kg, font: .body.weight(.semibold).monospacedDigit(),
                                id: id, zeroLabel: "Not set")
        }
    }
}
