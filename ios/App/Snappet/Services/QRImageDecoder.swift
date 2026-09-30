import Foundation
import CoreImage
import ImageIO
import Vision

/// Reads QR payloads out of a still image — a screenshot or photo of a code picked from the library
/// (prompt 138). On-device only. Vision's barcode detector is tried first (robust to perspective and
/// small codes in a big photo); Core Image's QR detector is the fallback for the images Vision misses.
/// Returns every QR string found, in detection order; the caller decides which one is "ours".
enum QRImageDecoder {
    static func payloads(in data: Data) async -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[
            kCGImagePropertyOrientation] as? UInt32
        return await payloads(in: image, orientation: orientation.flatMap(CGImagePropertyOrientation.init) ?? .up)
    }

    static func payloads(in image: CGImage, orientation: CGImagePropertyOrientation = .up) async -> [String] {
        let fromVision = await Task.detached(priority: .userInitiated) { vision(image, orientation) }.value
        if !fromVision.isEmpty { return fromVision }
        return coreImage(image)
    }

    private static func vision(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        guard (try? handler.perform([request])) != nil else { return [] }
        return unique((request.results ?? []).compactMap(\.payloadStringValue))
    }

    private static func coreImage(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return unique(features.compactMap { ($0 as? CIQRCodeFeature)?.messageString })
    }

    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }
}
