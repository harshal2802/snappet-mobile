import Foundation
import CoreGraphics

/// # Pure tile layout — the single source of truth for the HR stat tile
///
/// `layout(template:enabledMetrics:tileRect:hasChart:)` turns the tile's design + which metrics are
/// ON + the tile's rectangle into per-metric **slot frames** (plus an optional chart rect). The SwiftUI
/// preview (`HRTileView`) and the Core-Animation export burn-in (`StudioOverlays.hrTileLayer`) both
/// call THIS, so what the user places is exactly what burns into the file (WYSIWYG) — the same
/// contract the legacy per-element path had through `HROverlayValues`.
///
/// ## Scale invariance (why preview == export)
/// The preview passes a rect in **points** (a few hundred wide); the export passes a rect in **output
/// pixels** (e.g. 1080 wide). To make the layout *identical* in both, every decision — how many fields
/// fit, how many grid columns, how many rows — is derived only from the rect's **proportions** (its
/// aspect and the metric count), which are scale-invariant. Font sizes are computed as fractions of the
/// rect; the 11 pt legibility **floor** is applied ONLY to the value reported in each slot, never to the
/// fit math, so reflow can't diverge between a small preview and a large export.
///
/// Platform-free (CoreGraphics only) and unit-tested in `SnappetTests`.
enum HRTileLayout {

    /// Minimum reported font size (legibility floor). A guard, not the primary path — applied to the
    /// slot's `fontSize` but NOT to the fit/reflow math (see the scale-invariance note above).
    static let fontFloor: CGFloat = 11

    /// How a slot is drawn. The layout decides geometry + role; the consumer (preview / export) draws
    /// the value text, a zone pill, a chip, or an arc accordingly.
    enum Role: String, Sendable, Equatable {
        case hero      // the lead metric, largest (usually bpm)
        case field     // a value + caption column/cell
        case chip      // a compact value-only chip
        case pill      // a zone pill (filled, rounded)
        case gauge     // an arc/ring bound to a ratio metric (%HRR)
    }

    enum TextAlign: String, Sendable, Equatable { case leading, center, trailing }

    /// One laid-out metric: where it goes, how it's drawn, and at what size.
    struct MetricSlot: Equatable, Sendable {
        var metric: HROverlayMetric
        /// Absolute frame in the same coordinate space as the input `tileRect` (top-left origin).
        var frame: CGRect
        var role: Role
        var fontSize: CGFloat
        var align: TextAlign
        /// Draw the metric's caption (e.g. "BPM") alongside the value — dropped when there's no room.
        var showsLabel: Bool
    }

    /// The full layout: the tile rect, an optional chart register, and the metric slots in display order.
    struct Result: Equatable, Sendable {
        var tileRect: CGRect
        var chartRect: CGRect?
        var slots: [MetricSlot]
    }

    // MARK: - Entry point

    static func layout(template: HRTileTemplate, enabledMetrics: [HROverlayMetric],
                       tileRect rect: CGRect, hasChart: Bool) -> Result {
        let metrics = enabledMetrics
        switch template {
        case .scorebug:    return scorebug(metrics, rect, hasChart)
        case .hero:        return heroCard(metrics, rect, hasChart)
        case .bento:       return bento(metrics, rect, hasChart)
        case .list:        return list(metrics, rect, hasChart)
        case .ring:        return ring(metrics, rect, hasChart)
        case .hudPill:     return hudPill(metrics, rect, hasChart)
        case .chartBanner: return chartBanner(metrics, rect, hasChart)
        }
    }

    // MARK: - Shared helpers

    /// The lead/hero metric = the first enabled one (the catalog's default order is also priority
    /// order, so this is bpm when bpm is on, else the next most-important enabled metric).
    private static func hero(_ metrics: [HROverlayMetric]) -> HROverlayMetric? { metrics.first }

    /// Estimated rendered width of a value at `font`, in the same units as `font` (pure — no HR data).
    private static func valueWidth(_ m: HROverlayMetric, font: CGFloat, pad: CGFloat) -> CGFloat {
        m.tileValueChars * font * 0.62 + pad * 2
    }

    /// Drop the lowest-priority metric (largest `tilePriority`) among the droppable tail until `fits`
    /// holds or only `keepLeading` lead metrics remain. NEVER drops the first `keepLeading` (the hero,
    /// + protected peers). Returns the kept metrics in their **original order**. Deterministic.
    static func reflowed(_ metrics: [HROverlayMetric], keepLeading: Int,
                         fits: ([HROverlayMetric]) -> Bool) -> [HROverlayMetric] {
        var kept = metrics
        let protected = Swift.max(0, Swift.min(keepLeading, metrics.count))
        while kept.count > protected && !fits(kept) {
            let tail = kept.indices.filter { $0 >= protected }
            guard let drop = tail.max(by: { kept[$0].tilePriority < kept[$1].tilePriority }) else { break }
            kept.remove(at: drop)
        }
        return kept
    }

    private static func empty(_ rect: CGRect) -> Result { Result(tileRect: rect, chartRect: nil, slots: []) }

    // MARK: - Scorebug (default): broadcast lower-third strip

    private static func scorebug(_ metrics: [HROverlayMetric], _ rect: CGRect, _ hasChart: Bool) -> Result {
        guard !metrics.isEmpty else { return empty(rect) }
        let chartH: CGFloat = hasChart ? rect.height * 0.34 : 0
        let rowH = rect.height - chartH
        let rowRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rowH)
        let chartRect = hasChart
            ? CGRect(x: rect.minX, y: rowRect.maxY, width: rect.width, height: chartH) : nil

        let pad = rowH * 0.10
        let rawFont = rowH * 0.40                      // UNfloored — drives the scale-invariant fit
        let showsLabel = rowH >= rawFont * 2.0         // room for a caption line under the value

        func fieldWidth(_ m: HROverlayMetric) -> CGFloat {
            let lead = (m == metrics.first) ? 1.30 : 1.0
            return valueWidth(m, font: rawFont, pad: pad) * lead
        }
        func fits(_ ms: [HROverlayMetric]) -> Bool {
            ms.reduce(0) { $0 + fieldWidth($1) } <= rowRect.width
        }
        let kept = reflowed(metrics, keepLeading: min(2, metrics.count), fits: fits)

        // Scale field widths to fill the row exactly (shrink only) and centre them.
        let total = kept.reduce(0) { $0 + fieldWidth($1) }
        let k = total > 0 ? min(1, rowRect.width / total) : 1
        var x = rowRect.minX + (rowRect.width - total * k) / 2
        var slots: [MetricSlot] = []
        for m in kept {
            let w = fieldWidth(m) * k
            let isHero = (m == kept.first)
            slots.append(MetricSlot(
                metric: m,
                frame: CGRect(x: x, y: rowRect.minY, width: w, height: rowH),
                role: isHero ? .hero : .field,
                fontSize: max(fontFloor, rawFont * (isHero ? 1.12 : 1.0)),
                align: .center, showsLabel: showsLabel))
            x += w
        }
        return Result(tileRect: rect, chartRect: chartRect, slots: slots)
    }

    // MARK: - HR Hero: one big number + zone pill + demoted chips

    private static func heroCard(_ metrics: [HROverlayMetric], _ rect: CGRect, _ hasChart: Bool) -> Result {
        guard let lead = hero(metrics) else { return empty(rect) }
        var slots: [MetricSlot] = []
        let heroH = rect.height * 0.52
        let heroFont = max(fontFloor, heroH * 0.60)
        slots.append(MetricSlot(metric: lead,
                                frame: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: heroH),
                                role: .hero, fontSize: heroFont, align: .center, showsLabel: true))
        var y = rect.minY + heroH
        let others = metrics.filter { $0 != lead }

        if others.contains(.zone) {
            let pillH = rect.height * 0.20
            slots.append(MetricSlot(metric: .zone,
                                    frame: CGRect(x: rect.minX, y: y, width: rect.width, height: pillH),
                                    role: .pill, fontSize: max(fontFloor, pillH * 0.52),
                                    align: .center, showsLabel: false))
            y += pillH
        }

        var chartRect: CGRect?
        if hasChart && (rect.maxY - y) > rect.height * 0.22 {
            let chH = rect.height * 0.18
            chartRect = CGRect(x: rect.minX, y: y, width: rect.width, height: chH)
            y += chH
        }

        let chips = others.filter { $0 != .zone }
        let chipRowH = rect.maxY - y
        if !chips.isEmpty && chipRowH >= fontFloor {
            let rawChip = min(chipRowH * 0.5, heroH * 0.18)
            let pad = rect.width * 0.015
            func chipW(_ m: HROverlayMetric) -> CGFloat { valueWidth(m, font: rawChip, pad: pad) }
            let kept = reflowed(chips, keepLeading: 0,
                                fits: { $0.reduce(0) { $0 + chipW($1) } <= rect.width })
            let total = kept.reduce(0) { $0 + chipW($1) }
            var x = rect.minX + (rect.width - total) / 2
            for m in kept {
                let w = chipW(m)
                slots.append(MetricSlot(metric: m,
                                        frame: CGRect(x: x, y: y, width: w, height: chipRowH),
                                        role: .chip, fontSize: max(fontFloor, rawChip),
                                        align: .center, showsLabel: false))
                x += w
            }
        }
        return Result(tileRect: rect, chartRect: chartRect, slots: slots)
    }

    // MARK: - Stats Bento: hero spans the top, then an N-column grid

    private static func bento(_ metrics: [HROverlayMetric], _ rect: CGRect, _ hasChart: Bool) -> Result {
        guard let lead = hero(metrics) else { return empty(rect) }
        var slots: [MetricSlot] = []
        let heroH = rect.height * 0.26
        slots.append(MetricSlot(metric: lead,
                                frame: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: heroH),
                                role: .hero, fontSize: max(fontFloor, heroH * 0.50),
                                align: .leading, showsLabel: true))
        var y = rect.minY + heroH

        var chartRect: CGRect?
        if hasChart {
            let chH = rect.height * 0.20
            chartRect = CGRect(x: rect.minX, y: y, width: rect.width, height: chH)
            y += chH
        }

        let gridMetrics = metrics.filter { $0 != lead }
        guard !gridMetrics.isEmpty else { return Result(tileRect: rect, chartRect: chartRect, slots: slots) }
        let gridRect = CGRect(x: rect.minX, y: y, width: rect.width, height: max(0, rect.maxY - y))

        // Columns from proportions: a cell must be at least ~one field wide. Scale-invariant because
        // both the cell width and the min cell width scale with the rect.
        let rawCellFont = gridRect.height * 0.18
        let minCellW = valueWidth(.avgHR, font: max(rawCellFont, 8), pad: gridRect.width * 0.02)
        let cols = (gridRect.width / 2 >= minCellW) ? 2 : 1
        let rowsNeeded = Int(ceil(Double(gridMetrics.count) / Double(cols)))
        let rawRowH = gridRect.height / CGFloat(max(1, rowsNeeded))
        // Drop lowest-priority cells if rows would be shorter than the floor would allow.
        let maxRows = max(1, Int(gridRect.height / (fontFloor * 1.7)))
        let cellFont = max(fontFloor, rawRowH * 0.34)
        let capacity = maxRows * cols
        let kept = gridMetrics.count <= capacity
            ? gridMetrics
            : reflowed(gridMetrics, keepLeading: 0, fits: { $0.count <= capacity })
        let rows = max(1, Int(ceil(Double(kept.count) / Double(cols))))
        let rowH = gridRect.height / CGFloat(rows)
        let colW = gridRect.width / CGFloat(cols)
        for (i, m) in kept.enumerated() {
            let r = i / cols, c = i % cols
            slots.append(MetricSlot(
                metric: m,
                frame: CGRect(x: gridRect.minX + CGFloat(c) * colW,
                              y: gridRect.minY + CGFloat(r) * rowH, width: colW, height: rowH),
                role: .field, fontSize: cellFont, align: .leading,
                showsLabel: rowH >= cellFont * 1.7))
        }
        return Result(tileRect: rect, chartRect: chartRect, slots: slots)
    }

    // MARK: - Metrics List: single-column label–value rows

    private static func list(_ metrics: [HROverlayMetric], _ rect: CGRect, _ hasChart: Bool) -> Result {
        guard !metrics.isEmpty else { return empty(rect) }
        let chartH: CGFloat = hasChart ? rect.height * 0.16 : 0
        let listH = rect.height - chartH
        let chartRect = hasChart
            ? CGRect(x: rect.minX, y: rect.minY + listH, width: rect.width, height: chartH) : nil

        // Lead row is 1.4× tall, the rest 1 unit. n rows occupy (n + 0.4)·unit, so the most that fit
        // is ⌊listH/unit − 0.4⌋. Truncate from the bottom (lowest-priority) keeping the lead.
        let unit = fontFloor * 1.7
        let maxRows = max(1, Int((listH / unit) - 0.4))
        let kept = metrics.count <= maxRows
            ? metrics
            : reflowed(metrics, keepLeading: 1, fits: { $0.count <= maxRows })

        let denom = 1.4 + CGFloat(max(0, kept.count - 1))
        let baseRowH = listH / max(1, denom)
        var slots: [MetricSlot] = []
        var y = rect.minY
        for (i, m) in kept.enumerated() {
            let isLead = (i == 0)
            let h = baseRowH * (isLead ? 1.4 : 1.0)
            slots.append(MetricSlot(metric: m,
                                    frame: CGRect(x: rect.minX, y: y, width: rect.width, height: h),
                                    role: isLead ? .hero : .field,
                                    fontSize: max(fontFloor, h * (isLead ? 0.42 : 0.40)),
                                    align: .leading, showsLabel: true))
            y += h
        }
        return Result(tileRect: rect, chartRect: chartRect, slots: slots)
    }

    // MARK: - Zone Ring: %HRR arc with bpm centered

    /// Below this diameter (absolute) a ring has no legible room → it degrades to a flat zone pill.
    /// Real tiles sit far above this in both preview points and export pixels, so the collapse only
    /// triggers at degenerate sizes (kept consistent across preview/export in practice).
    static let ringMinDiameter: CGFloat = 64

    private static func ring(_ metrics: [HROverlayMetric], _ rect: CGRect, _ hasChart: Bool) -> Result {
        guard let lead = hero(metrics) else { return empty(rect) }
        let others = metrics.filter { $0 != lead }
        let hasChips = others.contains { $0 != .zone }
        let chipBandH = hasChips ? rect.height * 0.18 : 0
        let ringArea = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - chipBandH)
        let diameter = min(ringArea.width, ringArea.height)

        var slots: [MetricSlot] = []
        if diameter < ringMinDiameter {
            // Collapse: a pill with bpm + zone, no gauge.
            let h = min(rect.height, fontFloor * 2.2)
            slots.append(MetricSlot(metric: lead,
                                    frame: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h),
                                    role: .pill, fontSize: max(fontFloor, h * 0.5), align: .center,
                                    showsLabel: false))
            return Result(tileRect: rect, chartRect: nil, slots: slots)
        }

        let ringRect = CGRect(x: ringArea.midX - diameter / 2, y: ringArea.midY - diameter / 2,
                              width: diameter, height: diameter)
        // The arc is bound to %HRR when on, else to the lead (render computes the fill fraction).
        let gaugeMetric: HROverlayMetric = others.contains(.hrr) ? .hrr : lead
        slots.append(MetricSlot(metric: gaugeMetric, frame: ringRect, role: .gauge,
                                fontSize: max(fontFloor, diameter * 0.10), align: .center, showsLabel: false))
        // Centered bpm hero (inside the ring).
        let inset = diameter * 0.22
        let centerRect = ringRect.insetBy(dx: inset, dy: inset)
        slots.append(MetricSlot(metric: lead, frame: centerRect, role: .hero,
                                fontSize: max(fontFloor, centerRect.height * 0.42), align: .center, showsLabel: true))

        if hasChips {
            let chips = others.filter { $0 != .zone }
            let band = CGRect(x: rect.minX, y: ringArea.maxY, width: rect.width, height: chipBandH)
            let rawChip = band.height * 0.5
            let pad = rect.width * 0.012
            func chipW(_ m: HROverlayMetric) -> CGFloat { valueWidth(m, font: rawChip, pad: pad) }
            let kept = reflowed(chips, keepLeading: 0, fits: { $0.reduce(0) { $0 + chipW($1) } <= band.width })
            let total = kept.reduce(0) { $0 + chipW($1) }
            var x = band.minX + (band.width - total) / 2
            for m in kept {
                let w = chipW(m)
                slots.append(MetricSlot(metric: m, frame: CGRect(x: x, y: band.minY, width: w, height: band.height),
                                        role: .chip, fontSize: max(fontFloor, rawChip), align: .center, showsLabel: false))
                x += w
            }
        }
        return Result(tileRect: rect, chartRect: nil, slots: slots)
    }

    // MARK: - HUD Pill: a single compact chip row

    private static func hudPill(_ metrics: [HROverlayMetric], _ rect: CGRect, _ hasChart: Bool) -> Result {
        guard !metrics.isEmpty else { return empty(rect) }
        let rawFont = rect.height * 0.46
        let pad = rect.height * 0.18
        func chipW(_ m: HROverlayMetric) -> CGFloat { valueWidth(m, font: rawFont, pad: pad) }
        // Single line; keep the lead, drop trailing low-priority to fit.
        let kept = reflowed(metrics, keepLeading: 1, fits: { $0.reduce(0) { $0 + chipW($1) } <= rect.width })
        let total = kept.reduce(0) { $0 + chipW($1) }
        let k = total > 0 ? min(1, rect.width / total) : 1
        var x = rect.minX + (rect.width - total * k) / 2
        var slots: [MetricSlot] = []
        for m in kept {
            let w = chipW(m) * k
            slots.append(MetricSlot(metric: m, frame: CGRect(x: x, y: rect.minY, width: w, height: rect.height),
                                    role: m == .zone ? .pill : .chip,
                                    fontSize: max(fontFloor, rawFont), align: .center, showsLabel: false))
            x += w
        }
        return Result(tileRect: rect, chartRect: nil, slots: slots)
    }

    // MARK: - Chart Banner: the moving chart + a caption row

    private static func chartBanner(_ metrics: [HROverlayMetric], _ rect: CGRect, _ hasChart: Bool) -> Result {
        // The chart is this template's point; if the user turned it off, the whole tile is the caption row.
        let chartH: CGFloat = hasChart ? rect.height * 0.58 : 0
        let chartRect = hasChart
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: chartH) : nil
        let capH = rect.height - chartH
        guard !metrics.isEmpty, capH > 0 else { return Result(tileRect: rect, chartRect: chartRect, slots: []) }

        let capRect = CGRect(x: rect.minX, y: rect.minY + chartH, width: rect.width, height: capH)
        let pad = capH * 0.12
        let rawFont = capH * 0.42
        func chipW(_ m: HROverlayMetric) -> CGFloat { valueWidth(m, font: rawFont, pad: pad) }
        let kept = reflowed(metrics, keepLeading: min(2, metrics.count),
                            fits: { $0.reduce(0) { $0 + chipW($1) } <= capRect.width })
        let total = kept.reduce(0) { $0 + chipW($1) }
        let k = total > 0 ? min(1, capRect.width / total) : 1
        var x = capRect.minX + (capRect.width - total * k) / 2
        var slots: [MetricSlot] = []
        for m in kept {
            let w = chipW(m) * k
            slots.append(MetricSlot(metric: m, frame: CGRect(x: x, y: capRect.minY, width: w, height: capRect.height),
                                    role: m == kept.first ? .hero : .chip,
                                    fontSize: max(fontFloor, rawFont * (m == kept.first ? 1.05 : 1.0)),
                                    align: .center, showsLabel: false))
            x += w
        }
        return Result(tileRect: rect, chartRect: chartRect, slots: slots)
    }
}

// MARK: - Metric tile metadata (priority / caption / width estimate)

extension HROverlayMetric {
    /// Lower = more important — kept when the tile can't fit everything (the layout drops from the
    /// high-number end, i.e. recovery → calories → … → never bpm). The catalog's default metric order
    /// matches this, so "drop lowest priority" == "drop trailing field".
    var tilePriority: Int {
        switch self {
        case .bpm:      return 0
        case .zone:     return 1
        case .hrr:      return 2
        case .avgHR:    return 3
        case .maxHR:    return 4
        case .redline:  return 5
        case .strain:   return 6
        case .hrv:      return 7
        case .calories: return 8
        case .recovery: return 9
        }
    }

    /// Short uppercase caption shown next to / under the value in field / list / hero roles.
    var tileCaption: String {
        switch self {
        case .bpm:      return "BPM"
        case .zone:     return "ZONE"
        case .hrr:      return "HRR"
        case .avgHR:    return "AVG"
        case .maxHR:    return "PEAK"
        case .redline:  return "RDL"
        case .strain:   return "LOAD"
        case .hrv:      return "HRV"
        case .calories: return "KCAL"
        case .recovery: return "REC"
        }
    }

    /// Representative character count of the rendered value, for the layout's pure width estimate (it
    /// must size fields without the live HR data). Worst-case-ish so fields don't overflow.
    var tileValueChars: CGFloat {
        switch self {
        case .bpm:      return 4.5   // "♥ 156"
        case .zone:     return 3     // "Z3"
        case .hrr:      return 4     // "72%"
        case .avgHR:    return 4     // "142"
        case .maxHR:    return 4     // "178"
        case .redline:  return 4.5   // "🔥12%"
        case .strain:   return 3     // "86"
        case .hrv:      return 5     // "42ms"
        case .calories: return 5     // "320k"
        case .recovery: return 6     // "Ready"
        }
    }
}
