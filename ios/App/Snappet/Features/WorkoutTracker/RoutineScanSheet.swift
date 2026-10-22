import SwiftUI

/// "Scan routine" (prompt 138, wireframe frame 10): the camera scanner plus **Choose from Photos**, so a
/// code someone sent you as a screenshot imports too. Reached from the Routines ＋ menu and the empty
/// state. Hands the decoded routine to the host, which shows the one import-confirm preview. Another kind of
/// Snappet code (a climb, a lineup) opens where it belongs (prompt 201).
struct RoutineScanSheet: View {
    let onFound: (SharedRoutine) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                SnappetScannerView(
                    prompt: "Point at a Snappet routine QR code.",
                    foreignHint: "That isn't a Snappet code.",
                    decode: { SharedRoutine(decoding: $0) },
                    onScan: found)
                    .accessibilityIdentifier("routine.scanSheet.camera")
                PhotoCodePickerRow(idPrefix: "routine.scanSheet", tint: SnappetColor.workout,
                                   decode: { SharedRoutine(decoding: $0) }, onFound: found)
            }
            .padding(.vertical, 12)
            .navigationTitle("Scan routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func found(_ routine: SharedRoutine) {
        Haptics.success()
        onFound(routine)
        dismiss()
    }
}
