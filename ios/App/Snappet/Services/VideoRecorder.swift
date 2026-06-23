import SwiftUI
import UIKit
import AVFoundation
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
    ///
    /// The Simulator is forced `false` explicitly: on current simulators `isSourceTypeAvailable(.camera)` can
    /// report `true`, but actually presenting an `(.camera)` `UIImagePickerController` there has no camera to
    /// drive and **crashes the app** — so we must never take the present path on the sim. Real hardware keeps
    /// the genuine capability check (a real device without a camera then correctly reads `false`).
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    /// Request camera (and, best-effort, microphone) capture authorization. **Must be granted before the
    /// recorder is presented:** configuring the camera-only `UIImagePickerController` properties
    /// (`cameraCaptureMode` / `cameraFlashMode`) on a camera the app isn't authorized for throws an
    /// `NSException` → `abort()` (the device crash). `isSourceTypeAvailable(.camera)` is `true` even while
    /// camera permission is still `.notDetermined`, so the source-availability guard alone is NOT enough —
    /// this mirrors `SnappetScannerView`, which pre-requests `AVCaptureDevice` access. Returns whether the
    /// **camera** is usable; the mic is requested too (recorded video has audio) but a denied mic only makes
    /// the clip silent, so it doesn't block.
    static func requestCaptureAccess() async -> Bool {
        let camera = await access(for: .video)
        guard camera else { return false }
        _ = await access(for: .audio)   // best-effort: silent video if denied
        return true
    }

    private static func access(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false   // denied / restricted
        }
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        // Video-only `mediaTypes` puts the camera straight into video-recording mode. We deliberately do NOT
        // touch the camera-only *setters* `cameraCaptureMode` / `videoQuality` / `cameraFlashMode`: configuring
        // them here throws an NSException (→ SIGABRT) on a real device — they're validated against a camera
        // session that isn't ready at `makeUIViewController` time (confirmed from the device crash report:
        // `-[UIImagePickerController setCameraCaptureMode:]` → objc_exception_throw → abort). The single
        // movie media type is sufficient to record video at the default quality, with no throwing setters.
        picker.mediaTypes = [UTType.movie.identifier]
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
