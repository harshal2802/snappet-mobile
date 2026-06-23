import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// In-app **camera video recorder** for capturing a clip mid-session (e.g. while timing a set). A thin
/// `UIImagePickerController(.camera)` wrapper configured for VIDEO capture — the native record / stop /
/// "Use Video" UI, on-device, no network. Hands the finished movie's temp URL back via `onRecorded` (or
/// `onCancel` on dismiss); the caller saves it to Photos (`MediaLibraryService.saveRecording`) and tags it
/// to the session. Mirrors `MediaPicker`'s representable shape (the PHPicker analogue) so the two camera
/// edges read the same.
///
/// **Device-only:** the Simulator has no camera (`isAvailable == false`), so callers must guard on
/// `isAvailable` before presenting — the real record→save→attach path can only be exercised on hardware.
struct VideoRecorder: UIViewControllerRepresentable {
    /// The recorded movie's temporary file URL (`info[.mediaURL]`) — valid until the picker is released, so
    /// the caller should save/copy it promptly.
    let onRecorded: (URL) -> Void
    /// The user backed out without recording (or no movie came back).
    let onCancel: () -> Void

    /// `false` on the Simulator and on any device without a camera — guard on this before presenting.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // `cameraCaptureMode` is only valid once `sourceType == .camera` (set above first).
        picker.cameraCaptureMode = .video
        picker.mediaTypes = [UTType.movie.identifier]   // video only — no stills
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onRecorded: onRecorded, onCancel: onCancel) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onRecorded: (URL) -> Void
        let onCancel: () -> Void
        init(onRecorded: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onRecorded = onRecorded
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { onRecorded(url) } else { onCancel() }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCancel() }
    }
}

/// A clip recorded in-session with the camera and already saved to the user's Photos library, awaiting a
/// session tag. Carries the saved asset's `localIdentifier`, the wall-clock instant recording **began**
/// (mapped to a session-relative offset when the clip is attached, via `SessionMediaService.candidate`),
/// and its measured duration. A plain value type so it can be accumulated in a cover and handed up to the
/// session at commit time.
struct RecordedClip: Identifiable, Sendable, Equatable {
    let id: UUID
    /// The PHAsset `localIdentifier` of the just-saved recording (the same handle every `SessionMedia` row
    /// stores — bytes stay in Photos).
    let localIdentifier: String
    /// Wall-clock instant recording started → the session-relative `offsetSec` at attach time.
    let capturedAt: Date
    /// Measured video duration in seconds; `nil` when it couldn't be read.
    let durationSec: Double?

    init(id: UUID = UUID(), localIdentifier: String, capturedAt: Date, durationSec: Double?) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.capturedAt = capturedAt
        self.durationSec = durationSec
    }
}
