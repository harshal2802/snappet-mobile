import SwiftUI

/// A QR scanner sheet for opening a climb shared from another phone. Reads a
/// `snappet://kilter/climb/<uuid>` link, validates it, and reports the decoded `KilterClimbLink`.
/// Camera-only, on-device, no network. Now a thin wrapper over the generalized `SnappetScannerView`
/// (workout-redesign E6 lifted the AVFoundation plumbing into `Core/SnappetScannerView.swift` so the
/// climb scanner and the routine scanner share one camera path) — passing the climb-link decoder.
struct KilterScannerView: View {
    /// Called once with a successfully decoded link (the sheet then dismisses itself).
    let onScan: (KilterClimbLink) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SnappetScannerView(
                prompt: "Point at a Kilter climb QR code.",
                foreignHint: "That isn't a Snappet climb code.",
                decode: { KilterClimbLink(decoding: $0) },
                onScan: { link in onScan(link); dismiss() })
                .accessibilityIdentifier("kilter.scanner")
                .navigationTitle("Scan climb")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
