import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// **Looks on playback and shared copies** (prompt 254, EditLooks / ShareSheet). The video in Photos is never changed:
/// a look is a Core Image filter applied while a frame is drawn (an `AVVideoComposition` with a CI handler), and rally
/// finding reads the original frames through its own reader. The filter numbers are pure (`RacketLook.Params`).
enum RacketLookRenderer {
    /// The look applied to one frame.
    static func apply(_ p: RacketLook.Params, to image: CIImage) -> CIImage {
        var out = image
        if p.temperature != 6500 {
            let t = CIFilter.temperatureAndTint()
            t.inputImage = out
            t.neutral = CIVector(x: 6500, y: 0)
            t.targetNeutral = CIVector(x: CGFloat(p.temperature), y: 0)
            out = t.outputImage ?? out
        }
        if p.saturation != 1 || p.contrast != 1 || p.brightness != 0 {
            let c = CIFilter.colorControls()
            c.inputImage = out
            c.saturation = Float(p.saturation)
            c.contrast = Float(p.contrast)
            c.brightness = Float(p.brightness)
            out = c.outputImage ?? out
        }
        return out
    }

    /// A still with a look (the Looks tab's preset thumbnails).
    static func still(_ image: UIImage, look: RacketLook) -> UIImage {
        guard !look.isOriginal, let ci = CIImage(image: image) else { return image }
        let ctx = CIContext()
        let out = apply(look.params, to: ci)
        guard let cg = ctx.createCGImage(out, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    /// A label drawn into a shared copy: white text on a dark rounded box ("Rally 12 · You won · 7 – 5").
    static func labelImage(_ text: String, height: CGFloat) -> CIImage? {
        let size = max(14, height * 0.035)
        let gen = CIFilter.textImageGenerator()
        gen.text = text
        gen.fontName = "HelveticaNeue-Bold"
        gen.fontSize = Float(size)
        gen.scaleFactor = 1
        guard let black = gen.outputImage else { return nil }
        // The generator draws black text; make it white (alpha kept) so it reads on the dark box (found on the phone).
        let white = CIFilter.colorMatrix()
        white.inputImage = black
        white.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        white.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        white.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        white.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        guard let textImage = white.outputImage?.cropped(to: black.extent) else { return nil }
        let pad = size * 0.45
        let box = textImage.extent.insetBy(dx: -pad, dy: -pad * 0.6)
        let bg = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.65)).cropped(to: box)
        return textImage.composited(over: bg).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
    }

    /// A composition over `asset` that draws each frame with the current look of `control`, and the labels for that
    /// moment. Used by the player (labels empty; the look can change while it plays) and by exports.
    static func composition(for asset: AVAsset, control: RacketLookControl) async -> AVVideoComposition? {
        try? await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let source = request.sourceImage
            var out = control.bypassed ? source : apply(control.look.params, to: source.clampedToExtent()).cropped(to: source.extent)
            if let label = control.label(at: request.compositionTime.seconds, height: source.extent.height) {
                let margin = source.extent.height * 0.04
                let y = source.extent.maxY - margin - label.extent.height
                out = label.transformed(by: CGAffineTransform(translationX: source.extent.minX + margin, y: y)).composited(over: out)
            }
            request.finish(with: out, context: nil)
        }
    }
}

/// What the frame handler reads, set from the main actor while it runs on AVFoundation's queue. Guarded by a lock.
final class RacketLookControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _look: RacketLook
    private var _bypass = false
    private let labels: [RacketSharePlan.Label]
    private var cache: [String: CIImage] = [:]

    init(look: RacketLook, labels: [RacketSharePlan.Label] = []) {
        _look = look
        self.labels = labels
    }

    var look: RacketLook {
        get { lock.withLock { _look } }
        set { lock.withLock { _look = newValue } }
    }

    /// "Hold the video to see the original".
    var bypassed: Bool {
        get { lock.withLock { _bypass } }
        set { lock.withLock { _bypass = newValue } }
    }

    func label(at t: Double, height: CGFloat) -> CIImage? {
        guard let l = labels.first(where: { t >= $0.start && t < $0.end }) else { return nil }
        return lock.withLock {
            if let c = cache[l.text] { return c }
            let img = RacketLookRenderer.labelImage(l.text, height: height)
            cache[l.text] = img
            return img
        }
    }
}
