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

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let resolved = resolvedReadings()
            let layout = HRTileLayout.layout(template: tile.template,
                                             enabledMetrics: resolved.map(\.metric),
                                             tileRect: rect, hasChart: tile.showChart)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: min(18, rect.height * 0.18))
                    .fill(.black.opacity(0.32))
                if tile.showChart, let chartRect = layout.chartRect {
                    HRTileSparkline(samples: values.samples, fraction: fraction,
                                    zoneColored: tile.zoneColored)
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
        }
        .accessibilityIdentifier("studioHRTile")
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

    @ViewBuilder
    private func slotView(_ slot: HRTileLayout.MetricSlot, reading: HROverlayValues.Reading?) -> some View {
        switch slot.role {
        case .gauge:
            Circle().strokeBorder(Color(studioHex: reading?.hex ?? "#FF3B30"),
                                  lineWidth: max(3, slot.frame.width * 0.08))
        case .pill:
            if let reading {
                Text(reading.text)
                    .font(.system(size: slot.fontSize, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.horizontal, slot.fontSize * 0.5).padding(.vertical, slot.fontSize * 0.2)
                    .background(Color(studioHex: reading.hex).opacity(0.95), in: Capsule())
            }
        default:
            if let reading {
                VStack(spacing: 1) {
                    Text(reading.text)
                        .font(.system(size: slot.fontSize, weight: slot.role == .hero ? .heavy : .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color(studioHex: reading.hex))
                        .shadow(color: .black.opacity(0.7), radius: 2)
                    if slot.showsLabel {
                        Text(slot.metric.tileCaption)
                            .font(.system(size: max(8, slot.fontSize * 0.42), weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.7), radius: 2)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity,
                       alignment: slot.align == .leading ? .leading : (slot.align == .trailing ? .trailing : .center))
            }
        }
    }
}

/// A compact HR sparkline (polyline + playhead dot) for the tile's chart register — the preview twin of
/// `StudioOverlays.tileChartLayer`. SwiftUI top-left coords, so the normalized y (1 = top) is flipped.
private struct HRTileSparkline: View {
    let samples: [HRPoint]
    let fraction: Double
    let zoneColored: Bool

    var body: some View {
        GeometryReader { geo in
            let pts = HRChartGeometry.normalizedPoints(samples)
            let w = geo.size.width, h = geo.size.height
            let color = zoneColored ? HeartRateZone.forBpm(avgBPM).color : Color(studioHex: "#FF3B30")
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x * w, y: (1 - f.y) * h))
                    for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.x * w, y: (1 - q.y) * h)) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                if let dot = dotPoint(pts) {
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .position(x: dot.x * w, y: (1 - dot.y) * h)
                }
            }
        }
    }

    private var avgBPM: Double {
        let v = samples.map(\.bpm).filter { $0 > 0 }
        return v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
    private func dotPoint(_ pts: [CGPoint]) -> CGPoint? {
        guard !pts.isEmpty else { return nil }
        let f = min(1, max(0, fraction))
        // Nearest point by x to the playhead fraction.
        return pts.min { abs($0.x - f) < abs($1.x - f) }
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
