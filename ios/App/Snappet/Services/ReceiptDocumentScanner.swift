import SwiftUI
import VisionKit

/// SwiftUI wrapper over VisionKit's document camera (`VNDocumentCameraViewController`). It
/// captures one or more receipt pages, OCRs each via `ReceiptScanner`, and hands back the
/// combined text. The caller feeds that text straight into `ReceiptParser`.
///
/// Device-only: the document camera needs a real camera, so gate presentation on
/// `ReceiptDocumentScanner.isSupported` (false on the simulator).
struct ReceiptDocumentScanner: UIViewControllerRepresentable {
    /// Called with the recognized receipt text (empty string if cancelled or OCR failed).
    let onText: (String) -> Void

    /// Whether a document camera is available (false on the simulator / camera-less devices).
    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onText: (String) -> Void
        init(onText: @escaping (String) -> Void) { self.onText = onText }

        // The controller is hosted in a `fullScreenCover`, so the caller drives dismissal by
        // flipping its presentation binding inside `onText` — we don't call `dismiss` here.
        // Every path (finish / cancel / fail) calls `onText` exactly once so the cover always closes.

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            // OCR each scanned page inline (Vision's recognizer is synchronous) and hand back the
            // combined text — mirrors the direct-callback pattern in `MediaPicker.Coordinator`.
            var parts: [String] = []
            for page in 0..<scan.pageCount {
                guard let image = scan.imageOfPage(at: page).cgImage else { continue }
                parts.append(ReceiptScanner.recognizeText(in: image))
            }
            onText(parts.joined(separator: "\n"))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onText("")
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onText("")
        }
    }
}
