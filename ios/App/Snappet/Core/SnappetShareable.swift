import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// A value that can be shared offline as a `snappet://` URL and parsed back from a scanned/opened
/// string. Generalizes the Kilter QR stack (workout-redesign E6): both `KilterClimbLink` (a catalog
/// REFERENCE) and `SharedRoutine` (a whole compact routine) conform, so they share ONE QR renderer
/// (`QRCodeImage`), one scanner (`SnappetScannerView`), and one route pattern (`SnappetDeepLink`).
///
/// Pure value + codec (Foundation only) so every conformer is unit-testable without a camera — the
/// repo's pure-logic-at-a-thin-edge rule. The camera scan stays the only device-pending half.
protocol SnappetShareable: Sendable {
    /// The `snappet://…` URL that carries this value, or nil when it can't be represented.
    var url: URL? { get }
    /// Parse a scanned/opened string back into this value, or nil if it isn't one of ours.
    init?(decoding string: String)
}

extension SnappetShareable {
    /// The string actually encoded into the QR symbol (empty only when the value is unrepresentable).
    var encoded: String { url?.absoluteString ?? "" }
}

// `KilterClimbLink` already provides `url` + `init?(decoding:)` + `encoded` — declare the conformance
// here so the generalized renderer/scanner can treat a climb link and a routine uniformly.
extension KilterClimbLink: SnappetShareable {}

/// Render a string into a crisp QR `UIImage`. Lifted verbatim from `KilterShareView.qrImage(for:)`
/// (workout-redesign E6) so the climb-share sheet and the routine-share sheet render identical codes.
/// The CoreImage generator emits a tiny bitmap, so we scale up with nearest-neighbor interpolation to
/// keep the modules crisp; QR modules stay **pure black-on-white** for maximum scannability.
enum QRCodeImage {
    /// `correctionLevel`: "M" (~15% recovery) is the default — a sensible balance of density vs
    /// resilience. A larger payload can drop to "L" (~7%) to squeeze more data into a scannable code.
    static func make(for string: String, correctionLevel: String = "M", scale: CGFloat = 12) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
