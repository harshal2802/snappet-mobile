import AVFoundation
import QuartzCore
import UIKit

/// Builds the Core Animation overlay layer tree for the studio's **text overlays** (S4), composited
/// into export + preview via `AVVideoCompositionCoreAnimationTool` (the proven `VideoStudio` pattern).
/// Each `OverlayItem` (kind `.text`) becomes a CATextLayer positioned (normalized → canvas via
/// `ClipEditGeometry.layerPoint`), scaled, rotated, coloured, and **time-gated** to `[startSec,
/// endSec]` by an opacity keyframe so it appears/disappears on cue. Device-only render; attached only
/// on the instruction-based composer paths (no-filter / transition) — combining overlays WITH a colour
/// filter is a follow-up (the CIFilter handler composites tracks itself). Sticker overlays + animated
/// (keyframed) opacity are follow-ups; v1 is static, time-gated text.
enum StudioOverlays {

    static func makeAnimationTool(overlays: [OverlayItem], canvas: CGSize, totalDuration: Double)
        -> AVVideoCompositionCoreAnimationTool? {
        let texts = overlays.filter { $0.kind == .text && !$0.content.isEmpty }
        guard !texts.isEmpty, canvas.width > 0, canvas.height > 0, totalDuration > 0 else { return nil }

        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: canvas)
        let videoLayer = CALayer(); videoLayer.frame = CGRect(origin: .zero, size: canvas)
        let overlayLayer = CALayer(); overlayLayer.frame = CGRect(origin: .zero, size: canvas)

        for overlay in texts {
            overlayLayer.addSublayer(textLayer(for: overlay, canvas: canvas, totalDuration: totalDuration))
        }
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlayLayer)
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    private static func textLayer(for overlay: OverlayItem, canvas: CGSize, totalDuration: Double) -> CATextLayer {
        let text = CATextLayer()
        text.string = overlay.content
        let fontSize = max(8, canvas.height * 0.05 * overlay.scale)
        text.fontSize = fontSize
        text.foregroundColor = uiColor(overlay.colorHex).cgColor
        text.alignmentMode = .center
        text.isWrapped = true
        text.contentsScale = 2
        text.shadowColor = UIColor.black.cgColor
        text.shadowOpacity = 0.6
        text.shadowRadius = 3
        text.shadowOffset = .zero

        let boxW = canvas.width * 0.9
        let boxH = max(fontSize * 1.6, 40)
        let center = ClipEditGeometry.layerPoint(normalized: overlay.position, in: canvas)
        text.frame = CGRect(x: center.x - boxW / 2, y: center.y - boxH / 2, width: boxW, height: boxH)
        if abs(overlay.rotationDegrees) > 0.01 {
            text.transform = CATransform3DMakeRotation(CGFloat(overlay.rotationDegrees) * .pi / 180, 0, 0, 1)
        }

        // Time-gate: visible (at `opacity`) only within [start, end], else 0. A keyframe over the whole
        // timeline so the overlay also DISAPPEARS after `end` (a fillMode-forwards basic animation would
        // wrongly hold it). Same approach as VideoStudio.attachOverlays.
        let total = max(0.01, totalDuration)
        let start = max(0, min(overlay.startSec, total))
        let end = max(start, min(overlay.endSec, total))
        text.opacity = 0
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        let o = Float(min(1, max(0, overlay.opacity)))
        anim.values = [0, 0, o, o, 0, 0]
        anim.keyTimes = [0, NSNumber(value: start / total), NSNumber(value: start / total),
                         NSNumber(value: end / total), NSNumber(value: end / total), 1]
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = total
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        text.add(anim, forKey: "visibility")
        return text
    }

    private static func uiColor(_ hex: String) -> UIColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .white }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
