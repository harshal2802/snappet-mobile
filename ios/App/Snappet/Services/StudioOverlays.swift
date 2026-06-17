import AVFoundation
import QuartzCore
import UIKit
import SwiftUI

/// Builds the Core Animation overlay layer tree for the studio's **text overlays** (S4), composited
/// into export + preview via `AVVideoCompositionCoreAnimationTool` (the layer-tree pattern the studio's
/// render engine, `StudioComposer`, drives).
/// Each `OverlayItem` (kind `.text`) becomes a CATextLayer positioned (normalized → canvas via
/// `ClipEditGeometry.layerPoint`), scaled, rotated, coloured, and **time-gated** to `[startSec,
/// endSec]` by an opacity keyframe so it appears/disappears on cue. Device-only render; attached only
/// on the instruction-based composer paths (no-filter / transition) — combining overlays WITH a colour
/// filter is a follow-up (the CIFilter handler composites tracks itself). Sticker overlays + animated
/// (keyframed) opacity are follow-ups; v1 is static, time-gated text.

/// One video clip's HR placed on the composed output timeline — the per-clip analogue of the
/// session-wide `(hrSamples, hrElements)` pair. `samples` are already sliced to the clip's capture
/// window and rebased to clip-local time (`StudioHRPlacement` + `HRWindowSlicer`); the chart normalizes
/// its own x-axis, so only the relative shape matters. `elements` are the badges resolved over THIS
/// clip's window. `Sendable` so it crosses into the AVFoundation export actor.
struct PlacedClipHR: Sendable, Equatable {
    var startSec: Double          // clip's start on the output timeline
    var durationSec: Double       // clip's output (trim+speed) length
    var samples: [HRPoint]
    var elements: [ResolvedHROverlay]
    /// The resolved HR stat **tile** for this clip (the overlay redesign). When set, one composite tile
    /// is drawn at the clip's slot instead of the free-floating `elements`. `nil` = legacy badges.
    var tile: ResolvedHRTile? = nil
}

enum StudioOverlays {

    /// `clipHR` (non-empty for the **multi-clip Studio**) draws each clip's own capture-window HR at
    /// the clip's slot — superseding the session-wide `hrSamples`/`hrElements` (the fallback when
    /// `clipHR` is empty). This is the fix for the Studio drawing the whole session's HR across the
    /// concatenated composition.
    static func makeAnimationTool(overlays: [OverlayItem], canvas: CGSize, totalDuration: Double,
                                  hrSamples: [HRPoint] = [], hrConfig: HROverlayConfig? = nil,
                                  hrElements: [ResolvedHROverlay] = [],
                                  hrTile: ResolvedHRTile? = nil,
                                  clipHR: [PlacedClipHR] = [])
        -> AVVideoCompositionCoreAnimationTool? {
        // `.video` overlays are PiP video tracks (handled by the composer), NOT Core Animation layers.
        let visible = overlays.filter { !$0.content.isEmpty && $0.kind != .video }
        let perClip = !clipHR.isEmpty
        let chartOn = hrConfig?.showChart ?? false
        let hasHR = perClip ? (chartOn && clipHR.contains { $0.samples.count >= 2 })
                            : (chartOn && hrSamples.count >= 2)
        let hasElements = perClip ? clipHR.contains { !$0.elements.isEmpty } : !hrElements.isEmpty
        // The unified HR stat tile (the overlay redesign) supersedes `hrElements` when present.
        let hasTile = perClip ? clipHR.contains { $0.tile != nil } : (hrTile != nil)
        guard (!visible.isEmpty || hasHR || hasElements || hasTile),
              canvas.width > 0, canvas.height > 0, totalDuration > 0 else { return nil }

        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: canvas)
        let videoLayer = CALayer(); videoLayer.frame = CGRect(origin: .zero, size: canvas)
        let overlayLayer = CALayer(); overlayLayer.frame = CGRect(origin: .zero, size: canvas)

        for overlay in visible {
            let layer: CALayer
            switch overlay.kind {
            case .sticker:   layer = stickerLayer(for: overlay, canvas: canvas)
            case .climbName: layer = styledTextLayer(for: overlay, canvas: canvas,
                                                     fontFraction: 0.04, defaultHighlight: "#000000")
            default:         layer = styledTextLayer(for: overlay, canvas: canvas,
                                                     fontFraction: 0.05, defaultHighlight: nil)
            }
            applyVisibility(layer, overlay: overlay, totalDuration: totalDuration)
            overlayLayer.addSublayer(layer)
        }
        if perClip {
            // Multi-clip Studio: one tile (or, legacy, one chart + element set) PER clip, each placed/
            // gated to its own slot so it shows that clip's capture-window HR (not the whole session
            // across the composition).
            for clip in clipHR {
                if let tile = clip.tile {
                    // The unified HR stat tile owns the whole overlay (including its own chart register).
                    if let layer = hrTileLayer(tile, samples: clip.samples, canvas: canvas,
                                               totalDuration: totalDuration,
                                               slotStartSec: clip.startSec, slotDurationSec: clip.durationSec) {
                        overlayLayer.addSublayer(layer)
                    }
                    continue
                }
                if let hrConfig, chartOn, clip.samples.count >= 2 {
                    overlayLayer.addSublayer(hrChartLayer(
                        samples: clip.samples, config: hrConfig, canvas: canvas,
                        totalDuration: totalDuration,
                        slotStartSec: clip.startSec, slotDurationSec: clip.durationSec))
                }
                for layer in hrElementLayers(clip.elements, canvas: canvas, totalDuration: totalDuration,
                                             slotStartSec: clip.startSec, slotDurationSec: clip.durationSec) {
                    overlayLayer.addSublayer(layer)
                }
            }
        } else if let hrTile {
            // Session-wide tile (the fallback path for clips with no media link).
            if let layer = hrTileLayer(hrTile, samples: hrSamples, canvas: canvas, totalDuration: totalDuration) {
                overlayLayer.addSublayer(layer)
            }
        } else {
            if let hrConfig, hasHR {
                overlayLayer.addSublayer(hrChartLayer(samples: hrSamples, config: hrConfig,
                                                      canvas: canvas, totalDuration: totalDuration))
            }
            // The configurable HR/fitness overlay elements (prompt 28): one badge layer per display
            // segment, opacity-gated to its time window (a static element is a single [0,1] segment).
            for layer in hrElementLayers(hrElements, canvas: canvas, totalDuration: totalDuration) {
                overlayLayer.addSublayer(layer)
            }
        }
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlayLayer)
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    /// The export heart-rate chart (moving-playhead line): the HR polyline + a dot animated along it
    /// in sync with the video time. Bottom-left origin (the animation tool's layer space — same flip
    /// as `ClipEditGeometry.layerPoint`). Internal so the studio's render engine reuses it.
    /// `slotStartSec`/`slotDurationSec` place the chart on **one clip's slot** of a multi-clip
    /// composition: the playhead dot sweeps only during the slot and the whole chart is opacity-gated to
    /// it (so each clip shows its own capture-window HR). Defaulted (`slotStartSec = 0`, `slotDurationSec
    /// = nil → the whole timeline, no gate`) so a whole-timeline chart renders without a slot gate.
    static func hrChartLayer(samples: [HRPoint], config: HROverlayConfig,
                             canvas: CGSize, totalDuration: Double,
                             slotStartSec: Double = 0, slotDurationSec: Double? = nil) -> CALayer {
        let playheadDuration = slotDurationSec ?? totalDuration
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
            // Build STRICTLY-INCREASING keyTimes in [0,1] (Core Animation drops a `.linear` keyframe
            // animation with equal/decreasing keyTimes — duplicate sample timestamps would otherwise
            // freeze the export dot). Keep values aligned to the kept keyTimes; span [0,1].
            var values: [NSValue] = []
            var keyTimes: [NSNumber] = []
            var last = -1.0
            let eps = 1e-4
            for p in pts {
                let kt = min(1, max(0, p.x))
                if kt > last + eps {
                    values.append(NSValue(cgPoint: local(p))); keyTimes.append(NSNumber(value: kt)); last = kt
                }
            }
            if keyTimes.count >= 2 {
                keyTimes[0] = 0
                keyTimes[keyTimes.count - 1] = 1
                let anim = CAKeyframeAnimation(keyPath: "position")
                anim.values = values
                anim.keyTimes = keyTimes
                anim.calculationMode = .linear
                anim.beginTime = AVCoreAnimationBeginTimeAtZero + slotStartSec
                anim.duration = max(0.01, playheadDuration)
                anim.isRemovedOnCompletion = false
                anim.fillMode = .both
                dot.position = local(pts[0])
                dot.add(anim, forKey: "hrPlayhead")
            } else {
                dot.position = local(pts[0])
            }
        }
        container.addSublayer(dot)
        // Multi-clip: the chart is only on screen during its own clip's slot (otherwise every clip's
        // chart would stack on top of each other for the whole video).
        if let slotDurationSec,
           !(slotStartSec <= 0.0001 && slotStartSec + slotDurationSec >= totalDuration - 0.0001) {
            gateSegmentOpacity(container, start: slotStartSec / totalDuration,
                               end: (slotStartSec + slotDurationSec) / totalDuration,
                               totalDuration: totalDuration)
        }
        return container
    }

    /// Build the burned-in badge layers for the configurable HR/fitness overlay elements (prompt 28).
    /// Each resolved overlay contributes one rounded "pill" `CATextLayer` per display segment, all at
    /// the same position, each opacity-gated to its `[start, end]` fraction window — so a **static**
    /// element (one `[0,1]` segment) is always visible while an **animated live** element shows its
    /// changing readings over the clip (Core Animation can't redraw text per frame, so we cross-fade
    /// pre-rendered per-value layers). Bottom-left layer space (the animation tool's), like the chart.
    /// `slotStartSec`/`slotDurationSec` place the badges on **one clip's slot** of a multi-clip
    /// composition: each element's `[0,1]` clip-local segment fractions are mapped onto the clip's
    /// slot window before opacity-gating, so a clip's per-clip badges only show during that clip.
    /// Defaulted (`slotStartSec = 0`, `slotDurationSec = nil → whole timeline`) to an identity mapping,
    /// so a whole-timeline badge renders without a slot gate.
    static func hrElementLayers(_ overlays: [ResolvedHROverlay], canvas: CGSize,
                                totalDuration: Double,
                                slotStartSec: Double = 0, slotDurationSec: Double? = nil) -> [CALayer] {
        guard canvas.width > 0, canvas.height > 0, totalDuration > 0 else { return [] }
        let slotDur = slotDurationSec ?? totalDuration
        var layers: [CALayer] = []
        for o in overlays {
            let cx = o.normalizedX * canvas.width
            let cy = canvas.height - o.normalizedY * canvas.height        // flip Y to bottom-left
            let fontSize = max(10, canvas.height * 0.045 * o.scale)
            for seg in o.segments {
                let pill = hrBadgeLayer(text: seg.reading.text, hex: seg.reading.hex,
                                        fontSize: fontSize, center: CGPoint(x: cx, y: cy))
                // Map clip-local segment fractions onto the clip's slot, as fractions of the whole timeline.
                let absStart = (slotStartSec + seg.start * slotDur) / totalDuration
                let absEnd = (slotStartSec + seg.end * slotDur) / totalDuration
                gateSegmentOpacity(pill, start: absStart, end: absEnd, totalDuration: totalDuration)
                layers.append(pill)
            }
        }
        return layers
    }

    /// One rounded badge: a coloured `CATextLayer` on a translucent dark capsule, sized to its text.
    private static func hrBadgeLayer(text: String, hex: String, fontSize: CGFloat,
                                     center: CGPoint) -> CALayer {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let color = uiColor(hex)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let textSize = attributed.size()
        let hPad: CGFloat = fontSize * 0.5, vPad: CGFloat = fontSize * 0.3
        let boxW = ceil(textSize.width) + 2 * hPad, boxH = ceil(textSize.height) + 2 * vPad

        let container = CALayer()
        container.frame = CGRect(x: center.x - boxW / 2, y: center.y - boxH / 2, width: boxW, height: boxH)
        container.backgroundColor = UIColor.black.withAlphaComponent(0.4).cgColor
        container.cornerRadius = boxH / 2

        let label = CATextLayer()
        label.string = attributed
        label.contentsScale = 2
        label.alignmentMode = .center
        label.frame = CGRect(x: hPad, y: vPad, width: ceil(textSize.width), height: ceil(textSize.height))
        container.addSublayer(label)
        return container
    }

    /// Opacity-gate a badge to its `[start, end]` fraction window. A full-clip `[0,1]` segment stays
    /// fully visible; a sub-window appears/disappears on cue (the animated-live cross-fade).
    private static func gateSegmentOpacity(_ layer: CALayer, start: Double, end: Double,
                                           totalDuration: Double) {
        if start <= 0.0001 && end >= 0.9999 { layer.opacity = 1; return }   // static → always on
        let s = min(1, max(0, start)), e = min(1, max(s, end))
        layer.opacity = 0
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        // 0 before the window, 1 across it, 0 after — tiny epsilons keep keyTimes strictly increasing.
        let eps = 1e-4
        anim.values = [0, 0, 1, 1, 0] as [Float]
        anim.keyTimes = [0, max(0, s - eps), s, e, min(1, e + eps)].map { NSNumber(value: $0) }
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = max(0.01, totalDuration)
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        layer.add(anim, forKey: "hrSegment")
    }

    // MARK: - Unified HR stat tile (the overlay redesign)

    /// Burn in one **composite HR stat tile**: a single card (scrim + per-metric slots + an optional
    /// chart register) laid out by the pure `HRTileLayout` — the SAME function the SwiftUI preview runs,
    /// so the file matches the editor (WYSIWYG). Bottom-left layer space (the animation tool's), so the
    /// top-left frames `HRTileLayout` returns are flipped into the container. `slotStartSec`/
    /// `slotDurationSec` place + gate the tile on **one clip's slot** of a multi-clip composition (so a
    /// per-clip tile only shows during that clip); defaulted to the whole timeline for a session-wide tile.
    static func hrTileLayer(_ tile: ResolvedHRTile, samples: [HRPoint], canvas: CGSize,
                            totalDuration: Double, slotStartSec: Double = 0,
                            slotDurationSec: Double? = nil) -> CALayer? {
        guard canvas.width > 0, canvas.height > 0, totalDuration > 0 else { return nil }
        let w = max(1, canvas.width * tile.width)
        let h = max(1, canvas.height * tile.height)
        let cxTL = tile.centerX * canvas.width
        let cyTL = tile.centerY * canvas.height
        let topLeft = CGRect(x: cxTL - w / 2, y: cyTL - h / 2, width: w, height: h)
        let result = HRTileLayout.layout(template: tile.template, enabledMetrics: tile.enabledMetrics,
                                         tileRect: CGRect(origin: .zero, size: topLeft.size),
                                         hasChart: tile.showChart)

        // The card container, flipped from the top-left canvas box to the tool's bottom-left space.
        let container = CALayer()
        container.frame = CGRect(x: topLeft.minX, y: canvas.height - topLeft.maxY, width: w, height: h)

        // Legibility scrim behind everything (honors the HR-legibility decision, prompt 51).
        let scrim = CALayer()
        scrim.frame = container.bounds
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.32).cgColor
        scrim.cornerRadius = min(18, h * 0.18)
        container.addSublayer(scrim)

        // Flip a top-left local frame (HRTileLayout space) into the container's bottom-left space.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }

        let slotDur = slotDurationSec ?? totalDuration
        let segByMetric = Dictionary(tile.metrics.map { ($0.metric, $0.segments) }, uniquingKeysWith: { a, _ in a })

        if tile.showChart, let chartRect = result.chartRect, samples.count >= 2 {
            container.addSublayer(tileChartLayer(samples: samples, localRect: flip(chartRect),
                                                 zoneColored: tile.zoneColored, totalDuration: totalDuration,
                                                 slotStartSec: slotStartSec, slotDurationSec: slotDur))
        }

        for slot in result.slots {
            guard let segs = segByMetric[slot.metric], !segs.isEmpty else { continue }
            let frame = flip(slot.frame)
            switch slot.role {
            case .pill:
                for l in tilePillLayers(segs, frame: frame, fontSize: slot.fontSize,
                                        slotStartSec: slotStartSec, slotDur: slotDur, total: totalDuration) {
                    container.addSublayer(l)
                }
            case .gauge:
                container.addSublayer(tileGaugeLayer(segs.first, frame: frame))   // the centered number is a .hero slot
            default:
                for l in tileValueLayers(slot, segs: segs, frame: frame,
                                         slotStartSec: slotStartSec, slotDur: slotDur, total: totalDuration) {
                    container.addSublayer(l)
                }
            }
        }

        // A per-clip tile shows only during its own slot (skip the gate for a whole-timeline tile).
        if let slotDurationSec,
           !(slotStartSec <= 0.0001 && slotStartSec + slotDurationSec >= totalDuration - 0.0001) {
            gateSegmentOpacity(container, start: slotStartSec / totalDuration,
                               end: (slotStartSec + slotDurationSec) / totalDuration, totalDuration: totalDuration)
        }
        return container
    }

    /// Value text for a hero / field / chip slot: one text layer per display segment (a static metric
    /// is one always-on layer; an animated live metric cross-fades per-value layers, opacity-gated to
    /// each reading's window mapped onto the clip slot). A caption (`metric.tileCaption`) is drawn under
    /// the value when the slot has room.
    private static func tileValueLayers(_ slot: HRTileLayout.MetricSlot, segs: [HROverlayValues.Segment],
                                        frame: CGRect, slotStartSec: Double, slotDur: Double,
                                        total: Double) -> [CALayer] {
        let captionH = slot.showsLabel ? min(frame.height * 0.34, slot.fontSize * 0.7) : 0
        // Bottom-left space: caption at the bottom (lower y), value above it.
        let valueRect = CGRect(x: frame.minX, y: frame.minY + captionH,
                               width: frame.width, height: frame.height - captionH)
        var layers: [CALayer] = []
        let single = segs.count <= 1
        for seg in segs {
            let label = plainTextLayer(seg.reading.text, color: uiColor(seg.reading.hex),
                                       fontSize: slot.fontSize, weight: slot.role == .hero ? .heavy : .semibold,
                                       align: slot.align, in: valueRect, shadow: true)
            if single { label.opacity = 1 } else {
                gateSegmentOpacity(label, start: (slotStartSec + seg.start * slotDur) / total,
                                   end: (slotStartSec + seg.end * slotDur) / total, totalDuration: total)
            }
            layers.append(label)
        }
        if captionH > 0 {
            let capRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: captionH)
            let cap = plainTextLayer(slot.metric.tileCaption, color: UIColor.white.withAlphaComponent(0.75),
                                     fontSize: max(8, slot.fontSize * 0.42), weight: .medium,
                                     align: slot.align, in: capRect, shadow: true)
            cap.opacity = 1
            layers.append(cap)
        }
        return layers
    }

    /// A zone pill: a rounded capsule filled with the (zone) colour, white text centered, one per
    /// segment (cross-faded for an animated live zone).
    private static func tilePillLayers(_ segs: [HROverlayValues.Segment], frame: CGRect, fontSize: CGFloat,
                                       slotStartSec: Double, slotDur: Double, total: Double) -> [CALayer] {
        let single = segs.count <= 1
        return segs.map { seg in
            let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let attr = NSAttributedString(string: seg.reading.text,
                                          attributes: [.font: font, .foregroundColor: UIColor.white])
            let ts = attr.size()
            let pad = fontSize * 0.5
            let pw = min(frame.width, ceil(ts.width) + 2 * pad)
            let ph = min(frame.height, ceil(ts.height) + fontSize * 0.4)
            let pill = CALayer()
            pill.frame = CGRect(x: frame.midX - pw / 2, y: frame.midY - ph / 2, width: pw, height: ph)
            pill.backgroundColor = uiColor(seg.reading.hex).withAlphaComponent(0.95).cgColor
            pill.cornerRadius = ph / 2
            let label = CATextLayer()
            label.string = attr; label.contentsScale = 2; label.alignmentMode = .center
            label.frame = CGRect(x: pad, y: (ph - ceil(ts.height)) / 2, width: pw - 2 * pad, height: ceil(ts.height))
            pill.addSublayer(label)
            if single { pill.opacity = 1 } else {
                gateSegmentOpacity(pill, start: (slotStartSec + seg.start * slotDur) / total,
                                   end: (slotStartSec + seg.end * slotDur) / total, totalDuration: total)
            }
            return pill
        }
    }

    /// A decorative gauge ring (the %HRR arc) coloured by the current zone — the centered bpm number
    /// (a separate `.hero` slot) is the value of record, so the ring is a full coloured stroke.
    private static func tileGaugeLayer(_ seg: HROverlayValues.Segment?, frame: CGRect) -> CALayer {
        let ring = CAShapeLayer()
        ring.frame = frame
        let lw = max(3, frame.width * 0.08)
        let path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: lw / 2 + 1, dy: lw / 2 + 1))
        ring.path = path.cgPath
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = uiColor(seg?.reading.hex ?? "#FF3B30").cgColor
        ring.lineWidth = lw
        ring.opacity = 1
        return ring
    }

    /// The tile's chart register: the HR polyline + an animated playhead dot drawn inside `localRect`
    /// (bottom-left, inside the tile container). Reuses the chart's strictly-increasing-keyTimes dot
    /// animation; the dot sweeps over the clip's slot.
    private static func tileChartLayer(samples: [HRPoint], localRect outer: CGRect, zoneColored: Bool,
                                       totalDuration: Double, slotStartSec: Double, slotDurationSec: Double) -> CALayer {
        let container = CALayer(); container.frame = outer
        let rect = container.bounds.insetBy(dx: 4, dy: 4)
        let pts = HRChartGeometry.normalizedPoints(samples)
        func local(_ n: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height)   // n.y=1 → top (bottom-left)
        }
        let lineColor = zoneColored ? UIColor(HeartRateZone.forBpm(averageBPM(samples)).color)
                                    : UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
        let path = CGMutablePath()
        if let f = pts.first { path.move(to: local(f)); for q in pts.dropFirst() { path.addLine(to: local(q)) } }
        let line = CAShapeLayer()
        line.frame = container.bounds; line.path = path
        line.strokeColor = lineColor.cgColor; line.fillColor = UIColor.clear.cgColor
        line.lineWidth = 2; line.lineJoin = .round
        container.addSublayer(line)

        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8); dot.cornerRadius = 4
        dot.backgroundColor = UIColor.white.cgColor
        if !pts.isEmpty {
            var values: [NSValue] = [], keyTimes: [NSNumber] = []
            var last = -1.0; let eps = 1e-4
            for p in pts {
                let kt = min(1, max(0, p.x))
                if kt > last + eps { values.append(NSValue(cgPoint: local(p))); keyTimes.append(NSNumber(value: kt)); last = kt }
            }
            if keyTimes.count >= 2 {
                keyTimes[0] = 0; keyTimes[keyTimes.count - 1] = 1
                let anim = CAKeyframeAnimation(keyPath: "position")
                anim.values = values; anim.keyTimes = keyTimes; anim.calculationMode = .linear
                anim.beginTime = AVCoreAnimationBeginTimeAtZero + slotStartSec
                anim.duration = max(0.01, slotDurationSec)
                anim.isRemovedOnCompletion = false; anim.fillMode = .both
                dot.position = local(pts[0]); dot.add(anim, forKey: "hrPlayhead")
            } else { dot.position = local(pts[0]) }
        }
        container.addSublayer(dot)
        return container
    }

    /// A single positioned text layer: measured, aligned within `rect` (bottom-left space), vertically
    /// centered, optionally drop-shadowed for legibility over footage.
    private static func plainTextLayer(_ text: String, color: UIColor, fontSize: CGFloat,
                                       weight: UIFont.Weight, align: HRTileLayout.TextAlign,
                                       in rect: CGRect, shadow: Bool) -> CATextLayer {
        let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        let tw = min(rect.width, ceil(size.width)), th = ceil(size.height)
        let x: CGFloat
        switch align {
        case .leading:  x = rect.minX
        case .center:   x = rect.midX - tw / 2
        case .trailing: x = rect.maxX - tw
        }
        let label = CATextLayer()
        label.string = attr
        label.contentsScale = 2
        label.isWrapped = false
        label.truncationMode = .end
        label.alignmentMode = align == .leading ? .left : (align == .trailing ? .right : .center)
        label.frame = CGRect(x: x, y: rect.midY - th / 2, width: tw, height: th)
        if shadow {
            label.shadowColor = UIColor.black.cgColor; label.shadowOpacity = 0.7
            label.shadowRadius = 3; label.shadowOffset = .zero
        }
        return label
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

    /// A **styled text / climb-name** overlay: an `NSAttributedString` `CATextLayer` (font preset +
    /// weight/italic + colour) WRAPPED to ~0.9 of the canvas width, with the box height measured from the
    /// wrapped text (`boundingRect`) so multi-line captions never clip — the same wrap the SwiftUI
    /// preview does, so preview == file. An optional highlight container backs the text (climb-name
    /// seeds a dark default); without a highlight the text gets a drop shadow to stay legible. Returns
    /// the container so `applyVisibility` time-gates the whole chip.
    private static func styledTextLayer(for overlay: OverlayItem, canvas: CGSize,
                                        fontFraction: CGFloat, defaultHighlight: String?) -> CALayer {
        let fontSize = max(8, canvas.height * fontFraction * overlay.scale)
        let font = uiFont(overlay, size: fontSize)
        let hPad: CGFloat = 12, vPad: CGFloat = 6
        let maxTextW = canvas.width * 0.9 - 2 * hPad

        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attributed = NSAttributedString(string: overlay.content, attributes: [
            .font: font, .foregroundColor: uiColor(overlay.colorHex), .paragraphStyle: para])
        let bounding = attributed.boundingRect(
            with: CGSize(width: maxTextW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let textW = min(maxTextW, ceil(bounding.width)), textH = ceil(bounding.height)
        let boxW = textW + 2 * hPad, boxH = textH + 2 * vPad
        let center = ClipEditGeometry.layerPoint(normalized: overlay.position, in: canvas)

        let container = CALayer()
        container.frame = CGRect(x: center.x - boxW / 2, y: center.y - boxH / 2, width: boxW, height: boxH)
        let highlight = overlay.highlightHex ?? defaultHighlight
        if let highlight {
            container.backgroundColor = uiColor(highlight).withAlphaComponent(0.55).cgColor
            container.cornerRadius = 8
        }

        let text = CATextLayer()
        text.string = attributed
        text.isWrapped = true
        text.contentsScale = 2
        text.frame = CGRect(x: hPad, y: vPad, width: textW, height: textH)
        if highlight == nil {   // legible over footage without a background
            text.shadowColor = UIColor.black.cgColor; text.shadowOpacity = 0.6
            text.shadowRadius = 3; text.shadowOffset = .zero
        }
        container.addSublayer(text)

        if abs(overlay.rotationDegrees) > 0.01 {
            container.transform = CATransform3DMakeRotation(CGFloat(overlay.rotationDegrees) * .pi / 180, 0, 0, 1)
        }
        return container
    }

    /// Resolve an overlay's font preset + bold/italic into a `UIFont` (design family + symbolic traits)
    /// — the export twin of `StudioFont.swiftUIDesign`.
    private static func uiFont(_ overlay: OverlayItem, size: CGFloat) -> UIFont {
        let design: UIFontDescriptor.SystemDesign
        switch overlay.font {
        case .system: design = .default
        case .rounded: design = .rounded
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        let base = UIFont.systemFont(ofSize: size, weight: overlay.bold ? .bold : .regular)
        var desc = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
        var traits: UIFontDescriptor.SymbolicTraits = []
        if overlay.bold { traits.insert(.traitBold) }
        if overlay.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let t = desc.withSymbolicTraits(traits) { desc = t }
        return UIFont(descriptor: desc, size: size)
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
