import AVFoundation
import QuartzCore
import UIKit
import SwiftUI

/// Builds the Core Animation overlay layer tree for the studio's **text overlays** (S4), composited
/// into export + preview via `AVVideoCompositionCoreAnimationTool` (the proven `VideoStudio` pattern).
/// Each `OverlayItem` (kind `.text`) becomes a CATextLayer positioned (normalized → canvas via
/// `ClipEditGeometry.layerPoint`), scaled, rotated, coloured, and **time-gated** to `[startSec,
/// endSec]` by an opacity keyframe so it appears/disappears on cue. Device-only render; attached only
/// on the instruction-based composer paths (no-filter / transition) — combining overlays WITH a colour
/// filter is a follow-up (the CIFilter handler composites tracks itself). Sticker overlays + animated
/// (keyframed) opacity are follow-ups; v1 is static, time-gated text.
enum StudioOverlays {

    static func makeAnimationTool(overlays: [OverlayItem], canvas: CGSize, totalDuration: Double,
                                  hrSamples: [HRPoint] = [], hrConfig: HROverlayConfig? = nil)
        -> AVVideoCompositionCoreAnimationTool? {
        // `.video` overlays are PiP video tracks (handled by the composer), NOT Core Animation layers.
        let visible = overlays.filter { !$0.content.isEmpty && $0.kind != .video }
        let hasHR = hrConfig != nil && hrSamples.count >= 2
        guard (!visible.isEmpty || hasHR), canvas.width > 0, canvas.height > 0, totalDuration > 0 else { return nil }

        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: canvas)
        let videoLayer = CALayer(); videoLayer.frame = CGRect(origin: .zero, size: canvas)
        let overlayLayer = CALayer(); overlayLayer.frame = CGRect(origin: .zero, size: canvas)

        for overlay in visible {
            let layer = overlay.kind == .sticker
                ? stickerLayer(for: overlay, canvas: canvas)
                : textLayer(for: overlay, canvas: canvas)
            applyVisibility(layer, overlay: overlay, totalDuration: totalDuration)
            overlayLayer.addSublayer(layer)
        }
        if let hrConfig, hasHR {
            overlayLayer.addSublayer(hrLayer(samples: hrSamples, config: hrConfig,
                                             canvas: canvas, totalDuration: totalDuration))
        }
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlayLayer)
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    /// The export heart-rate chart (moving-playhead line): the whole session's HR polyline + a dot
    /// animated along it in sync with the video time. Bottom-left origin (the animation tool's layer
    /// space — same flip as `ClipEditGeometry.layerPoint`).
    private static func hrLayer(samples: [HRPoint], config: HROverlayConfig,
                                canvas: CGSize, totalDuration: Double) -> CALayer {
        let chartW = max(60, canvas.width * config.scale)
        let chartH = chartW * 0.36
        let cx = config.normalizedX * canvas.width
        let cy = canvas.height - config.normalizedY * canvas.height        // flip Y to bottom-left
        let outer = CGRect(x: cx - chartW / 2, y: cy - chartH / 2, width: chartW, height: chartH)
        let rect = outer.insetBy(dx: 6, dy: 6)

        let container = CALayer(); container.frame = outer
        let bg = CALayer(); bg.frame = container.bounds
        bg.backgroundColor = UIColor.black.withAlphaComponent(0.35).cgColor; bg.cornerRadius = 8
        container.addSublayer(bg)

        let pts = HRChartGeometry.normalizedPoints(samples)
        // bottom-left: y = n.y * height (n.y = 1 → top). Map into rect (local to container).
        func local(_ n: CGPoint) -> CGPoint {
            CGPoint(x: (rect.minX - outer.minX) + n.x * rect.width,
                    y: (rect.minY - outer.minY) + n.y * rect.height)
        }
        let lineColor = config.zoneColored
            ? UIColor(HeartRateZone.forBpm(averageBPM(samples)).color)
            : uiColor(config.colorHex)

        let path = CGMutablePath()
        if let f = pts.first { path.move(to: local(f)); for q in pts.dropFirst() { path.addLine(to: local(q)) } }
        let line = CAShapeLayer()
        line.frame = container.bounds; line.path = path
        line.strokeColor = lineColor.cgColor; line.fillColor = UIColor.clear.cgColor
        line.lineWidth = 2; line.lineJoin = .round
        container.addSublayer(line)

        // The playhead dot, animated along the line over the whole timeline.
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 9, height: 9); dot.cornerRadius = 4.5
        dot.backgroundColor = UIColor.white.cgColor
        let inner = CALayer(); inner.frame = CGRect(x: 2, y: 2, width: 5, height: 5)
        inner.cornerRadius = 2.5; inner.backgroundColor = lineColor.cgColor
        dot.addSublayer(inner)
        if !pts.isEmpty {
            let anim = CAKeyframeAnimation(keyPath: "position")
            anim.values = pts.map { NSValue(cgPoint: local($0)) }
            var keyTimes = pts.map { NSNumber(value: min(1, max(0, $0.x))) }
            keyTimes[0] = 0; keyTimes[keyTimes.count - 1] = 1     // must span [0,1]
            anim.keyTimes = keyTimes
            anim.calculationMode = .linear
            anim.beginTime = AVCoreAnimationBeginTimeAtZero
            anim.duration = totalDuration
            anim.isRemovedOnCompletion = false
            anim.fillMode = .both
            dot.position = local(pts[0])
            dot.add(anim, forKey: "hrPlayhead")
        }
        container.addSublayer(dot)
        return container
    }

    private static func averageBPM(_ samples: [HRPoint]) -> Double {
        let v = samples.map(\.bpm).filter { $0 > 0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }

    /// A sticker overlay: an SF Symbol image (`content` = symbol name) tinted by `colorHex`, sized by
    /// scale, positioned + rotated. Falls back to a filled circle if the symbol can't be resolved.
    private static func stickerLayer(for overlay: OverlayItem, canvas: CGSize) -> CALayer {
        let side = max(24, canvas.height * 0.12 * overlay.scale)
        let layer = CALayer()
        let config = UIImage.SymbolConfiguration(pointSize: side, weight: .semibold)
        let image = UIImage(systemName: overlay.content, withConfiguration: config)?
            .withTintColor(uiColor(overlay.colorHex), renderingMode: .alwaysOriginal)
        layer.contents = image?.cgImage
        layer.contentsGravity = .resizeAspect
        let center = ClipEditGeometry.layerPoint(normalized: overlay.position, in: canvas)
        layer.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        if abs(overlay.rotationDegrees) > 0.01 {
            layer.transform = CATransform3DMakeRotation(CGFloat(overlay.rotationDegrees) * .pi / 180, 0, 0, 1)
        }
        return layer
    }

    private static func textLayer(for overlay: OverlayItem, canvas: CGSize) -> CATextLayer {
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
        return text
    }

    /// Time-gate a layer to `[startSec, endSec]` via an opacity keyframe over the whole timeline (so it
    /// also DISAPPEARS after `end`). If the overlay carries `opacityKeyframes`, those drive the opacity
    /// inside the window (animated); otherwise it holds the static `opacity`.
    private static func applyVisibility(_ layer: CALayer, overlay: OverlayItem, totalDuration: Double) {
        let total = max(0.01, totalDuration)
        let start = max(0, min(overlay.startSec, total))
        let end = max(start, min(overlay.endSec, total))
        layer.opacity = 0
        let anim = CAKeyframeAnimation(keyPath: "opacity")

        var values: [Float] = [0, 0]
        var keyTimes: [NSNumber] = [0, NSNumber(value: start / total)]
        let kfs = overlay.opacityKeyframes.sorted { $0.timeSec < $1.timeSec }
        if kfs.isEmpty {
            let o = Float(min(1, max(0, overlay.opacity)))
            values += [o, o]
            keyTimes += [NSNumber(value: start / total), NSNumber(value: end / total)]
        } else {
            // Animated opacity: sample each keyframe (clamped into the window), strictly increasing in t.
            var lastT = start
            for k in kfs {
                let t = min(end, max(start, k.timeSec))
                if t < lastT { continue }
                values.append(Float(min(1, max(0, k.value))))
                keyTimes.append(NSNumber(value: t / total))
                lastT = t
            }
            // Hold the last keyframe value to the window end.
            values.append(values.last ?? 0)
            keyTimes.append(NSNumber(value: end / total))
        }
        values += [0, 0]
        keyTimes += [NSNumber(value: end / total), 1]

        anim.values = values
        anim.keyTimes = keyTimes
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = total
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: "visibility")
    }

    private static func uiColor(_ hex: String) -> UIColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .white }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
