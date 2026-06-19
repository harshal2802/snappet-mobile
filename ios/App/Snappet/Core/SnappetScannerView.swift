import SwiftUI
import UIKit
import AVFoundation

/// A generalized QR scanner sheet (workout-redesign E6): camera-only, on-device, no network. It hands
/// each scanned payload to a caller-supplied `decode` closure and reports the first thing that decodes —
/// so the SAME plumbing scans a Kilter climb link, a shared routine, or anything else that conforms to
/// `SnappetShareable`. Lifted from `KilterScannerView` (its AVFoundation `QRScannerRepresentable` +
/// permission states) so the two share one camera path and can't drift.
///
/// Handles not-determined / denied / no-camera inline. Rejecting a foreign code shows the `foreignHint`.
struct SnappetScannerView<Value>: View {
    /// Prompt shown while pointing at a (not-yet-recognized) code.
    let prompt: String
    /// Hint shown after a code that `decode` rejected (a foreign / wrong-type QR).
    let foreignHint: String
    /// Try to decode a scanned string into the value type, or nil if it isn't one of ours.
    let decode: (String) -> Value?
    /// Called once with a successfully decoded value (the parent dismisses).
    let onScan: (Value) -> Void

    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var sawForeignCode = false

    var body: some View {
        Group {
            switch status {
            case .authorized: scanner
            case .notDetermined: requestView
            default: deniedView
            }
        }
    }

    private var scanner: some View {
        ZStack {
            SnappetQRScannerRepresentable { code in handle(code) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack {
                Spacer()
                Text(sawForeignCode ? foreignHint : prompt)
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 24)
            }
        }
        .padding(.horizontal)
    }

    private var requestView: some View {
        ContentUnavailableView {
            Label("Camera access", systemImage: "camera")
        } description: {
            Text("Snappet uses the camera to scan a QR code. Nothing leaves your device.")
        } actions: {
            Button("Allow camera") {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    Task { @MainActor in status = granted ? .authorized : .denied }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var deniedView: some View {
        ContentUnavailableView {
            Label("Camera is off", systemImage: "camera.fill")
        } description: {
            Text("Allow camera access in Settings to scan a code.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private func handle(_ code: String) {
        if let value = decode(code) {
            onScan(value)
        } else {
            sawForeignCode = true
        }
    }
}

/// Wraps an `AVCaptureSession` configured for QR metadata into SwiftUI. `onCode` fires on the main actor
/// for each newly-seen payload; the parent decides whether it's one of ours. (Lifted from the private
/// representable in `KilterScannerView` so the climb scanner and the routine scanner share one path.)
struct SnappetQRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> SnappetQRScannerController {
        let vc = SnappetQRScannerController()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ controller: SnappetQRScannerController, context: Context) {}
}

/// The capture plumbing. `UIViewController` is `@MainActor`; the metadata delegate is invoked on the main
/// queue (set below), so it hops back via `MainActor.assumeIsolated` — mirroring the `KilterBoardController`
/// CoreBluetooth pattern for non-`Sendable` Apple objects crossing isolation.
final class SnappetQRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// Last payload reported, so the same code in frame after frame doesn't flood — but a *different*
    /// (e.g. the correct) code can still be read after a foreign one.
    private var lastReported: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.layer.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !session.isRunning else { return }
        // `startRunning()` blocks — keep it off the main thread. The session isn't `Sendable`; it's
        // confined to this controller and only started here, so the unsafe capture is sound.
        nonisolated(unsafe) let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard session.isRunning else { return }
        nonisolated(unsafe) let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        nonisolated(unsafe) let objects = objects
        MainActor.assumeIsolated {
            guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue, value != lastReported else { return }
            lastReported = value
            onCode?(value)
        }
    }
}
