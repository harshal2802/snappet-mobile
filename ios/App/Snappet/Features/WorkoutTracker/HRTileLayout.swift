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
    /// `hiddenCount` is how many **enabled** metrics didn't make it onto the tile (per-template cap +
    /// fit reflow) — the editor surfaces it as a `+N · enlarge tile` affordance so "toggle all 10 on"
    /// fills the legible tier and parks the rest, instead of cropping (rules #6/#7).
    struct Result: Equatable, Sendable {
        var tileRect: CGRect
        var chartRect: CGRect?
        var slots: [MetricSlot]
        var hiddenCount: Int = 0
    }

    // MARK: - Entry point

    static func layout(template: HRTileTemplate, enabledMetrics: [HROverlayMetric],
                       tileRect rect: CGRect, hasChart: Bool) -> Result {
        // Per-template **hard visible cap** (rule #6): one hero + secondary + tertiary, never all 10 at
        // equal size. Keep the highest-priority prefix (the catalog order IS priority order); the rest
        // become `hiddenCount` → `+N · enlarge`. The per-template reflow may drop further if the rect is
        // tiny, and that's counted into `hiddenCount` too.
        let cap = visibleCap(template, hasChart: hasChart)
        let metrics = Array(enabledMetrics.prefix(cap))
        var result: Result
        switch template {
        case .scorebug:    result = scorebug(metrics, rect, hasChart)
        case .hero:        result = heroCard(metrics, rect, hasChart)
        case .bento:       result = bento(metrics, rect, hasChart)
        case .list:        result = list(metrics, rect, hasChart)
        case .ring:        result = ring(metrics, rect, hasChart)
        case .hudPill:     result = hudPill(metrics, rect, hasChart)
        case .chartBanner: result = chartBanner(metrics, rect, hasChart)
        }
        // Count DISTINCT rendered metrics — ring can emit one metric as both a gauge and a hero/chip, so
        // slots.count overstates coverage; the parked count must reflect metrics not shown at all.
        result.hiddenCount = Swift.max(0, enabledMetrics.count - Set(result.slots.map(\.metric)).count)
        return result
    }

    /// The per-template hard ceiling on visible metrics (hero + medium + chips) — issue #163, rule #6.
    static func visibleCap(_ t: HRTileTemplate, hasChart: Bool) -> Int {
        switch t {
        case .hero:        return 5   // hero + zone pill + ≤3 chips
        case .ring:        return 4   // gauge + centred hero + ≤2 chips
        case .scorebug:    return 4   // hero + zone bar + ≤3 right stats
        case .list:        return 6   // hero + ≤5 rows
        case .bento:       return 6
        case .hudPill:     return 3   // zone-dot · bpm · zone
        case .chartBanner: return 4   // bpm + zone + 4-up row reduces to a hero + chips set
        }
    }

    // MARK: - Shared helpers

    /// The lead/hero metric = the first enabled one (the catalog's default order is also priority
    /// order, so this is bpm when bpm is on, else the next most-important enabled metric).
    private static func hero(_ metrics: [HROverlayMetric]) -> HROverlayMetric? { metrics.first }

    /// Em-advance for the **honest** width estimate — ~0.66 for the semibold SF Rounded *tabular*
    /// numerals the tile draws on both sides (rule #3). Replaces the old fictional 0.62 × inline-string
    /// guess; combined with the value-only `tileValueChars` it's the single biggest on-device crop fix.
    static let emAdvance: CGFloat = 0.66

    /// Honest rendered width of a metric's **value-only** string at `font` + padding (pure — no HR data,
    /// so it uses the value FORMAT's worst-case char count, which is stable across the clip so the layout
    /// doesn't reflow frame-to-frame). Inline-unit roles add the unit separately.
    private static func valueWidth(_ m: HROverlayMetric, font: CGFloat, pad: CGFloat) -> CGFloat {
        m.tileValueChars * font * emAdvance + pad * 2
    }

    /// A value-only **chip's** width: wide enough for BOTH the value and its (often wider) uppercase
    /// caption ("EFFORT" > "72"), since they stack centred (rule #4). Caption is rendered ~0.42× the value.
    private static func chipWidth(_ m: HROverlayMetric, font: CGFloat, pad: CGFloat) -> CGFloat {
        let vw = m.tileValueChars * font * emAdvance
        let cw = CGFloat(m.tileCaption.count) * font * 0.46 * emAdvance
        return Swift.max(vw, cw) + pad * 2
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

    /// Inset a tile rect by a fraction of each dimension so content reads as a padded **card** (the glass
    /// kit), not edge-to-edge text. Fraction-based → scale-invariant (preview points == export pixels).
    private static func inset(_ rect: CGRect, by f: CGFloat) -> CGRect {
        rect.insetBy(dx: rect.width * f, dy: rect.height * f)
    }

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

    // MARK: - ① Glass Hero Card (the default): zone pill · giant BPM hero · sparkline · value-only chips

    /// The premium default (issue #163 ①). Top-to-bottom: a **zone pill** (top-left), the **giant BPM
    /// hero** (value + small inline unit), an optional **sparkline** tucked under it, then a row of ≤3
    /// **value-only chips** (AVG · PEAK · KCAL — value + uppercase caption, never the wide inline string).
    /// The hero owns the dominant visual weight (rule #1); content is inset from the glass edge so it
    /// reads as a card, not edge-to-edge text.
    private static func heroCard(_ metrics: [HROverlayMetric], _ rawRect: CGRect, _ hasChart: Bool) -> Result {
        guard let lead = hero(metrics) else { return empty(rawRect) }
        let rect = inset(rawRect, by: 0.07)
        var slots: [MetricSlot] = []
        let others = metrics.filter { $0 != lead }
        let hasZone = others.contains(.zone)
        let chips = others.filter { $0 != .zone }

        // Vertical budget (fractions → scale-invariant). The hero takes whatever the pill/sparkline/chips
        // leave, so it stays the dominant ~45–55%.
        let pillH  = hasZone ? rect.height * 0.17 : 0
        let chipsH = chips.isEmpty ? 0 : rect.height * 0.22
        let chartH = hasChart ? rect.height * 0.20 : 0
        let heroH  = max(rect.height * 0.30, rect.height - pillH - chartH - chipsH)

        var y = rect.minY
        if hasZone {
            slots.append(MetricSlot(metric: .zone,
                                    frame: CGRect(x: rect.minX, y: y, width: rect.width, height: pillH),
                                    role: .pill, fontSize: max(fontFloor, pillH * 0.46),
                                    align: .leading, showsLabel: false))
            y += pillH
        }
        slots.append(MetricSlot(metric: lead,
                                frame: CGRect(x: rect.minX, y: y, width: rect.width, height: heroH),
                                role: .hero, fontSize: max(fontFloor, heroH * 0.66),
                                align: .leading, showsLabel: false))
        y += heroH

        var chartRect: CGRect?
        if hasChart {
            chartRect = CGRect(x: rect.minX, y: y, width: rect.width, height: chartH)
            y += chartH
        }

        if !chips.isEmpty {
            let n = chips.count
            let gap = rect.width * 0.04
            let chipW = (rect.width - gap * CGFloat(n - 1)) / CGFloat(n)
            // Cap the chip font so the widest value OR caption (the caption renders ~0.62× the value)
            // fits chipW with a safety margin — the layout GUARANTEES fit instead of leaning on clip/scale
            // (rule #11; a 4-digit "1999" kcal used to overflow the column at the default size). The
            // showsLabel gate uses the UNfloored font so it stays scale-invariant (the 11pt floor never
            // leaks into the fit decision — preview points == export pixels).
            let safety = chipW * 0.08
            let need = chips.map { Swift.max($0.tileValueChars, CGFloat($0.tileCaption.count) * 0.62) }.max() ?? 3
            let widthCapFont = (chipW - 2 * safety) / (Swift.max(1, need) * emAdvance)
            let chipFontRaw = Swift.min(chipsH * 0.46, widthCapFont)
            let chipFont = Swift.max(fontFloor, chipFontRaw)
            let showsLabel = chipsH >= chipFontRaw * 2.0   // room for caption above value
            var x = rect.minX
            for m in chips {
                slots.append(MetricSlot(metric: m,
                                        frame: CGRect(x: x, y: y, width: chipW, height: chipsH),
                                        role: .chip, fontSize: chipFont, align: .center, showsLabel: showsLabel))
                x += chipW + gap
            }
        }
        return Result(tileRect: rawRect, chartRect: chartRect, slots: slots)
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

    /// Worst-case character count of the **value-only** rendered string (the redesign — `142`, not
    /// `142 avg bpm`), for the layout's honest pure width estimate. It must size slots without the live
    /// HR data, so this is the value FORMAT's worst case (stable across the clip → no frame-to-frame
    /// reflow). The inline unit ("BPM"/"%"/…) and the caption are sized separately by the layout.
    var tileValueChars: CGFloat {
        switch self {
        case .bpm:      return 3     // "188"
        case .zone:     return 13    // "Z4 · Threshold"
        case .hrr:      return 3     // "100"
        case .avgHR:    return 3     // "188"
        case .maxHR:    return 3     // "188"
        case .redline:  return 3     // "100"
        case .strain:   return 3     // "999"
        case .hrv:      return 3     // "199"
        case .calories: return 4     // "1999"
        case .recovery: return 10    // "Recovering"
        }
    }
}
