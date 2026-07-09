import AVFoundation
import QuartzCore
import UIKit
import SwiftUI
import CoreText

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
/// session-wide `(hrSamples, hrTile)` pair. `samples` are already sliced to the clip's capture window
/// and rebased to clip-local time (`StudioHRPlacement` + `HRWindowSlicer`); the chart normalizes its own
/// x-axis, so only the relative shape matters. `Sendable` so it crosses into the AVFoundation export actor.
struct PlacedClipHR: Sendable, Equatable {
    var startSec: Double          // clip's start on the output timeline
    var durationSec: Double       // clip's output (trim+speed) length
    var samples: [HRPoint]
    /// The resolved HR stat **tile** for this clip — one composite tile drawn at the clip's slot.
    var tile: ResolvedHRTile? = nil
}

enum StudioOverlays {

    /// `clipHR` (non-empty for the **multi-clip Studio**) draws each clip's own capture-window HR stat
    /// tile at the clip's slot — superseding the session-wide `hrTile` (the fallback when `clipHR` is
    /// empty). This is the fix for the Studio drawing the whole session's HR across the concatenated
    /// composition.
    static func makeAnimationTool(overlays: [OverlayItem], canvas: CGSize, totalDuration: Double,
                                  hrSamples: [HRPoint] = [],
                                  hrTile: ResolvedHRTile? = nil,
                                  clipHR: [PlacedClipHR] = [])
        -> AVVideoCompositionCoreAnimationTool? {
        // `.video` overlays are PiP video tracks (handled by the composer), NOT Core Animation layers.
        let visible = overlays.filter { !$0.content.isEmpty && $0.kind != .video }
        let perClip = !clipHR.isEmpty
        let hasTile = perClip ? clipHR.contains { $0.tile != nil } : (hrTile != nil)
        guard (!visible.isEmpty || hasTile),
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
            // Multi-clip Studio: one HR stat tile PER clip, placed/gated to its own slot so it shows that
            // clip's capture-window HR (not the whole session across the composition).
            for clip in clipHR {
                if let tile = clip.tile,
                   let layer = hrTileLayer(tile, samples: clip.samples, canvas: canvas,
                                           totalDuration: totalDuration,
                                           slotStartSec: clip.startSec, slotDurationSec: clip.durationSec) {
                    overlayLayer.addSublayer(layer)
                }
            }
        } else if let hrTile,
                  let layer = hrTileLayer(hrTile, samples: hrSamples, canvas: canvas, totalDuration: totalDuration) {
            // Session-wide tile (the fallback path for clips with no media link).
            overlayLayer.addSublayer(layer)
        }
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlayLayer)
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    /// Opacity-gate a layer to its `[start, end]` fraction window (at visible `level`). A full-clip
    /// `[0,1]` segment stays fully visible; a sub-window appears/disappears on cue (per-clip gating, the
    /// animated-live cross-fade for a tile's live metric, and the whole-tile opacity).
    private static func gateSegmentOpacity(_ layer: CALayer, start: Double, end: Double,
                                           totalDuration: Double, level: Float = 1) {
        if start <= 0.0001 && end >= 0.9999 { layer.opacity = level; return }   // static → always on (at `level`)
        let s = min(1, max(0, start)), e = min(1, max(s, end))
        layer.opacity = 0
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        // 0 before the window, `level` across it, 0 after — tiny epsilons keep keyTimes strictly increasing.
        let eps = 1e-4
        anim.values = [0, 0, level, level, 0] as [Float]
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

        // The "Glass HUD" panel (issue #163): the kit's translucent fill (doubles as the legibility
        // scrim — the export can't live-blur the footage), a hairline edge, and a soft drop shadow. Same
        // hex/alpha + fraction-based radius the SwiftUI preview uses, so the two match.
        let radius = HRTileStyle.tileRadius(w: w, h: h)
        let glass = CALayer()
        glass.frame = container.bounds
        glass.backgroundColor = uiColor(HRTileStyle.glassFillHex)
            .withAlphaComponent(HRTileStyle.glassFillAlpha).cgColor
        glass.cornerRadius = radius
        glass.borderColor = uiColor(HRTileStyle.hairlineHex)
            .withAlphaComponent(HRTileStyle.hairlineAlpha).cgColor
        glass.borderWidth = 1
        container.addSublayer(glass)
        container.shadowColor = UIColor.black.cgColor
        container.shadowOpacity = Float(HRTileStyle.shadowAlpha)
        container.shadowRadius = radius * 0.45
        container.shadowOffset = .zero

        // Flip a top-left local frame (HRTileLayout space) into the container's bottom-left space.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }

        let slotDur = slotDurationSec ?? totalDuration
        let segByMetric = Dictionary(tile.metrics.map { ($0.metric, $0.segments) }, uniquingKeysWith: { a, _ in a })

        // Template chrome (Broadcast accent bar / Gradient Strain skin), behind the content. Coloured by
        // the clip's OVERALL zone (average bpm) — static, matching the preview's `chromeZoneHex`, so it
        // doesn't flicker (the live tracking is the hero/pill/zone-bar/gauge/dot).
        let avg = averageBPM(samples)
        let zoneHex = avg > 0 ? HeartRateZone.forBpm(avg, maxHR: tile.maxHR).colorHex : HeartRateZone.aerobic.colorHex
        for d in result.decorations {
            container.addSublayer(tileDecorationLayer(d, frame: flip(d.frame), zoneHex: zoneHex, tileRadius: radius))
        }

        if tile.showChart, let chartRect = result.chartRect, samples.count >= 2 {
            container.addSublayer(tileChartLayer(samples: samples, maxHR: tile.maxHR,
                                                 localRect: flip(chartRect), zoneColored: tile.zoneColored,
                                                 sparkline: chartRect.height < h * 0.30,
                                                 totalDuration: totalDuration,
                                                 slotStartSec: slotStartSec, slotDurationSec: slotDur,
                                                 window: tile.window))
        }

        for slot in result.slots {
            guard let segs = segByMetric[slot.metric], !segs.isEmpty else { continue }
            let frame = flip(slot.frame)
            switch slot.role {
            case .pill:
                for l in tilePillLayers(segs, frame: frame, fontSize: slot.fontSize, align: slot.align,
                                        slotStartSec: slotStartSec, slotDur: slotDur, total: totalDuration) {
                    container.addSublayer(l)
                }
            case .gauge:
                container.addSublayer(tileGaugeLayer(segs, frame: frame,
                                                     slotStartSec: slotStartSec, slotDur: slotDur, total: totalDuration))
            case .zoneBar:
                container.addSublayer(tileZoneBarLayer(segs, frame: frame, vertical: slot.zoneBarVertical,
                                                       slotStartSec: slotStartSec, slotDur: slotDur, total: totalDuration))
            default:
                for l in tileValueLayers(slot, segs: segs, frame: frame,
                                         slotStartSec: slotStartSec, slotDur: slotDur, total: totalDuration) {
                    container.addSublayer(l)
                }
            }
        }

        // Whole-tile opacity the user dialed (clamped to the legible floor) — composed with the per-clip
        // gate so a gated tile shows at `opacityF` during its slot and a whole-timeline tile holds it.
        let opacityF = Float(min(1, max(HRTile.minOpacity, tile.opacity)))
        if let slotDurationSec,
           !(slotStartSec <= 0.0001 && slotStartSec + slotDurationSec >= totalDuration - 0.0001) {
            gateSegmentOpacity(container, start: slotStartSec / totalDuration,
                               end: (slotStartSec + slotDurationSec) / totalDuration,
                               totalDuration: totalDuration, level: opacityF)
        } else {
            container.opacity = opacityF
        }
        return container
    }

    /// Value text for a hero / field / chip slot (issue #163), the export twin of `HRTileView`'s
    /// `heroValue` / `chip` / `field`: value-only strings with the uppercase caption (`metric.tileCaption`)
    /// supplying the label, drawn in the kit's tabular rounded font. One text layer per display segment
    /// (a static metric is one always-on layer; an animated live metric cross-fades per-value layers,
    /// opacity-gated to each reading's window mapped onto the clip slot). Decorations (chip bg, caption)
    /// are static; only the value cross-fades.
    private static func tileValueLayers(_ slot: HRTileLayout.MetricSlot, segs: [HROverlayValues.Segment],
                                        frame: CGRect, slotStartSec: Double, slotDur: Double,
                                        total: Double) -> [CALayer] {
        var layers: [CALayer] = []
        let single = segs.count <= 1
        func gate(_ l: CALayer, _ seg: HROverlayValues.Segment) {
            if single { l.opacity = 1 } else {
                gateSegmentOpacity(l, start: (slotStartSec + seg.start * slotDur) / total,
                                   end: (slotStartSec + seg.end * slotDur) / total, totalDuration: total)
            }
        }

        switch slot.role {
        case .hero:
            for seg in segs { let g = heroGroupLayer(seg.reading, frame: frame, fontSize: slot.fontSize, align: slot.align); gate(g, seg); layers.append(g) }

        case .chip:
            let bg = CALayer(); bg.frame = frame; bg.opacity = 1
            bg.backgroundColor = uiColor(HRTileStyle.chipFillHex).withAlphaComponent(HRTileStyle.chipFillAlpha).cgColor
            bg.cornerRadius = HRTileStyle.chipRadius(h: frame.height)
            layers.append(bg)
            // Bottom-left: caption at the TOP (higher y), value below it.
            let capH = slot.showsLabel ? frame.height * 0.34 : 0
            if capH > 0 {
                let capRect = CGRect(x: frame.minX, y: frame.maxY - capH, width: frame.width, height: capH)
                let cap = plainTextLayer(slot.metric.tileCaption.uppercased(), color: heroWhite(HRTileStyle.captionAlpha),
                                         fontSize: slot.fontSize * 0.62, weight: .semibold, align: .center, in: capRect, shadow: false)
                cap.opacity = 1; layers.append(cap)
            }
            let valRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - capH)
            for seg in segs {
                let v = plainTextLayer(seg.reading.value, color: valueColorUI(slot.metric, seg.reading),
                                       fontSize: slot.fontSize, weight: .bold, align: .center, in: valRect, shadow: false)
                gate(v, seg); layers.append(v)
            }

        case .field where slot.showsLabel && slot.align == .leading:
            // Label-column (leading) + value-column (trailing) so the value can't collide with its label.
            let capRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width * 0.5, height: frame.height)
            let cap = plainTextLayer(slot.metric.tileCaption.uppercased(), color: heroWhite(HRTileStyle.captionAlpha),
                                     fontSize: slot.fontSize * 0.62, weight: .semibold, align: .leading, in: capRect, shadow: true)
            cap.opacity = 1; layers.append(cap)
            for seg in segs {
                let v = valueUnitLayer(seg.reading, color: valueColorUI(slot.metric, seg.reading),
                                       fontSize: slot.fontSize, align: .trailing, in: frame)
                gate(v, seg); layers.append(v)
            }

        default:   // stacked value (caption under it, centred) or value-only
            let capH = slot.showsLabel ? frame.height * 0.32 : 0
            let valRect = CGRect(x: frame.minX, y: frame.minY + capH, width: frame.width, height: frame.height - capH)
            for seg in segs {
                let v = valueUnitLayer(seg.reading, color: valueColorUI(slot.metric, seg.reading),
                                       fontSize: slot.fontSize, align: slot.align, in: valRect)
                gate(v, seg); layers.append(v)
            }
            if capH > 0 {
                let capRect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: capH)
                let cap = plainTextLayer(slot.metric.tileCaption.uppercased(), color: heroWhite(HRTileStyle.captionAlpha),
                                         fontSize: slot.fontSize * 0.62, weight: .semibold, align: slot.align, in: capRect, shadow: true)
                cap.opacity = 1; layers.append(cap)
            }
        }
        return layers
    }

    /// The hero number: a near-white value + a small inline unit ("156" + "BPM"), bottom-aligned so they
    /// share a baseline. Grouped in one layer so a live-bpm cross-fade gates the value+unit together.
    private static func heroGroupLayer(_ reading: HROverlayValues.Reading, frame: CGRect,
                                       fontSize: CGFloat, align: HRTileLayout.TextAlign) -> CALayer {
        let group = CALayer(); group.frame = frame
        let valFont = tileFont(size: fontSize, weight: .heavy)
        let valAttr = NSAttributedString(string: reading.value, attributes: [.font: valFont, .foregroundColor: heroWhite()])
        let vs = valAttr.size()
        let unitFont = tileFont(size: fontSize * 0.34, weight: .bold)
        let unitAttr = reading.unit.map {
            NSAttributedString(string: $0, attributes: [.font: unitFont, .foregroundColor: heroWhite(HRTileStyle.captionAlpha)])
        }
        let us = unitAttr?.size() ?? .zero
        let gap = fontSize * 0.08
        let vw = min(vs.width, frame.width)
        let totalW = min(frame.width, vw + (unitAttr != nil ? gap + us.width : 0))
        let startX: CGFloat
        switch align { case .leading: startX = 0; case .trailing: startX = frame.width - totalW; case .center: startX = (frame.width - totalW) / 2 }
        let valY = (frame.height - vs.height) / 2
        let vl = CATextLayer(); vl.string = valAttr; vl.contentsScale = 2; vl.isWrapped = false; vl.alignmentMode = .left
        vl.frame = CGRect(x: startX, y: valY, width: vw, height: vs.height)
        applyTextShadow(vl); group.addSublayer(vl)
        if let unitAttr {
            let ul = CATextLayer(); ul.string = unitAttr; ul.contentsScale = 2; ul.isWrapped = false; ul.alignmentMode = .left
            ul.frame = CGRect(x: startX + vw + gap, y: valY, width: us.width, height: us.height)   // bottom-aligned ≈ shared baseline
            applyTextShadow(ul); group.addSublayer(ul)
        }
        return group
    }

    /// A field value + a SMALL inline unit (the unit at 0.5× the value, matching `HRTileView.field`'s
    /// preview — not a same-size concatenation), measured & aligned in `rect`. Grouped so a live cross-fade
    /// gates value+unit together.
    private static func valueUnitLayer(_ reading: HROverlayValues.Reading, color: UIColor,
                                       fontSize: CGFloat, align: HRTileLayout.TextAlign, in rect: CGRect) -> CALayer {
        let group = CALayer(); group.frame = rect
        let valFont = tileFont(size: fontSize, weight: .bold)
        let valAttr = NSAttributedString(string: reading.value, attributes: [.font: valFont, .foregroundColor: color])
        let vs = valAttr.size()
        let unitFont = tileFont(size: fontSize * 0.5, weight: .semibold)
        let unitAttr = reading.unit.map {
            NSAttributedString(string: $0, attributes: [.font: unitFont, .foregroundColor: heroWhite(HRTileStyle.captionAlpha)])
        }
        let us = unitAttr?.size() ?? .zero
        let gap = fontSize * 0.1
        let vw = min(vs.width, rect.width)
        let totalW = min(rect.width, vw + (unitAttr != nil ? gap + us.width : 0))
        let startX: CGFloat
        switch align { case .leading: startX = 0; case .trailing: startX = rect.width - totalW; case .center: startX = (rect.width - totalW) / 2 }
        let valY = (rect.height - vs.height) / 2
        let vl = CATextLayer(); vl.string = valAttr; vl.contentsScale = 2; vl.isWrapped = false; vl.alignmentMode = .left
        vl.truncationMode = .end
        vl.frame = CGRect(x: startX, y: valY, width: vw, height: vs.height)
        applyTextShadow(vl); group.addSublayer(vl)
        if let unitAttr {
            let ul = CATextLayer(); ul.string = unitAttr; ul.contentsScale = 2; ul.isWrapped = false; ul.alignmentMode = .left
            ul.frame = CGRect(x: startX + vw + gap, y: valY, width: us.width, height: us.height)   // bottom-aligned ≈ shared baseline
            applyTextShadow(ul); group.addSublayer(ul)
        }
        return group
    }

    private static func heroWhite(_ alpha: CGFloat = 1) -> UIColor {
        uiColor(HRTileStyle.heroTextHex).withAlphaComponent(alpha)
    }
    /// Accent colour for a value: zone/semantic hue for the live-intensity metrics, near-white for the
    /// aggregates (the `decisions.md` rule, refreshed for the value-only chips).
    private static func valueColorUI(_ m: HROverlayMetric, _ r: HROverlayValues.Reading) -> UIColor {
        switch m {
        case .zone, .hrr, .redline, .recovery: return uiColor(r.hex)
        default: return heroWhite(HRTileStyle.valueAlpha)
        }
    }

    /// The kit's **tabular rounded** font (SF Rounded + monospaced figures) — the export's missing-tabular
    /// fix (a top on-device crop cause): tabular digits don't reflow/clip as the value changes.
    private static func tileFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        var desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let tabular: [UIFontDescriptor.FeatureKey: Int] = [.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector]
        desc = desc.addingAttributes([.featureSettings: [tabular]])
        return UIFont(descriptor: desc, size: size)
    }

    /// The zone pill (issue #163): a zone-tinted glass capsule with a leading zone **dot** + zone-coloured
    /// uppercase label — the export twin of `HRTileView.zonePill`. One per segment (cross-faded for an
    /// animated live zone). Aligned within its slot per `align` (leading on the hero card; centred on the pill).
    private static func tilePillLayers(_ segs: [HROverlayValues.Segment], frame: CGRect, fontSize: CGFloat,
                                       align: HRTileLayout.TextAlign, slotStartSec: Double, slotDur: Double,
                                       total: Double) -> [CALayer] {
        let single = segs.count <= 1
        return segs.map { seg in
            let zone = uiColor(seg.reading.hex)
            let font = tileFont(size: fontSize, weight: .bold)
            let attr = NSAttributedString(string: seg.reading.value.uppercased(),
                                          attributes: [.font: font, .foregroundColor: zone])
            let ts = attr.size()
            let dotD = fontSize * 0.42, dotGap = fontSize * 0.34, hPad = fontSize * 0.6
            let textW = min(ceil(ts.width), frame.width - 2 * hPad - dotD - dotGap)
            let pw = min(frame.width, dotD + dotGap + textW + 2 * hPad)
            let ph = min(frame.height, ceil(ts.height) + fontSize * 0.56)
            let px: CGFloat
            switch align { case .leading: px = frame.minX; case .trailing: px = frame.maxX - pw; case .center: px = frame.midX - pw / 2 }
            let pill = CALayer()
            pill.frame = CGRect(x: px, y: frame.midY - ph / 2, width: pw, height: ph)
            pill.backgroundColor = zone.withAlphaComponent(0.16).cgColor
            pill.cornerRadius = ph / 2
            pill.borderColor = zone.withAlphaComponent(0.35).cgColor; pill.borderWidth = 1
            let dot = CALayer()
            dot.frame = CGRect(x: hPad, y: (ph - dotD) / 2, width: dotD, height: dotD)
            dot.cornerRadius = dotD / 2; dot.backgroundColor = zone.cgColor
            pill.addSublayer(dot)
            let label = CATextLayer()
            label.string = attr; label.contentsScale = 2; label.alignmentMode = .left; label.isWrapped = false
            label.truncationMode = .end
            label.frame = CGRect(x: hPad + dotD + dotGap, y: (ph - ceil(ts.height)) / 2, width: textW, height: ceil(ts.height))
            pill.addSublayer(label)
            if single { pill.opacity = 1 } else {
                gateSegmentOpacity(pill, start: (slotStartSec + seg.start * slotDur) / total,
                                   end: (slotStartSec + seg.end * slotDur) / total, totalDuration: total)
            }
            return pill
        }
    }

    /// The %HRR **sweep** gauge: a faint full-circle track + a zone-coloured arc revealed to the effort
    /// `fraction` (via `strokeEnd`), starting at the top — the export twin of `HRTileView.gauge`. The
    /// arc's extent AND colour **animate across the clip's segments** (keyframes) so the burned-in arc
    /// tracks the playhead like the live preview, not frozen at the clip start. The centred bpm hero is a
    /// separate `.hero` slot. (Sweep direction is a device-burn-in check, like all export visuals.)
    private static func tileGaugeLayer(_ segs: [HROverlayValues.Segment], frame: CGRect,
                                       slotStartSec: Double, slotDur: Double, total: Double) -> CALayer {
        let container = CALayer(); container.frame = frame
        let first = segs.first
        let color0 = uiColor(first?.reading.hex ?? "#FF3B30")
        let frac0 = CGFloat(max(0.02, min(1, first?.reading.fraction ?? 1)))
        let lw = max(3, frame.width * 0.09)
        let r = (min(frame.width, frame.height) - lw) / 2
        let c = CGPoint(x: frame.width / 2, y: frame.height / 2)

        let track = CAShapeLayer(); track.frame = container.bounds
        track.path = UIBezierPath(arcCenter: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        track.fillColor = UIColor.clear.cgColor; track.strokeColor = color0.withAlphaComponent(0.16).cgColor
        track.lineWidth = lw
        container.addSublayer(track)

        let sweep = CAShapeLayer(); sweep.frame = container.bounds
        // Start at the top (+y is up in the tool's bottom-left space) and reveal `frac` via strokeEnd.
        sweep.path = UIBezierPath(arcCenter: c, radius: r, startAngle: .pi / 2,
                                  endAngle: .pi / 2 - 2 * .pi, clockwise: false).cgPath
        sweep.fillColor = UIColor.clear.cgColor; sweep.strokeColor = color0.cgColor
        sweep.lineWidth = lw; sweep.lineCap = .round
        sweep.strokeStart = 0; sweep.strokeEnd = frac0
        sweep.shadowColor = color0.cgColor; sweep.shadowRadius = 3; sweep.shadowOpacity = 0.6; sweep.shadowOffset = .zero

        // Strictly-increasing keyTimes from the segment starts (mapped onto the clip slot).
        var kts: [NSNumber] = [], ends: [NSNumber] = [], cols: [CGColor] = []
        var last = -1.0; let eps = 1e-4
        for s in segs {
            let kt = min(1, max(0, (slotStartSec + s.start * slotDur) / total))
            if kt > last + eps {
                kts.append(NSNumber(value: kt))
                ends.append(NSNumber(value: Double(max(0.02, min(1, s.reading.fraction ?? 1)))))
                cols.append(uiColor(s.reading.hex).cgColor)
                last = kt
            }
        }
        if kts.count >= 2 {
            kts[0] = 0; kts[kts.count - 1] = 1
            func anim(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values; a.keyTimes = kts; a.calculationMode = .linear
                a.beginTime = AVCoreAnimationBeginTimeAtZero; a.duration = max(0.01, total)
                a.isRemovedOnCompletion = false; a.fillMode = .both
                return a
            }
            sweep.add(anim("strokeEnd", ends), forKey: "gaugeEnd")
            sweep.add(anim("strokeColor", cols), forKey: "gaugeColor")
            sweep.add(anim("shadowColor", cols), forKey: "gaugeGlow")
        }
        container.addSublayer(sweep)
        return container
    }

    /// The segmented zone bar — 5 cells (Z1…Z5) tinted their zone colours, dimmed, with the **current
    /// zone's** cell lit + glowing on top. The lit cell **animates across the clip's segments** (one
    /// opacity-gated overlay per zone segment), so it tracks the playhead like the live preview rather
    /// than freezing at the clip start. `vertical` (Rail, Z5 on top) vs horizontal (Broadcast, Z1→Z5
    /// left→right) is set explicitly by the template, never inferred from the slot aspect. Export twin of
    /// `HRTileView.zoneBar`.
    private static func tileZoneBarLayer(_ segs: [HROverlayValues.Segment], frame: CGRect, vertical: Bool,
                                         slotStartSec: Double, slotDur: Double, total: Double) -> CALayer {
        let container = CALayer(); container.frame = frame
        let n = 5, gap: CGFloat = 3
        func cellFrame(_ k: Int) -> CGRect {
            if vertical {
                let cellH = (frame.height - gap * CGFloat(n - 1)) / CGFloat(n)
                let y = frame.height - CGFloat(k + 1) * cellH - CGFloat(k) * gap   // bottom-left: k=0 → top
                return CGRect(x: 0, y: y, width: frame.width, height: cellH)
            } else {
                let cellW = (frame.width - gap * CGFloat(n - 1)) / CGFloat(n)
                return CGRect(x: CGFloat(k) * (cellW + gap), y: 0, width: cellW, height: frame.height)
            }
        }
        func cellIndex(forZone z: Int) -> Int { vertical ? (5 - z) : (z - 1) }   // bar position of zone z
        func zoneColor(_ z: Int) -> UIColor { uiColor((HeartRateZone(rawValue: z) ?? .aerobic).colorHex) }

        // Base dim cells (static).
        for k in 0..<n {
            let z = vertical ? (5 - k) : (k + 1)
            let cell = CALayer(); cell.frame = cellFrame(k); cell.cornerRadius = 2
            cell.backgroundColor = zoneColor(z).withAlphaComponent(0.22).cgColor
            container.addSublayer(cell)
        }
        // Lit overlay per zone segment, cross-faded.
        let single = segs.count <= 1
        for s in segs {
            let cur = HeartRateZone.zoneIndex(forColorHex: s.reading.hex)
            guard (1...5).contains(cur) else { continue }
            let color = zoneColor(cur)
            let lit = CALayer(); lit.frame = cellFrame(cellIndex(forZone: cur)); lit.cornerRadius = 2
            lit.backgroundColor = color.cgColor
            lit.shadowColor = color.cgColor; lit.shadowRadius = 2; lit.shadowOpacity = 0.7; lit.shadowOffset = .zero
            if single { lit.opacity = 1 } else {
                gateSegmentOpacity(lit, start: (slotStartSec + s.start * slotDur) / total,
                                   end: (slotStartSec + s.end * slotDur) / total, totalDuration: total)
            }
            container.addSublayer(lit)
        }
        return container
    }

    /// Template chrome (Broadcast accent bar / Gradient Strain skin), the export twin of
    /// `HRTileView.decoration`. The gradient skin is **horizontal** (cool → zone) so its orientation is
    /// flip-safe in the tool tree, matching the preview.
    private static func tileDecorationLayer(_ d: HRTileLayout.Decoration, frame: CGRect,
                                            zoneHex: String, tileRadius: CGFloat) -> CALayer {
        let zone = uiColor(zoneHex)
        switch d.kind {
        case .accentBar:
            let bar = CALayer(); bar.frame = frame
            bar.backgroundColor = zone.cgColor; bar.cornerRadius = frame.width / 2
            bar.shadowColor = zone.cgColor; bar.shadowRadius = 3; bar.shadowOpacity = 0.7; bar.shadowOffset = .zero
            return bar
        case .gradientSkin:
            let grad = CAGradientLayer(); grad.frame = frame
            grad.startPoint = CGPoint(x: 0, y: 0.5); grad.endPoint = CGPoint(x: 1, y: 0.5)
            grad.colors = [uiColor("#0E3A4A").withAlphaComponent(0.5).cgColor, zone.withAlphaComponent(0.5).cgColor]
            grad.cornerRadius = tileRadius
            return grad
        }
    }

    /// The tile's chart register — the premium **zone-banded HR trace** (issue #163), the export twin of
    /// the SwiftUI `PremiumHRCurve`. A smooth Catmull-Rom→bézier curve (the shared `HRChartGeometry` path,
    /// so the two sides draw the identical line) with a zone-coloured stroke gradient (a `CAGradientLayer`
    /// masked by the stroke shape — left→right, flip-safe), a flat zone area wash, a glow so it floats
    /// over footage, a baked peak label (full curve), and a glowing playhead dot that is **x-synced** to
    /// the playhead (position keyframes keyed by x = t/maxT, like the preview) and **recoloured** by the
    /// bpm under it (colour keyframes). The FULL curve draws (no `strokeEnd` draw-on) so the per-frame
    /// preview matches. `localRect` is bottom-left, inside the tile container.
    private static func tileChartLayer(samples: [HRPoint], maxHR: Double, localRect outer: CGRect,
                                       zoneColored: Bool, sparkline: Bool, totalDuration: Double,
                                       slotStartSec: Double, slotDurationSec: Double,
                                       window: HRClipWindow? = nil) -> CALayer {
        let container = CALayer(); container.frame = outer
        let rect = container.bounds          // no inset — the preview maps into the full chart rect too (WYSIWYG)
        // Draw from the SAME dense resampled series the preview's `PremiumHRCurve` uses (prompt 101), so
        // the burned-in curve + gliding dot match. Aggregates (peak label / glow zone) stay on RAW samples.
        let chart = HRChartGeometry.displaySeries(samples)
        let sparse = HRCadence.summarize(samples).isSparse(windowSec: samples.last?.t ?? 0)
        let pts = HRChartGeometry.normalizedPoints(chart)
        func local(_ n: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height)   // n.y=1 → top (bottom-left)
        }
        guard pts.count >= 2 else { return container }
        let mapped = pts.map(local)

        // Extended-window region panes (prompt 115, "Variant A"): faint tinted washes for the
        // off-camera lead/tail, a slightly brighter footage pane, and 1px ember boundary ticks — the
        // export twin of the preview's `HRWindowRegionPanes`. Behind the area/curve layers. The curve
        // stays full-strength everywhere: the HR data is real, only the camera coverage differs.
        if let window, window.isExtended, let maxT = chart.map(\.t).max(), maxT > 0 {
            let fs = window.footageStartFraction(maxT: maxT)
            let fe = window.footageEndFraction(maxT: maxT)
            for p in HRWindowRegionStyle.panes(footageStart: fs, footageEnd: fe) {
                let l = CALayer()
                l.frame = CGRect(x: rect.minX + p.from * rect.width, y: rect.minY,
                                 width: (p.to - p.from) * rect.width, height: rect.height)
                l.backgroundColor = uiColor(p.hex).withAlphaComponent(p.alpha).cgColor
                container.addSublayer(l)
            }
            for x in HRWindowRegionStyle.tickXs(footageStart: fs, footageEnd: fe) {
                let tick = CALayer()
                tick.frame = CGRect(x: rect.minX + x * rect.width - HRWindowRegionStyle.tickWidth / 2,
                                    y: rect.minY, width: HRWindowRegionStyle.tickWidth, height: rect.height)
                tick.backgroundColor = uiColor(HRWindowRegionStyle.tickHex)
                    .withAlphaComponent(HRWindowRegionStyle.tickAlpha).cgColor
                container.addSublayer(tick)
            }
        }
        let smooth = HRChartGeometry.smoothedPath(through: mapped)
        let lw: CGFloat = sparkline ? HRTileStyle.lineWidthSpark : HRTileStyle.lineWidthFull
        // Dashed for an interpolation-only window — the export twin of the preview's honest sparse styling.
        let dashPattern: [NSNumber]? = sparse ? [NSNumber(value: Double(lw * 2.2)), NSNumber(value: Double(lw * 1.8))] : nil
        let peakZone = HeartRateZone.forBpm(HRChartGeometry.peakBPM(samples), maxHR: maxHR)
        let glowColor = zoneColored ? uiColor(peakZone.colorHex) : uiColor("#FF3B30")

        // Area wash (flat, matches the preview's flat fill).
        let areaPath = CGMutablePath()
        areaPath.addPath(smooth)
        if let first = mapped.first, let last = mapped.last {
            areaPath.addLine(to: CGPoint(x: last.x, y: rect.minY))     // baseline (bottom in bottom-left)
            areaPath.addLine(to: CGPoint(x: first.x, y: rect.minY))
            areaPath.closeSubpath()
        }
        let area = CAShapeLayer()
        area.frame = container.bounds; area.path = areaPath
        area.fillColor = glowColor.withAlphaComponent(HRTileStyle.areaTopAlpha * (sparse ? 0.22 : 0.55)).cgColor
        area.strokeColor = UIColor.clear.cgColor
        container.addSublayer(area)

        // Glow underlay (blurred coloured stroke under the gradient stroke).
        let glow = CAShapeLayer()
        glow.frame = container.bounds; glow.path = smooth
        glow.strokeColor = glowColor.cgColor; glow.fillColor = UIColor.clear.cgColor
        glow.lineWidth = lw; glow.lineCap = sparse ? .butt : .round; glow.lineJoin = .round
        glow.lineDashPattern = dashPattern
        glow.opacity = sparse ? 0.7 : 1
        glow.shadowColor = glowColor.cgColor; glow.shadowRadius = sparkline ? 2 : 3
        glow.shadowOpacity = Float(HRTileStyle.curveGlowAlpha); glow.shadowOffset = .zero
        container.addSublayer(glow)

        // The zone-banded stroke: a horizontal gradient masked by the stroke shape (left→right is
        // flip-safe). Flat colour when zoneColored is off or there aren't enough stops.
        let strokeMask = CAShapeLayer()
        strokeMask.frame = container.bounds; strokeMask.path = smooth
        strokeMask.strokeColor = UIColor.black.cgColor; strokeMask.fillColor = UIColor.clear.cgColor
        strokeMask.lineWidth = lw; strokeMask.lineCap = sparse ? .butt : .round; strokeMask.lineJoin = .round
        strokeMask.lineDashPattern = dashPattern
        let stops = zoneColored ? HRChartGeometry.zoneStops(chart, maxHR: maxHR) : []
        if stops.count >= 2 {
            let grad = CAGradientLayer()
            grad.frame = container.bounds
            grad.startPoint = CGPoint(x: 0, y: 0.5); grad.endPoint = CGPoint(x: 1, y: 0.5)
            grad.colors = stops.map { uiColor($0.hex).cgColor }
            grad.locations = stops.map { NSNumber(value: $0.location) }
            grad.mask = strokeMask
            container.addSublayer(grad)
        } else {
            strokeMask.strokeColor = uiColor(zoneColored ? peakZone.colorHex : "#FF3B30").cgColor
            container.addSublayer(strokeMask)
        }

        // Baked peak label above the hump (full curve only — CA can't redraw text per frame). Its centre
        // sits 0.18·height above the peak, matching `HRTileView`'s `h * 0.18` so preview == export.
        if !sparkline, let pk = HRChartGeometry.peakIndex(pts), let peak = HRChartGeometry.peakBPM(samples) {
            let f = max(9, rect.height * 0.16)
            let center = min(rect.maxY - f / 2, mapped[pk].y + rect.height * 0.18)
            let label = plainTextLayer("\(Int(peak.rounded()))", color: UIColor.white.withAlphaComponent(0.9),
                                       fontSize: f, weight: .bold, align: .center,
                                       in: CGRect(x: mapped[pk].x - f * 1.5, y: center - f / 2,
                                                  width: f * 3, height: f), shadow: true)
            container.addSublayer(label)
        }

        // Glowing playhead dot, time-synced by x (= t/maxT, the same fraction the preview uses) and
        // recoloured by the bpm UNDER the dot — both via x-keyed keyframes, so the burned-in dot tracks
        // the same point AND the same zone colour the preview's live dot shows (preview == export). The
        // white disc is static; the halo (the dot's own bg) + the core animate their colour.
        // Key off the SAME dense `chart` series `pts` came from, so dot index ↔ bpm stay aligned (and the
        // dot glides + recolours smoothly, matching the preview).
        // Keyframes from the shared pure mapping (prompt 115): identity without an extended window
        // (dot sweeps the whole chart, keyTime = x); with one, the dot enters at the lead/footage
        // boundary, sweeps only the footage span, and PARKS at the footage/tail boundary — the tail
        // (where the off-camera peak lives) stays drawn but is never swept.
        let keys = HRChartGeometry.playheadKeyframes(chart, window: window)
        let halo = sparkline ? 11.0 : 16.0, white = sparkline ? 7.0 : 10.0, core = sparkline ? 4.0 : 6.0
        func dotColor(_ bpm: Double) -> UIColor {
            zoneColored ? uiColor(HeartRateZone.forBpm(bpm, maxHR: maxHR).colorHex) : uiColor("#FF3B30")
        }
        // Strictly-increasing keyTimes (drop duplicates so CA keeps the animation).
        var positions: [NSValue] = [], haloColors: [CGColor] = [], coreColors: [CGColor] = [], keyTimes: [NSNumber] = []
        var last = -1.0; let eps = 1e-4
        for k in keys {
            let kt = min(1, max(0, k.keyTime))
            if kt > last + eps {
                positions.append(NSValue(cgPoint: local(CGPoint(x: k.x, y: k.y))))
                let c = dotColor(k.bpm)
                haloColors.append(c.withAlphaComponent(0.35).cgColor); coreColors.append(c.cgColor)
                keyTimes.append(NSNumber(value: kt)); last = kt
            }
        }
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: halo, height: halo); dot.cornerRadius = halo / 2
        dot.backgroundColor = haloColors.first ?? UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 0.35).cgColor
        let whiteDisc = CALayer()
        whiteDisc.frame = CGRect(x: (halo - white) / 2, y: (halo - white) / 2, width: white, height: white)
        whiteDisc.cornerRadius = white / 2; whiteDisc.backgroundColor = UIColor.white.cgColor
        dot.addSublayer(whiteDisc)
        let coreDisc = CALayer()
        coreDisc.frame = CGRect(x: (halo - core) / 2, y: (halo - core) / 2, width: core, height: core)
        coreDisc.cornerRadius = core / 2; coreDisc.backgroundColor = coreColors.first ?? UIColor.white.cgColor
        dot.addSublayer(coreDisc)
        dot.position = keys.first.map { local(CGPoint(x: $0.x, y: $0.y)) } ?? mapped[0]
        if keyTimes.count >= 2 {
            keyTimes[0] = 0; keyTimes[keyTimes.count - 1] = 1
            func keyed(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values; a.keyTimes = keyTimes; a.calculationMode = .linear
                a.beginTime = AVCoreAnimationBeginTimeAtZero + slotStartSec
                a.duration = max(0.01, slotDurationSec); a.isRemovedOnCompletion = false; a.fillMode = .both
                return a
            }
            dot.add(keyed("position", positions), forKey: "hrPlayheadPos")
            if zoneColored {
                dot.add(keyed("backgroundColor", haloColors), forKey: "hrPlayheadHalo")
                coreDisc.add(keyed("backgroundColor", coreColors), forKey: "hrPlayheadCore")
            }
        }
        container.addSublayer(dot)
        return container
    }

    /// A single positioned text layer: measured, aligned within `rect` (bottom-left space), vertically
    /// centered, optionally drop-shadowed for legibility over footage.
    private static func plainTextLayer(_ text: String, color: UIColor, fontSize: CGFloat,
                                       weight: UIFont.Weight, align: HRTileLayout.TextAlign,
                                       in rect: CGRect, shadow: Bool) -> CATextLayer {
        let font = tileFont(size: fontSize, weight: weight)
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
        if shadow { applyTextShadow(label) }
        return label
    }

    /// A soft drop shadow so text stays legible over footage.
    private static func applyTextShadow(_ layer: CALayer) {
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.7
        layer.shadowRadius = 3; layer.shadowOffset = .zero
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
