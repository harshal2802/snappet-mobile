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
///
/// Called from view bodies, which re-run on every state change. It used to build a new GPU `CIContext` per
/// call; on the GPU-less CI simulator showing one festival share code kept the app busy for 20–60 s (prompt 267).
/// Now one CPU context is shared (a black-and-white bitmap needs no GPU, and setting one up is the slow part
/// without a real GPU), and a code already drawn comes from a small cache.
enum QRCodeImage {
    /// `CIContext` is thread-safe and meant to be reused (Core Image docs), as is `NSCache`.
    nonisolated(unsafe) private static let context = CIContext(options: [.useSoftwareRenderer: true])
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 16
        return c
    }()

    /// `correctionLevel`: "M" (~15% recovery) is the default — a sensible balance of density vs
    /// resilience. A larger payload can drop to "L" (~7%) to squeeze more data into a scannable code.
    static func make(for string: String, correctionLevel: String = "M", scale: CGFloat = 12) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let key = "\(correctionLevel)|\(scale)|\(string)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}
