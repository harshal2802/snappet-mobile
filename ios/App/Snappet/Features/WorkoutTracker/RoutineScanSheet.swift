import SwiftUI
import PhotosUI

/// Why a picked photo didn't yield a routine — shown inline, never a blank result (prompt 138).
enum RoutinePhotoImportError: Error, Equatable {
    case noCode
    case notARoutine

    var message: String {
        switch self {
        case .noCode: "No QR code found in that photo. Try a sharper screenshot of the code."
        case .notARoutine: "That photo has a QR code, but it isn't a Snappet routine."
        }
    }
}

enum RoutinePhotoImport {
    /// The first payload that is a Snappet routine. Pure — the decode step is `QRImageDecoder`.
    static func routine(from payloads: [String]) -> Result<SharedRoutine, RoutinePhotoImportError> {
        guard !payloads.isEmpty else { return .failure(.noCode) }
        if let routine = payloads.lazy.compactMap(SharedRoutine.init(decoding:)).first { return .success(routine) }
        return .failure(.notARoutine)
    }

    static func routine(fromImageData data: Data) async -> Result<SharedRoutine, RoutinePhotoImportError> {
        routine(from: await QRImageDecoder.payloads(in: data))
    }
}

/// "Scan routine" (prompt 138, wireframe frame 10): the camera scanner plus **Choose from Photos**, so a
/// code someone sent you as a screenshot imports too. Reached from the Routines ＋ menu and the empty
/// state. Hands the decoded routine to the host, which shows the one import-confirm preview.
struct RoutineScanSheet: View {
    let onFound: (SharedRoutine) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pick: PhotosPickerItem?
    @State private var decoding = false
    @State private var photoError: RoutinePhotoImportError?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                SnappetScannerView(
                    prompt: "Point at a Snappet routine QR code.",
                    foreignHint: "That isn't a Snappet routine code.",
                    decode: { SharedRoutine(decoding: $0) },
                    onScan: found)
                    .accessibilityIdentifier("routine.scanSheet.camera")

                // Resolved outside: PhotosPicker's label closure is Sendable and can't read @State.
                let pickTitle = decoding ? "Reading photo…" : "Choose from Photos"
                PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                    Label(pickTitle, systemImage: "photo.on.rectangle")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(SnappetColor.workout)
                .disabled(decoding)
                .padding(.horizontal)
                .accessibilityIdentifier("routine.scanSheet.photos")

                Group {
                    if let photoError {
                        Label(photoError.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("routine.scanSheet.error")
                    } else {
                        Text("A screenshot of a code works too. Nothing leaves your phone.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote).multilineTextAlignment(.center).padding(.horizontal)
            }
            .padding(.vertical, 12)
            .navigationTitle("Scan routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                decoding = true
                photoError = nil
                Task { @MainActor in
                    let result: Result<SharedRoutine, RoutinePhotoImportError>
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        result = await RoutinePhotoImport.routine(fromImageData: data)
                    } else {
                        result = .failure(.noCode)
                    }
                    decoding = false
                    pick = nil
                    switch result {
                    case .success(let routine): found(routine)
                    case .failure(let error): photoError = error
                    }
                }
            }
        }
    }

    private func found(_ routine: SharedRoutine) {
        Haptics.success()
        onFound(routine)
        dismiss()
    }
}
