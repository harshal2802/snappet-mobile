import SwiftUI
import UIKit
import AVFoundation

/// A QR scanner sheet for opening a climb shared from another phone. Reads a
/// `snappet://kilter/climb/<uuid>` link, validates it, and reports the decoded `KilterClimbLink`.
/// Camera-only, on-device, no network. Handles the not-determined / denied / no-camera cases inline.
struct KilterScannerView: View {
    /// Called once with a successfully decoded link (the sheet then dismisses itself).
    let onScan: (KilterClimbLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var sawForeignCode = false

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized: scanner
                case .notDetermined: requestView
                default: deniedView
                }
            }
            .navigationTitle("Scan climb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var scanner: some View {
        ZStack {
            QRScannerRepresentable { code in handle(code) }
                .ignoresSafeArea(edges: .bottom)
            VStack {
                Spacer()
                Text(sawForeignCode ? "That isn't a Snappet climb code." : "Point at a Kilter climb QR code.")
                    .font(.subheadline).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 40)
            }
        }
        .accessibilityIdentifier("kilter.scanner")
    }

    private var requestView: some View {
        ContentUnavailableView {
            Label("Camera access", systemImage: "camera")
        } description: {
            Text("Snappet uses the camera to scan a climb's QR code. Nothing leaves your device.")
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
            Text("Allow camera access in Settings to scan a shared climb.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private func handle(_ code: String) {
        if let link = KilterClimbLink(decoding: code) {
            onScan(link)
            dismiss()
        } else {
            sawForeignCode = true
        }
    }
}

/// Wraps an `AVCaptureSession` configured for QR metadata into SwiftUI. `onCode` fires on the main
/// actor for each newly-seen payload; the parent decides whether it's a climb link.
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

/// The capture plumbing. `UIViewController` is `@MainActor`; the metadata delegate is invoked on the
/// main queue (set below), so it hops back via `MainActor.assumeIsolated` — mirroring the
/// `KilterBoardController` CoreBluetooth pattern for non-`Sendable` Apple objects crossing isolation.
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
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
