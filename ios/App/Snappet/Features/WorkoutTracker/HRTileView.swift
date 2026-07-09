import SwiftUI

/// # WYSIWYG preview of the HR stat **tile**
///
/// The SwiftUI twin of the export burn-in (`StudioOverlays.hrTileLayer`): both run the SAME pure
/// `HRTileLayout` over the tile's rect and resolve each metric's text/colour through `HROverlayValues`,
/// so what the user sees here is what burns into the file. `HRTileView` is the pure render; the
/// `HRTileEditorView` wraps it in a draggable + corner-resizable frame on the studio canvas (the tile
/// analogue of `ResizableFrame`).

// MARK: - Pure render

struct HRTileView: View {
    let tile: HRTile
    let values: HROverlayValues
    /// Playhead fraction within the clip (0…1) — drives the live metrics + the chart dot.
    let fraction: Double
    /// `true` (studio preview) → a live `.ultraThinMaterial` backdrop blur. `false` (the Clips feed inline
    /// poster) → a flat scrim fill: cheap to composite while a carousel page slides (a backdrop blur is
    /// re-rasterized every drag frame, which janks the swipe) AND it matches what the export actually burns
    /// (the export can't live-blur footage — it draws the same fill over a scrim).
    var liveBlur: Bool = true

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let resolved = resolvedReadings()
            let layout = HRTileLayout.layout(template: tile.template,
                                             enabledMetrics: resolved.map(\.metric),
                                             tileRect: rect, hasChart: tile.showChart)
            let zoneHex = chromeZoneHex
            ZStack(alignment: .topLeading) {
                glassCard(radius: HRTileStyle.tileRadius(w: rect.width, h: rect.height))
                // Template chrome (Broadcast accent bar / Gradient Strain skin), behind the content.
                ForEach(layout.decorations.indices, id: \.self) { i in
                    decoration(layout.decorations[i], zoneHex: zoneHex,
                               radius: HRTileStyle.tileRadius(w: rect.width, h: rect.height))
                }
                if tile.showChart, let chartRect = layout.chartRect {
                    PremiumHRCurve(samples: values.chartSamples, maxHR: values.resolvedMaxHR,
                                   fraction: fraction, zoneColored: tile.zoneColored,
                                   sparkline: chartRect.height < rect.height * 0.30,
                                   rawPeakBpm: values.rawPeakBpm, sparse: values.isSparseChart,
                                   window: values.window)
                        .frame(width: chartRect.width, height: chartRect.height)
                        .position(x: chartRect.midX, y: chartRect.midY)
                }
                ForEach(layout.slots.indices, id: \.self) { i in
                    let slot = layout.slots[i]
                    slotView(slot, reading: reading(for: slot.metric, in: resolved))
                        .frame(width: slot.frame.width, height: slot.frame.height)
                        .position(x: slot.frame.midX, y: slot.frame.midY)
                }
            }
            .opacity(min(1, max(HRTile.minOpacity, tile.opacity)))   // user-controlled tile transparency
        }
        .accessibilityIdentifier("studioHRTile")
    }

    /// The shared "Glass HUD" card backing (issue #163): a liquid-glass panel (material blur + the kit's
    /// translucent fill) with a hairline edge + soft drop shadow. The export draws the same fill over a
    /// scrim (it can't live-blur the footage), so the colours match and only the blur is preview-only.
    private func glassCard(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(liveBlur ? AnyShapeStyle(Material.ultraThinMaterial) : AnyShapeStyle(Color.black.opacity(0.30)))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .fill(Color(studioHex: HRTileStyle.glassFillHex).opacity(HRTileStyle.glassFillAlpha)))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(.white.opacity(HRTileStyle.hairlineAlpha), lineWidth: 1))
            .shadow(color: .black.opacity(HRTileStyle.shadowAlpha), radius: radius * 0.5, y: radius * 0.18)
    }

    // The enabled metrics that actually have data at this playhead, in display order — the layout input
    // (so a no-data metric, e.g. calories without a profile, is dropped here exactly as in the export).
    private func resolvedReadings() -> [(metric: HROverlayMetric, reading: HROverlayValues.Reading)] {
        tile.enabledMetrics.compactMap { metric in
            guard let entry = tile.entry(for: metric) else { return nil }
            var el = HROverlayElement(metric: metric, colorHex: entry.colorHex)
            el.live = entry.live; el.animated = entry.animated
            guard let r = values.reading(for: el, atFraction: fraction) else { return nil }
            return (metric, r)
        }
    }

    private func reading(for metric: HROverlayMetric,
                         in resolved: [(metric: HROverlayMetric, reading: HROverlayValues.Reading)]) -> HROverlayValues.Reading? {
        resolved.first { $0.metric == metric }?.reading
    }

    private var heroColor: Color { Color(studioHex: HRTileStyle.heroTextHex) }

    /// The accent colour for a non-hero value: zone/semantic hue for the live-intensity metrics
    /// (zone/%HRR/redline/recovery), near-white for the aggregates — so a single hue never misrepresents
    /// a multi-zone session (the `decisions.md` rule, refreshed for the value-only chips).
    private func valueColor(_ metric: HROverlayMetric, _ reading: HROverlayValues.Reading) -> Color {
        switch metric {
        case .zone, .hrr, .redline, .recovery: return Color(studioHex: reading.hex)
        default: return heroColor.opacity(HRTileStyle.valueAlpha)
        }
    }

    @ViewBuilder
    private func slotView(_ slot: HRTileLayout.MetricSlot, reading: HROverlayValues.Reading?) -> some View {
        if let reading {
            switch slot.role {
            case .gauge:
                gauge(reading, side: slot.frame.width)
            case .zoneBar:
                zoneBar(reading, vertical: slot.zoneBarVertical)
            case .pill:
                zonePill(reading, fontSize: slot.fontSize, align: slot.align)
            case .hero:
                heroValue(reading, fontSize: slot.fontSize, align: slot.align)
            case .chip:
                chip(slot.metric, reading, fontSize: slot.fontSize, height: slot.frame.height, showsLabel: slot.showsLabel)
            case .field:
                field(slot, reading)
            }
        }
    }

    /// The %HRR sweep gauge: a faint full-circle track + a zone-coloured arc filled to `reading.fraction`
    /// (the effort), sweeping clockwise from 12 o'clock. The centred bpm hero is a separate slot.
    private func gauge(_ reading: HROverlayValues.Reading, side: CGFloat) -> some View {
        let frac = max(0.02, min(1, reading.fraction ?? 1))
        let color = Color(studioHex: reading.hex)
        let lw = max(3, side * 0.09)
        return ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lw)
            Circle().trim(from: 0, to: frac)
                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.6), radius: 3)
        }
        .padding(lw / 2)
    }

    /// The segmented zone bar — 5 cells (Z1…Z5), each tinted its zone colour, the current zone lit and
    /// the rest dimmed. Horizontal (Broadcast) or vertical with Z5 on top (Rail).
    private func zoneBar(_ reading: HROverlayValues.Reading, vertical: Bool) -> some View {
        let cur = HeartRateZone.zoneIndex(forColorHex: reading.hex)
        let order = vertical ? [5, 4, 3, 2, 1] : [1, 2, 3, 4, 5]
        func cellColor(_ z: Int) -> Color { (HeartRateZone(rawValue: z) ?? .aerobic).color }
        let cells = ForEach(order, id: \.self) { z in
            RoundedRectangle(cornerRadius: 2)
                .fill(cellColor(z).opacity(z == cur ? 1 : 0.22))
                .shadow(color: z == cur ? cellColor(z).opacity(0.7) : .clear, radius: 2)
        }
        return Group {
            if vertical { VStack(spacing: 3) { cells } } else { HStack(spacing: 3) { cells } }
        }
    }

    /// The chrome (accent bar / gradient skin) colour — the clip's **overall** zone (from the average
    /// bpm), STATIC so it doesn't flicker per-frame; the export computes the same, so the two match. The
    /// live tracking is done by the bpm hero / zone pill / zone bar / gauge / chart dot.
    private var chromeZoneHex: String {
        let v = values.samples.map(\.bpm).filter { $0 > 0 }
        guard !v.isEmpty else { return HeartRateZone.aerobic.colorHex }
        return HeartRateZone.forBpm(v.reduce(0, +) / Double(v.count), maxHR: values.resolvedMaxHR).colorHex
    }

    /// Template chrome: the Broadcast accent bar (a thin zone-coloured bar) and the Gradient Strain skin
    /// (a horizontal cool→zone gradient wash, so colour doubles as the effort metric). Horizontal so it
    /// matches the export (a vertical CAGradientLayer's orientation is flip-ambiguous in the tool tree).
    @ViewBuilder
    private func decoration(_ d: HRTileLayout.Decoration, zoneHex: String, radius: CGFloat) -> some View {
        let zone = Color(studioHex: zoneHex)
        switch d.kind {
        case .accentBar:
            RoundedRectangle(cornerRadius: d.frame.width / 2)
                .fill(zone).shadow(color: zone.opacity(0.7), radius: 3)
                .frame(width: d.frame.width, height: d.frame.height)
                .position(x: d.frame.midX, y: d.frame.midY)
        case .gradientSkin:
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [Color(studioHex: "#0E3A4A").opacity(0.5), zone.opacity(0.5)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: d.frame.width, height: d.frame.height)
                .position(x: d.frame.midX, y: d.frame.midY)
        }
    }

    /// The giant hero number: near-white value + a small inline unit ("156" + "BPM"), tabular digits.
    private func heroValue(_ reading: HROverlayValues.Reading, fontSize: CGFloat, align: HRTileLayout.TextAlign) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.07) {
            Text(reading.value)
                .font(.system(size: fontSize, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(heroColor)
            if let unit = reading.unit {
                Text(unit)
                    .font(.system(size: fontSize * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(heroColor.opacity(HRTileStyle.captionAlpha))
            }
        }
        .lineLimit(1).minimumScaleFactor(0.5)
        .shadow(color: .black.opacity(0.45), radius: 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlign(align))
    }

    /// The zone pill: a zone-tinted glass capsule with a leading zone dot + zone-coloured uppercase label.
    private func zonePill(_ reading: HROverlayValues.Reading, fontSize: CGFloat, align: HRTileLayout.TextAlign) -> some View {
        let zone = Color(studioHex: reading.hex)
        return HStack(spacing: fontSize * 0.34) {
            Circle().fill(zone).frame(width: fontSize * 0.42, height: fontSize * 0.42)
            Text(reading.value.uppercased())
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(zone).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, fontSize * 0.6).padding(.vertical, fontSize * 0.28)
        .background(zone.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(zone.opacity(0.35), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlign(align))
    }

    /// A value-only chip: uppercase caption above a value, on a nested glass chip (issue #163 ①). The
    /// corner radius is computed from the slot `height` (the rendered chip height) so it matches the
    /// export's `chipRadius(h: frame.height)` exactly — WYSIWYG.
    private func chip(_ metric: HROverlayMetric, _ reading: HROverlayValues.Reading,
                      fontSize: CGFloat, height: CGFloat, showsLabel: Bool) -> some View {
        VStack(spacing: fontSize * 0.12) {
            if showsLabel {
                Text(metric.tileCaption)
                    .font(.system(size: fontSize * 0.62, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(heroColor.opacity(HRTileStyle.captionAlpha))
            }
            Text(reading.value)
                .font(.system(size: fontSize, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(valueColor(metric, reading))
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(studioHex: HRTileStyle.chipFillHex).opacity(HRTileStyle.chipFillAlpha),
                    in: RoundedRectangle(cornerRadius: HRTileStyle.chipRadius(h: height)))
    }

    /// A field/row. Mirrors the export's `tileValueLayers` `.field` cases exactly (WYSIWYG): when
    /// `showsLabel && align == .leading` → a label-column (leading) + value-column (trailing) so the
    /// value owns a fixed slot and can't collide with its label (rule #9, list/rail); else when
    /// `showsLabel` → value on top with the caption stacked under it (scorebug-style); else value-only.
    @ViewBuilder
    private func field(_ slot: HRTileLayout.MetricSlot, _ reading: HROverlayValues.Reading) -> some View {
        let captionText = Text(slot.metric.tileCaption)
            .font(.system(size: slot.fontSize * 0.62, weight: .semibold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(heroColor.opacity(HRTileStyle.captionAlpha))
        let valueView = HStack(alignment: .firstTextBaseline, spacing: slot.fontSize * 0.1) {
            Text(reading.value)
                .font(.system(size: slot.fontSize, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(valueColor(slot.metric, reading))
            if let unit = reading.unit {
                Text(unit).font(.system(size: slot.fontSize * 0.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(heroColor.opacity(HRTileStyle.captionAlpha))
            }
        }
        if slot.showsLabel && slot.align == .leading {
            HStack {
                captionText
                Spacer(minLength: slot.fontSize * 0.3)
                valueView
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if slot.showsLabel {
            VStack(spacing: slot.fontSize * 0.08) { valueView; captionText }
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlign(slot.align))
        } else {
            valueView.lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlign(slot.align))
        }
    }

    private func frameAlign(_ a: HRTileLayout.TextAlign) -> Alignment {
        switch a { case .leading: return .leading; case .trailing: return .trailing; case .center: return .center }
    }
}

/// The premium **zone-banded HR trace** (issue #163) — the preview twin of
/// `StudioOverlays.tileChartLayer`. A smooth Catmull-Rom→bézier curve (shared `HRChartGeometry`) drawn
/// with a zone-coloured stroke gradient (green over the aerobic plateau → orange/red into the peak), a
/// soft area fill, a glow so it floats over footage, and a glowing playhead dot. Draws on left→right to
/// the playhead `fraction` (matching the export's `strokeEnd` draw-on), so preview == export.
struct PremiumHRCurve: View {
    /// The points the curve draws from — pass the **dense** `HROverlayValues.chartSamples` so the line is
    /// smooth and the dot glides (prompt 101). Aggregates never come from here.
    let samples: [HRPoint]
    let maxHR: Double
    let fraction: Double
    let zoneColored: Bool
    /// A compact register tucked under a hero (thinner stroke, no peak label / baseline rule).
    var sparkline: Bool = false
    /// The RAW window's peak bpm, shown by the peak label (so smoothing the drawn curve can't shave the
    /// number off the scorebug's PEAK). `nil` falls back to the drawn series' peak.
    var rawPeakBpm: Double? = nil
    /// Whether this window is interpolation-dominated (`HRCadence.isSparse`): the curve is drawn **dashed**
    /// and dimmer, signalling "estimated between sparse samples" instead of presenting it as measured data.
    var sparse: Bool = false
    /// The clip's extended HR window (prompt 115): draws the "Variant A" region panes (lead/footage/tail
    /// washes + boundary ticks). The caller is responsible for passing a `fraction` already mapped onto
    /// the chart's x-axis (`HROverlayValues.chartFraction(forVideoFraction:)`). `nil` = no panes.
    var window: HRClipWindow? = nil

    var body: some View {
        GeometryReader { geo in
            let pts = HRChartGeometry.normalizedPoints(samples)
            let w = geo.size.width, h = geo.size.height
            let f = min(1, max(0, fraction))
            let lw = sparkline ? HRTileStyle.lineWidthSpark : HRTileStyle.lineWidthFull
            let stops = HRChartGeometry.zoneStops(samples, maxHR: maxHR)
            let dotZone = HeartRateZone.forBpm(HRChartGeometry.sampleBPM(samples, atFraction: f), maxHR: maxHR)
            let dotColor = zoneColored ? dotZone.color : Color(studioHex: "#FF3B30")
            let glow = zoneColored ? (peakZone(pts).color) : Color(studioHex: "#FF3B30")
            // Dashed + dimmer for an interpolation-only (sparse) window — honest "estimated" styling.
            let dash: [CGFloat] = sparse ? [lw * 2.2, lw * 1.8] : []
            if pts.count >= 2 {
                ZStack {
                    // Extended-window region panes (prompt 115, "Variant A") — behind everything, the
                    // preview twin of the export's pane layers in `StudioOverlays.tileChartLayer`.
                    if let window, window.isExtended, let maxT = samples.map(\.t).max(), maxT > 0 {
                        regionPanes(window: window, maxT: maxT, w: w, h: h)
                    }
                    // Area fill — a flat low-alpha zone wash (both sides use a flat fill so preview ==
                    // export; a CAGradientLayer's vertical orientation is flip-ambiguous in the tool tree).
                    SmoothHRArea(norm: pts)
                        .fill(glow.opacity(HRTileStyle.areaTopAlpha * (sparse ? 0.22 : 0.55)))
                    // The zone-banded stroke + glow. The FULL curve draws (no `strokeEnd` draw-on) so the
                    // per-frame SwiftUI preview and the Core-Animation export match during playback — only
                    // the dot moves; see `decisions.md`.
                    SmoothHRCurve(norm: pts)
                        .stroke(strokeStyle(stops: stops, flat: !zoneColored),
                                style: StrokeStyle(lineWidth: lw, lineCap: sparse ? .butt : .round,
                                                   lineJoin: .round, dash: dash))
                        .opacity(sparse ? 0.7 : 1)
                        .shadow(color: glow.opacity(HRTileStyle.curveGlowAlpha), radius: sparkline ? 2 : 3)
                    // Baked peak label (full curve only) — the RAW peak, not the smoothed curve's.
                    if !sparkline, let pk = HRChartGeometry.peakIndex(pts),
                       let peak = rawPeakBpm ?? HRChartGeometry.peakBPM(samples) {
                        Text("\(Int(peak.rounded()))")
                            .font(.system(size: max(9, h * 0.16), weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9))
                            .position(x: pts[pk].x * w, y: max(h * 0.12, (1 - pts[pk].y) * h - h * 0.18))
                    }
                    // Glowing playhead dot + baseline rule.
                    playhead(pts: pts, f: f, w: w, h: h, color: dotColor)
                }
            }
        }
    }

    private func strokeStyle(stops: [HRChartGeometry.ZoneStop], flat: Bool) -> AnyShapeStyle {
        if flat || stops.count < 2 { return AnyShapeStyle(Color(studioHex: "#FF3B30")) }
        return AnyShapeStyle(LinearGradient(
            stops: stops.map { .init(color: Color(studioHex: $0.hex), location: $0.location) },
            startPoint: .leading, endPoint: .trailing))
    }

    private func peakZone(_ pts: [CGPoint]) -> HeartRateZone {
        HeartRateZone.forBpm(HRChartGeometry.peakBPM(samples), maxHR: maxHR)
    }

    /// The "Variant A" region panes: faint zone-tinted washes (lead / footage / tail) + 1px ember
    /// boundary ticks at the footage edges. Styling from the shared `HRWindowRegionStyle`, fractions
    /// against the chart's `maxT` — identical to the export's pane layers.
    @ViewBuilder
    private func regionPanes(window: HRClipWindow, maxT: Double, w: CGFloat, h: CGFloat) -> some View {
        let fs = window.footageStartFraction(maxT: maxT)
        let fe = window.footageEndFraction(maxT: maxT)
        let panes: [(from: Double, to: Double, hex: String, alpha: CGFloat)] = [
            (0, fs, HRWindowRegionStyle.leadHex, HRWindowRegionStyle.leadAlpha),
            (fs, fe, HRWindowRegionStyle.footageHex, HRWindowRegionStyle.footageAlpha),
            (fe, 1, HRWindowRegionStyle.tailHex, HRWindowRegionStyle.tailAlpha)
        ]
        ZStack {
            ForEach(panes.indices, id: \.self) { i in
                let p = panes[i]
                if p.to - p.from > 0.001 {
                    Rectangle()
                        .fill(Color(studioHex: p.hex).opacity(p.alpha))
                        .frame(width: (p.to - p.from) * w, height: h)
                        .position(x: (p.from + p.to) / 2 * w, y: h / 2)
                }
            }
            ForEach([fs, fe], id: \.self) { x in
                if x > 0.001 && x < 0.999 {
                    Rectangle()
                        .fill(Color(studioHex: HRWindowRegionStyle.tickHex).opacity(HRWindowRegionStyle.tickAlpha))
                        .frame(width: HRWindowRegionStyle.tickWidth, height: h)
                        .position(x: x * w, y: h / 2)
                }
            }
        }
    }

    @ViewBuilder
    private func playhead(pts: [CGPoint], f: Double, w: CGFloat, h: CGFloat, color: Color) -> some View {
        let dot = pts.min { abs($0.x - f) < abs($1.x - f) } ?? pts[pts.count - 1]
        let p = CGPoint(x: dot.x * w, y: (1 - dot.y) * h)
        ZStack {
            if !sparkline {
                Rectangle().fill(.white.opacity(0.5)).frame(width: 1.25, height: max(0, h - p.y))
                    .position(x: p.x, y: (p.y + h) / 2)
            }
            Circle().fill(color.opacity(0.35)).frame(width: sparkline ? 11 : 16, height: sparkline ? 11 : 16).position(p)
            Circle().fill(.white).frame(width: sparkline ? 7 : 10, height: sparkline ? 7 : 10).position(p)
            Circle().fill(color).frame(width: sparkline ? 4 : 6, height: sparkline ? 4 : 6).position(p)
        }
    }
}

/// A smooth Catmull-Rom→bézier curve through normalized HR points (`y = 1` is the top), mapped into the
/// shape's rect — the SwiftUI twin of `HRChartGeometry.smoothedPath` (which both this and the export use).
private struct SmoothHRCurve: Shape {
    var norm: [CGPoint]
    func path(in rect: CGRect) -> Path {
        let mapped = norm.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + (1 - $0.y) * rect.height) }
        return Path(HRChartGeometry.smoothedPath(through: mapped))
    }
}

/// The closed area under the smooth curve (down to the baseline), for the gradient fill.
private struct SmoothHRArea: Shape {
    var norm: [CGPoint]
    func path(in rect: CGRect) -> Path {
        let mapped = norm.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + (1 - $0.y) * rect.height) }
        var p = Path(HRChartGeometry.smoothedPath(through: mapped))
        if let last = mapped.last, let first = mapped.first {
            p.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            p.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Draggable + corner-resizable editor frame

/// The HR tile on the studio canvas: a draggable, corner-resizable frame whose content is the live
/// `HRTileView` (so resizing reflows the metrics in real time — the user watches a Scorebug shed
/// trailing fields as they shrink it). Adapts `ResizableFrame`'s flicker-free pattern (handles anchored
/// at the committed size, model written once on gesture end), but **free-aspect** and with the tile's
/// own min sizes. Rendered as a sibling over the preview, like the HR chart.
struct HRTileEditorView: View {
    let tile: HRTile
    let values: HROverlayValues
    let fraction: Double
    /// Canvas width:height (e.g. 9/16) — the displayed video rect to place against.
    let ratio: CGFloat
    /// Commit a new normalized centre + size.
    let onFrame: (CGPoint, CGSize) -> Void

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var cornerDrag: CornerDrag?

    private struct CornerDrag: Equatable { var corner: HRTileCorner; var translation: CGSize }

    var body: some View {
        GeometryReader { geo in
            let rect = ClipEditGeometry.displayRect(ratio: ratio, in: geo.size)
            let committedCenter = ClipEditGeometry.previewPoint(normalized: tile.center, in: rect)
            let committedSize = CGSize(width: max(24, rect.width * tile.width),
                                       height: max(16, rect.height * tile.height))
            let live = cornerDrag.map { resized(corner: $0.corner, translation: $0.translation, in: rect).pts }
            let outline = live ?? (center: committedCenter, size: committedSize)
            ZStack {
                HRTileView(tile: tile, values: values, fraction: fraction)
                    .frame(width: outline.size.width, height: outline.size.height)
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(SnappetColor.workout, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .offset(x: outline.center.x - committedCenter.x, y: outline.center.y - committedCenter.y)
                cornerHandles(committedSize: committedSize, rect: rect)
            }
            .contentShape(Rectangle())
            .position(x: committedCenter.x + dragTranslation.width,
                      y: committedCenter.y + dragTranslation.height)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($dragTranslation) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        let dropped = CGPoint(x: committedCenter.x + v.translation.width,
                                              y: committedCenter.y + v.translation.height)
                        onFrame(ClipEditGeometry.normalizedPoint(fromPreview: dropped, in: rect), tile.size)
                    }
            )
        }
        .allowsHitTesting(true)
    }

    private func cornerHandles(committedSize s: CGSize, rect: CGRect) -> some View {
        ZStack {
            ForEach(HRTileCorner.allCases, id: \.self) { corner in
                Circle().fill(SnappetColor.workout).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .position(x: (s.width / 2) * corner.x + s.width / 2,
                              y: (s.height / 2) * corner.y + s.height / 2)
                    .offset(cornerDrag?.corner == corner ? cornerDrag!.translation : .zero)
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 1)
                            .updating($cornerDrag) { v, st, _ in st = CornerDrag(corner: corner, translation: v.translation) }
                            .onEnded { v in
                                let r = resized(corner: corner, translation: v.translation, in: rect)
                                onFrame(r.centerNorm, r.sizeNorm)
                            }
                    )
                    .accessibilityIdentifier("studioHRTileCorner")
            }
        }
        .frame(width: s.width, height: s.height)
    }

    /// Resize from a corner with the opposite corner fixed (free aspect), clamped to the tile's min
    /// sizes. Returns normalized centre+size (commit) and points (live outline).
    private func resized(corner: HRTileCorner, translation: CGSize, in rect: CGRect)
        -> (centerNorm: CGPoint, sizeNorm: CGSize, pts: (center: CGPoint, size: CGSize)) {
        let baseCenter = ClipEditGeometry.previewPoint(normalized: tile.center, in: rect)
        let halfW = rect.width * tile.width / 2, halfH = rect.height * tile.height / 2
        let fixed = CGPoint(x: baseCenter.x - corner.x * halfW, y: baseCenter.y - corner.y * halfH)
        let dragged = CGPoint(x: baseCenter.x + corner.x * halfW + translation.width,
                              y: baseCenter.y + corner.y * halfH + translation.height)
        let newW = abs(dragged.x - fixed.x), newH = abs(dragged.y - fixed.y)
        let sizeNorm = CGSize(width: min(1, max(HRTile.minWidth, newW / rect.width)),
                              height: min(1, max(HRTile.minHeight, newH / rect.height)))
        let sizePts = CGSize(width: max(24, sizeNorm.width * rect.width),
                             height: max(16, sizeNorm.height * rect.height))
        let signX: CGFloat = dragged.x >= fixed.x ? 1 : -1
        let signY: CGFloat = dragged.y >= fixed.y ? 1 : -1
        let centerPts = CGPoint(x: fixed.x + signX * sizePts.width / 2, y: fixed.y + signY * sizePts.height / 2)
        return (ClipEditGeometry.normalizedPoint(fromPreview: centerPts, in: rect), sizeNorm, (centerPts, sizePts))
    }
}

/// The four corners of the tile frame, relative to its centre (x: −1 leading/+1 trailing, y: −1 top/+1 bottom).
private enum HRTileCorner: CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
    var x: CGFloat { (self == .topTrailing || self == .bottomTrailing) ? 1 : -1 }
    var y: CGFloat { (self == .bottomLeading || self == .bottomTrailing) ? 1 : -1 }
}
