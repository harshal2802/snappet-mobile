import SwiftUI

/// A small sheet to log one running **leg** (Workout-Type Parity Phase 4): distance + duration with a live
/// derived-pace preview. Distance is entered in the user's unit (km/mi) and converted to metres on commit;
/// pace is derived (never stored). The "Log leg" commit funnels through the player's `appendLog`. Manual
/// entry is the v1 path — live watch/GPS distance is tracked in issue #177.
struct AddRunLegSheet: View {
    let unit: DistanceUnit
    let onLog: (_ distanceMeters: Double, _ durationSec: Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var distanceText = ""
    @State private var minutes = ""
    @State private var seconds = ""

    /// Parsed distance in metres (accepts a decimal comma), or `nil` when blank / non-positive.
    private var distanceMeters: Double? {
        let cleaned = distanceText.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v.isFinite, v > 0, v < 100_000 else { return nil }
        return unit == .km ? v * 1000 : v * 1609.344
    }

    private var durationSec: Double {
        let m = Double(minutes) ?? 0, s = Double(seconds) ?? 0
        return max(0, m) * 60 + max(0, s)
    }

    private var canLog: Bool { (distanceMeters ?? 0) > 0 && durationSec > 0 }

    private var pacePreview: String? {
        guard let d = distanceMeters, d > 0, durationSec > 0 else { return nil }
        return SetMeasure.formatPace(secPerKm: durationSec / (d / 1000), unit: unit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Distance") {
                    HStack {
                        TextField("0", text: $distanceText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("runLeg.distance")
                        Text(unit.display).foregroundStyle(.secondary)
                    }
                }
                Section("Time") {
                    HStack(spacing: 8) {
                        TextField("min", text: $minutes)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("runLeg.minutes")
                        Text(":").foregroundStyle(.secondary)
                        TextField("sec", text: $seconds)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("runLeg.seconds")
                    }
                }
                if let pace = pacePreview {
                    HStack {
                        Text("Pace")
                        Spacer()
                        Text(pace).foregroundStyle(SnappetColor.budget).fontWeight(.semibold)
                            .accessibilityIdentifier("runLeg.pace")
                    }
                }
            }
            .navigationTitle("Log a leg")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log leg") {
                        if let d = distanceMeters { onLog(d, durationSec); dismiss() }
                    }
                    .disabled(!canLog)
                    .accessibilityIdentifier("runLeg.log")
                }
            }
        }
    }
}
