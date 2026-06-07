import Foundation
import Vision
import CoreGraphics

/// On-device receipt OCR. Wraps Vision's text recognizer so the rest of the app deals only
/// in plain receipt text, which the pure `ReceiptParser` then turns into line items. This is
/// the thin platform edge (per the repo's layering rule): all the heuristics that decide what
/// is an item / tax / discount live in `ReceiptParser` and are unit-tested; this file only
/// turns pixels into lines of text.
///
/// Device-only: Vision needs real image data, so this isn't exercised in the unit suite.
enum ReceiptScanner {
    /// Recognize text in an image and return it as newline-separated lines ordered
    /// top-to-bottom — ready to hand to `ReceiptParser.parse`. Synchronous: Vision's
    /// `perform(_:)` runs the request inline and populates `request.results` before it
    /// returns, so callers run it off the main thread themselves if they need to.
    static func recognizeText(in cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        // Receipts are codes and abbreviations (CHSEBRGRCAP, ORGAINA2…), not prose — language
        // correction would "helpfully" mangle them, so turn it off.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }

        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        // Vision's coordinate origin is bottom-left, so a larger midY is higher up the
        // receipt; sort descending to read top → bottom.
        let lines = observations
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
