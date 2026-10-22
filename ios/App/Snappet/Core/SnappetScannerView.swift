import SwiftUI
import UIKit
import AVFoundation
import PhotosUI

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
    @Environment(SuiteRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

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
        } else if let link = SnappetCodeImport.snappetLink(code) {
            // Another kind of Snappet code (a routine in the climb scanner) — open it where it belongs (prompt 201).
            SnappetLinkHandoff.open(link, router: router, dismiss: dismiss)
        } else {
            sawForeignCode = true
        }
    }
}

/// Hands a Snappet link of another kind to the shell's link router after this sheet has gone (prompt 201). The delay
/// lets the dismissal finish first: presenting the link's own sheet (an import preview) in the same update as this
/// one's dismissal would drop it.
enum SnappetLinkHandoff {
    @MainActor
    static func open(_ link: String, router: SuiteRouter, dismiss: DismissAction) {
        guard let url = URL(string: link) else { return }
        Haptics.success()
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            router.pendingLink = url
        }
    }
}

/// **Choose from Photos** under a scanner (prompt 138 for routines; every scanner since prompt 201): a screenshot or
/// photo of a code imports too. Its own kind → `onFound`; another Snappet code → opened where it belongs; else an
/// inline reason. Placed BESIDE the scanner (not inside it) so its accessibility ids survive the scanner's own id.
struct PhotoCodePickerRow<Value>: View {
    /// Accessibility id prefix: `<prefix>.photos` (the button) and `<prefix>.error`.
    let idPrefix: String
    let tint: Color
    let decode: (String) -> Value?
    let onFound: (Value) -> Void

    @Environment(SuiteRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var pick: PhotosPickerItem?
    @State private var decoding = false
    @State private var failure: SnappetCodeImport.Failure?

    var body: some View {
        VStack(spacing: 12) {
            // Resolved outside: PhotosPicker's label closure is Sendable and can't read @State.
            let pickTitle = decoding ? "Reading photo…" : "Choose from Photos"
            PhotosPicker(selection: $pick, matching: .images, photoLibrary: .shared()) {
                Label(pickTitle, systemImage: "photo.on.rectangle")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.bordered).tint(tint)
            .disabled(decoding)
            .accessibilityIdentifier("\(idPrefix).photos")

            Group {
                if let failure {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("\(idPrefix).error")
                } else {
                    Text("A screenshot of a code works too. Nothing leaves your phone.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote).multilineTextAlignment(.center)
        }
        .padding(.horizontal)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            decoding = true
            failure = nil
            Task { @MainActor in
                let payloads: [String]
                if let data = try? await item.loadTransferable(type: Data.self) {
                    payloads = await QRImageDecoder.payloads(in: data)
                } else {
                    payloads = []
                }
                decoding = false
                pick = nil
                switch SnappetCodeImport.pick(payloads, decode: decode) {
                case .value(let value):
                    Haptics.success()
                    onFound(value)
                case .otherLink(let link):
                    SnappetLinkHandoff.open(link, router: router, dismiss: dismiss)
                case .failure(let why):
                    failure = why
                }
            }
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
