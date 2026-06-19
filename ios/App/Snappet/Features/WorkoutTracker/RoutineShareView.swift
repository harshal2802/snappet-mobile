import SwiftUI
import UIKit

/// Share a routine with a friend who has Snappet — a segmented **My Code / Scan** sheet
/// (workout-redesign E6). "My Code" renders the routine as a pure-black-on-white QR encoding a compact
/// `snappet://routine/v1/<blob>` `SharedRoutine` (+ a `ShareLink` for the link/file path); "Scan" opens
/// the generalized camera scanner to import a routine someone else is showing. Fully offline — both
/// phones ship the same exercise catalog, so the `exerciseId` references resolve locally.
///
/// **Honest size handling:** a routine whose encoded URL exceeds a comfortably-scannable QR
/// (`SharedRoutine.fitsInScannableQR`) hides the QR and leans on the always-present `ShareLink` instead
/// (link/file), so a 12-exercise routine that's too dense to scan is still shareable (README §10 Q4).
struct RoutineShareView: View {
    let routine: Routine
    /// Called with a routine scanned in the "Scan" tab — the host routes it to the import-confirm preview.
    let onScan: (SharedRoutine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .myCode

    private enum Mode: String, CaseIterable, Identifiable {
        case myCode, scan
        var id: String { rawValue }
        var label: String { self == .myCode ? "My Code" : "Scan" }
    }

    private var shared: SharedRoutine {
        SharedRoutine(name: routine.name, detail: routine.detail, exercises: routine.exercises)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityIdentifier("routine.share.modePicker")

                switch mode {
                case .myCode: myCode
                case .scan:
                    SnappetScannerView(
                        prompt: "Point at a Snappet routine QR code.",
                        foreignHint: "That isn't a Snappet routine code.",
                        decode: { SharedRoutine(decoding: $0) },
                        onScan: { decoded in onScan(decoded); dismiss() })
                        .accessibilityIdentifier("routine.scanner")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .navigationTitle("Share routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .presentationDetents([.large])
        }
    }

    @ViewBuilder private var myCode: some View {
        let shared = shared
        VStack(spacing: 14) {
            Text(routine.name).font(.headline).multilineTextAlignment(.center)

            if shared.fitsInScannableQR, let image = QRCodeImage.make(for: shared.encoded) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("QR code for \(routine.name)")
                    .accessibilityIdentifier("routine.share.qr")
                Text("Open Snappet on another phone, tap Share on a routine → Scan, and point it here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            } else {
                // Too big to scan reliably (the QR size cliff) — the link/file is the path.
                ContentUnavailableView {
                    Label("Too big for a code", systemImage: "qrcode")
                } description: {
                    Text("This routine is large — share the link instead, and your friend opens it in Snappet.")
                }
            }

            if let url = shared.url {
                ShareLink(item: url, subject: Text(routine.name),
                          message: Text("A workout routine from Snappet")) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(SnappetColor.workout)
                .accessibilityIdentifier("routine.share.link")
            }
        }
        .padding(.horizontal)
    }
}
