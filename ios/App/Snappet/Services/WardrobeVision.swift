import Foundation
import UIKit
import Vision
import CoreImage

/// The Wardrobe capture pipeline's platform edge (wardrobe prompt 01): subject lift,
/// image classification, and dominant-color extraction — all on-device Vision/CoreImage.
/// Every *decision* (label → category, RGB → color family, style/season inference) is a
/// pure mapping in `WardrobeTags.swift`; this file only moves pixels.
enum WardrobeVision {

    /// The auto-tagger's draft — every field editable in the tag sheet before save.
    struct DraftTags: Sendable, Equatable {
        var suggestedName: String = ""
        var category: GarmentCategory = .top
        var color: GarmentColorFamily = .grey
        var pattern: GarmentPattern = .solid
        var style: GarmentStyle = .casual
        var material: String = ""
        var seasons: Set<GarmentSeason> = []
        /// Whether the optional Apple-Intelligence pass refined the draft (UI badge).
        var sharpenedByAI: Bool = false
    }

    // MARK: - Subject lift

    /// Cut the garment off its background (VisionKit-style subject lift via
    /// `VNGenerateForegroundInstanceMaskRequest`, iOS 17+). Returns a transparent-background
    /// PNG-able image, or nil when segmentation finds no confident subject — the capture
    /// flow then offers "Keep original".
    static func liftSubject(from image: UIImage) async -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(image.imageOrientation))
            guard (try? handler.perform([request])) != nil,
                  let result = request.results?.first else { return nil }
            guard let masked = try? result.generateMaskedImage(
                ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
            else { return nil }
            let ci = CIImage(cvPixelBuffer: masked)
            let context = CIContext()
            guard let out = context.createCGImage(ci, from: ci.extent) else { return nil }
            return UIImage(cgImage: out)
        }.value
    }

    // MARK: - Auto-tagging

    /// Produce draft tags for a captured garment: Vision classification labels → category
    /// + style, average subject color → family, calendar month → season starting point.
    /// The optional Apple-Intelligence sharpener in `WardrobeIntelligence` then refines
    /// name/pattern/material when available; this heuristic result is the always-on floor.
    static func draftTags(for image: UIImage, now: Date = .now) async -> DraftTags {
        var draft = DraftTags()

        let labels = await classify(image)
        if let match = labels.lazy.compactMap({ label -> (GarmentCategory, String)? in
            GarmentCategory.fromVisionLabel(label).map { ($0, label) }
        }).first {
            draft.category = match.0
            draft.style = GarmentStyle.inferred(from: match.1)
            draft.suggestedName = match.1.replacingOccurrences(of: "_", with: " ").capitalized
        }

        if let rgb = averageOpaqueColor(of: image) {
            draft.color = GarmentColorFamily.fromRGB(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
        if draft.suggestedName.isEmpty {
            draft.suggestedName = "\(draft.color.title) \(draft.category.title.lowercased())"
        } else {
            draft.suggestedName = "\(draft.color.title) \(draft.suggestedName.lowercased())"
        }

        // Season starting point: outerwear reads cold-half; everything else all-season.
        if draft.category == .outerwear {
            draft.seasons = [.fall, .winter]
        }
        return draft
    }

    /// Vision classification labels above a modest confidence, best-first.
    static func classify(_ image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(image.imageOrientation))
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? [])
                .filter { $0.confidence > 0.2 }
                .sorted { $0.confidence > $1.confidence }
                .map(\.identifier)
        }.value
    }

    /// Average color of the non-transparent pixels (post-lift, that's the garment).
    /// Downsamples to 32×32 first so the walk is trivial.
    static func averageOpaqueColor(of image: UIImage) -> (r: Double, g: Double, b: Double)? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            r += Double(pixels[i]) / 255 / a
            g += Double(pixels[i + 1]) / 255 / a
            b += Double(pixels[i + 2]) / 255 / a
            n += 1
        }
        guard n > 0 else { return nil }
        return (min(1, r / n), min(1, g / n), min(1, b / n))
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
