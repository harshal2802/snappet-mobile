import Foundation
import CoreGraphics

/// # Shared "Glass HUD" style kit (issue #163)
///
/// The premium visual language applied to **every** template — defined ONCE here as raw values (hex
/// strings + alphas + fraction-based radii), so the SwiftUI preview (`HRTileView`) and the
/// Core-Animation export (`StudioOverlays`) read the **same numbers** and can't drift. Platform-free
/// (just `CGFloat` + `String`); each render side converts the hex/alpha into its own colour type.
/// Radii are *fractions* of the rect (not absolute points) so a tile looks identical whether the rect
/// is in preview points (~hundreds wide) or export pixels (~1080 wide) — the scale-invariance that
/// makes WYSIWYG hold (see `decisions.md`).
enum HRTileStyle {
    static let glassFillHex = "#111928";   static let glassFillAlpha: CGFloat = 0.72
    static let chipFillHex  = "#1C2230";   static let chipFillAlpha: CGFloat  = 0.80
    static let hairlineHex  = "#FFFFFF";   static let hairlineAlpha: CGFloat  = 0.14
    static let heroTextHex  = "#F2F4F8"                                     // hero — never pure white
    static let valueAlpha: CGFloat   = 0.82                                // secondary value text
    static let captionAlpha: CGFloat = 0.55                                // uppercase micro-label
    static let scrimAlpha: CGFloat   = 0.42                                // floor-fade behind the tile
    static let shadowAlpha: CGFloat  = 0.38
    static let lineWidthFull: CGFloat = 3.5                                // HR Trace / full-lane curve
    static let lineWidthSpark: CGFloat = 2.6                               // sparkline under a hero
    static let areaTopAlpha: CGFloat = 0.42                                // curve area-fill top alpha
    static let curveGlowAlpha: CGFloat = 0.6

    /// Tile corner radius as a fraction of the smaller side (premium rounded card; scale-invariant).
    static func tileRadius(w: CGFloat, h: CGFloat) -> CGFloat { Swift.min(w, h) * 0.13 }
    /// Nested chip / pill corner radius from the chip height (a near-capsule).
    static func chipRadius(h: CGFloat) -> CGFloat { h * 0.34 }
}

/// # The unified HR stat **tile**
///
/// The configurable HR/fitness overlay was originally a set of free-floating `HROverlayElement`
/// badges, each independently placed. This replaces them with a **single, resizable, draggable
/// tile**: pick a *template* (the design), toggle each metric ON/OFF (all ON by default), and place
/// the one tile anywhere on the video. The pure `HRTileLayout` turns `(template, enabled metrics,
/// tile rect)` into per-metric slot frames — the single source of truth shared by the SwiftUI
/// preview and the Core-Animation export burn-in (so WYSIWYG holds), exactly like the older
/// per-element path fed both through `HROverlayValues`.
///
/// Everything here is **platform-free** (CoreGraphics only) and unit-tested in `SnappetTests`.

// MARK: - Template (the design catalog)

/// A tile design the user can pick from the catalog — the premium **"Glass HUD"** redesign (issue
/// #163). Each lays the SAME metrics out under a strict **hero → secondary → tertiary** hierarchy
/// (one big number, a few medium, the rest compact — never all 10 at equal size); the pure
/// `HRTileLayout` knows the geometry per case. The model `rawValue`s are unchanged from the #160–162
/// catalog (so persisted tiles + the studio walkthrough UITest's `studioTileTemplate.<raw>` ids keep
/// working); only the visual language, default frames, and spawn sets changed.
///
/// **Default = `hero` (Glass Hero Card), with the sparkline chart ON** — the most premium + legible +
/// general-purpose design (see `HROverlayConfig.default` / the editor's `toggleHROverlay`).
enum HRTileTemplate: String, Codable, CaseIterable, Sendable, Identifiable {
    /// **Glass Hero Card — the default.** Giant BPM hero + zone pill, a sparkline under it, then ≤3
    /// value-only chips (AVG · PEAK · KCAL). Most legible the instant it's placed; safest over any footage.
    case hero
    /// **Zone Ring Cluster.** A %HRR effort arc coloured by zone with BPM centred; ≤2 chips below.
    case ring
    /// **Broadcast Lower-Third.** A wide bottom strip — BPM hero + accent bar · 5-cell zone bar · right
    /// stat columns; a full-width chart lane grows under it when the chart is on.
    case scorebug
    /// **Vertical Glass Rail.** A slim right-edge column — BPM hero, a vertical zone bar, ≤5 label→value rows.
    case list
    /// **Gradient Strain Card.** A glass card whose gradient backing is driven by effort/zone; BPM hero +
    /// zone + %HRR, a value-only caption, and a bottom chart banner.
    case bento
    /// **Minimal HUD Pill.** A single capsule — zone dot · BPM · zone. The lightest, non-intrusive tag.
    case hudPill
    /// **HR Trace.** A wide bottom strap where the premium curve is the hero: BPM + zone pill on top, the
    /// full zone-banded trace in the middle, a 4-up AVG · PEAK · KCAL · EFFORT row below. Chart always on.
    case chartBanner

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hero:        return "Glass Hero"
        case .ring:        return "Zone Ring"
        case .scorebug:    return "Broadcast"
        case .list:        return "Rail"
        case .bento:       return "Strain"
        case .hudPill:     return "HUD Pill"
        case .chartBanner: return "HR Trace"
        }
    }

    /// SF Symbol for the catalog card.
    var systemImage: String {
        switch self {
        case .hero:        return "heart.text.square.fill"
        case .ring:        return "circle.dashed.inset.filled"
        case .scorebug:    return "rectangle.bottomthird.inset.filled"
        case .list:        return "rectangle.righthalf.inset.filled.arrow.right"
        case .bento:       return "flame.fill"
        case .hudPill:     return "capsule.fill"
        case .chartBanner: return "chart.xyaxis.line"
        }
    }

    /// Metrics that start **ON** when this template is first chosen — the **legible default set** for the
    /// design (a focused hero + secondary + a few tertiary, NOT all 10), so a freshly-placed tile reads
    /// cleanly before any toggle. The user can turn the rest on; the layout then caps + offers `+N · enlarge`
    /// (never crops). Order is priority order, so the layout's "drop the trailing low-priority" stays correct.
    var spawnMetrics: [HROverlayMetric] {
        switch self {
        case .hero:        return [.bpm, .zone, .avgHR, .maxHR, .calories]
        case .ring:        return [.bpm, .zone, .hrr, .avgHR, .maxHR]
        case .scorebug:    return [.bpm, .zone, .avgHR, .maxHR, .hrr]
        case .list:        return [.bpm, .zone, .hrr, .avgHR, .maxHR, .calories]
        case .bento:       return [.bpm, .zone, .hrr, .avgHR, .maxHR]
        case .hudPill:     return [.bpm, .zone]
        case .chartBanner: return [.bpm, .zone, .avgHR, .maxHR, .calories, .hrr]
        }
    }

    /// Whether the moving-playhead chart line is shown by default for this template (issue #163 table:
    /// HR Trace / Glass Hero / Broadcast / Gradient Strain default ON; Zone Ring / Rail / HUD Pill OFF).
    var spawnShowChart: Bool {
        switch self {
        case .hero, .scorebug, .bento, .chartBanner: return true
        case .ring, .list, .hudPill:                 return false
        }
    }

    /// Default normalized centre (0…1, top-left) when the tile is first placed (issue #163 table).
    var defaultCenter: CGPoint {
        switch self {
        case .hero:        return CGPoint(x: 0.30, y: 0.30)
        case .ring:        return CGPoint(x: 0.30, y: 0.32)
        case .scorebug:    return CGPoint(x: 0.50, y: 0.86)
        case .list:        return CGPoint(x: 0.84, y: 0.46)
        case .bento:       return CGPoint(x: 0.32, y: 0.32)
        case .hudPill:     return CGPoint(x: 0.50, y: 0.10)
        case .chartBanner: return CGPoint(x: 0.50, y: 0.81)
        }
    }

    /// Default normalized size (width, height as fractions of the canvas) when first placed — the larger
    /// defaults from issue #163 so a freshly-placed tile is legible before any resize. Broadcast / Strain
    /// / Glass Hero ship at their chart-on size (their chart defaults ON).
    var defaultSize: CGSize {
        switch self {
        case .hero:        return CGSize(width: 0.54, height: 0.36)
        case .ring:        return CGSize(width: 0.56, height: 0.34)
        case .scorebug:    return CGSize(width: 0.92, height: 0.27)
        case .list:        return CGSize(width: 0.30, height: 0.56)
        case .bento:       return CGSize(width: 0.50, height: 0.36)
        case .hudPill:     return CGSize(width: 0.58, height: 0.11)
        case .chartBanner: return CGSize(width: 0.92, height: 0.30)
        }
    }

    /// The minimum tile **height** (normalized) that keeps the chart register legible when it's on — the
    /// editor nudges `tile.height` up to this on chart-enable so the curve always has room (the pure
    /// layout carves the chart as a *fraction* to stay scale-invariant, so this normalized floor — not an
    /// absolute point height — is what guarantees "the curve is never cropped"; see `decisions.md`).
    var minHeightWithChart: Double {
        switch self {
        case .hero:        return 0.34   // hero + zone pill + sparkline + chip row
        case .scorebug:    return 0.24   // strip + full-width chart lane
        case .bento:       return 0.34
        case .chartBanner: return 0.26   // the curve IS the design
        case .ring, .list, .hudPill: return 0.30
        }
    }
}

// MARK: - Per-metric toggle row

/// One row of the tile's metric list: which metric, whether it's shown (`on` — the ON/OFF toggle,
/// all ON by default), and the live/animated flags (mirroring the legacy `HROverlayElement` so the
/// value resolution is unchanged). Stored **ordered** inside `HRTile.entries` so the layout is
/// deterministic. `colorHex` lets a user re-tint one metric.
struct HRTileMetricEntry: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var metricRaw: String
    /// The ON/OFF visibility toggle. **Defaults ON** — every metric is shown unless the user hides it.
    var on: Bool = true
    /// Track the playhead (a live, changing reading) vs. a single clip value. Forced off for metrics
    /// that don't support live (same rule as `HROverlayElement`).
    var live: Bool = false
    /// Animate the live reading in the export (per-value opacity cross-fade). Live-animatable only.
    var animated: Bool = false
    var colorHex: String = "#FFFFFF"

    var metric: HROverlayMetric { HROverlayMetric(rawValue: metricRaw) ?? .bpm }
    var isLive: Bool { metric.supportsLive && live }
    var isAnimated: Bool { isLive && metric.supportsAnimation && animated }

    init(metric: HROverlayMetric, on: Bool = true, colorHex: String = "#FFFFFF") {
        self.metricRaw = metric.rawValue
        self.on = on
        self.live = metric.supportsLive          // default a time-varying metric to live…
        self.animated = metric.supportsAnimation // …and animated, since that reads best
        self.colorHex = colorHex
    }

    private enum CodingKeys: String, CodingKey { case id, metricRaw, on, live, animated, colorHex }

    /// Migration-safe decode: every field but `metricRaw` is `decodeIfPresent ?? default`, because a
    /// non-optional property with a default value still **throws** on a missing key under synthesized
    /// `Codable` (the repo's documented gotcha) — so a tile persisted before a field existed still loads.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        metricRaw = try c.decode(String.self, forKey: .metricRaw)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        live = try c.decodeIfPresent(Bool.self, forKey: .live) ?? false
        animated = try c.decodeIfPresent(Bool.self, forKey: .animated) ?? false
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFFFFF"
    }
}

// MARK: - The tile

/// The single HR/fitness overlay tile: a `template`, an ordered set of per-metric `entries` (the
/// ON/OFF toggles), and a normalized `centre + size` that drives drag + corner-resize (the same
/// convention as a PiP / base-frame collage cell, so the existing `ResizableFrame` gesture + the
/// `ClipEditGeometry.pipRect` math are reused). `showChart` adds the moving-playhead line as a tile
/// register. Stored on `HROverlayConfig.tile` (nil = legacy chart-only / off).
struct HRTile: Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var templateRaw: String
    /// One entry per metric the tile knows about, **in display order**. `.on` is the visibility toggle.
    var entries: [HRTileMetricEntry]
    var centerX: Double = 0.5
    var centerY: Double = 0.80
    /// Tile size as fractions of the canvas (corner-resizable). Width floors at 0.14, height at 0.06
    /// so even the thinnest strip stays legible; both cap at 1 (full canvas).
    var width: Double = 0.62
    var height: Double = 0.16
    /// Draw the moving-playhead HR chart line as a tile register.
    var showChart: Bool = false
    /// Tint live-intensity readings by HR zone (vs. each entry's `colorHex`).
    var zoneColored: Bool = true

    /// Legibility floor for a corner-resize (raised in the #163 redesign from 0.14/0.06 so even the
    /// smallest tile a user can drag to stays readable before any reflow).
    static let minWidth = 0.18, minHeight = 0.09

    var template: HRTileTemplate { HRTileTemplate(rawValue: templateRaw) ?? .scorebug }

    var center: CGPoint {
        get { CGPoint(x: centerX, y: centerY) }
        set { centerX = min(1, max(0, newValue.x)); centerY = min(1, max(0, newValue.y)) }
    }
    var size: CGSize {
        get { CGSize(width: width, height: height) }
        set {
            width = min(1, max(HRTile.minWidth, newValue.width))
            height = min(1, max(HRTile.minHeight, newValue.height))
        }
    }

    /// The metrics to lay out, in display order — the layout input (entries the user has toggled ON).
    var enabledMetrics: [HROverlayMetric] { entries.filter(\.on).map(\.metric) }

    /// The entry for a metric (for the resolver's live/colour lookup), if present + on.
    func entry(for metric: HROverlayMetric) -> HRTileMetricEntry? {
        entries.first { $0.metric == metric && $0.on }
    }

    init(id: UUID = UUID(), template: HRTileTemplate, entries: [HRTileMetricEntry],
         center: CGPoint, size: CGSize, showChart: Bool, zoneColored: Bool = true) {
        self.id = id
        self.templateRaw = template.rawValue
        self.entries = entries
        self.centerX = min(1, max(0, center.x)); self.centerY = min(1, max(0, center.y))
        self.width = min(1, max(HRTile.minWidth, size.width))
        self.height = min(1, max(HRTile.minHeight, size.height))
        self.showChart = showChart
        self.zoneColored = zoneColored
    }

    /// Build a fresh tile for a template: one entry per metric in `HROverlayMetric.allCases` order,
    /// `.on` for the template's `spawnMetrics` (the rest appended `.off` so toggling them ON is
    /// instant and order is stable), placed at the template's default frame.
    static func make(template: HRTileTemplate) -> HRTile {
        let entries = HROverlayMetric.allCases.map {
            HRTileMetricEntry(metric: $0, on: template.spawnMetrics.contains($0))
        }
        return HRTile(template: template, entries: entries,
                      center: template.defaultCenter, size: template.defaultSize,
                      showChart: template.spawnShowChart)
    }

    /// Switch the template while **preserving** the user's per-metric toggles/colours/live flags —
    /// only the layout (and the default frame/chart, if the tile is still at the old template's
    /// defaults) changes. Metrics the new template has never seen keep their current state.
    func switchingTemplate(to newTemplate: HRTileTemplate) -> HRTile {
        var copy = self
        copy.templateRaw = newTemplate.rawValue
        // Ensure every metric still has an entry (defensive — older tiles may predate a metric).
        let known = Set(copy.entries.map(\.metric))
        for m in HROverlayMetric.allCases where !known.contains(m) {
            copy.entries.append(HRTileMetricEntry(metric: m, on: newTemplate.spawnMetrics.contains(m)))
        }
        return copy
    }

    // MARK: Codable (migration-safe)

    private enum CodingKeys: String, CodingKey {
        case id, templateRaw, entries, centerX, centerY, width, height, showChart, zoneColored
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        templateRaw = try c.decodeIfPresent(String.self, forKey: .templateRaw) ?? HRTileTemplate.scorebug.rawValue
        entries = try c.decodeIfPresent([HRTileMetricEntry].self, forKey: .entries) ?? []
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 0.80
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0.62
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.16
        showChart = try c.decodeIfPresent(Bool.self, forKey: .showChart) ?? false
        zoneColored = try c.decodeIfPresent(Bool.self, forKey: .zoneColored) ?? true
    }
}

// MARK: - Migration from the legacy free-floating elements

/// Folds a legacy `HROverlayConfig` (free-floating `elements` + a standalone chart) into a single
/// `HRTile`, with **zero data loss** — every element becomes an ON entry preserving its
/// metric/live/animated/colour, the remaining metrics are appended OFF, the template is inferred from
/// how many elements there were, and the tile's frame is the bounding box of the elements' positions.
/// Pure + deterministic so it's unit-tested; the view model calls it lazily on load.
enum HRTileMigration {

    /// The tile a legacy config should upgrade to, or `nil` if there's nothing to migrate
    /// (`tile` already set, or no elements and no chart).
    static func tile(from config: HROverlayConfig) -> HRTile? {
        guard config.tile == nil else { return nil }
        let elements = config.elements
        guard !elements.isEmpty || config.showChart else { return nil }

        let template = inferredTemplate(elementCount: elements.count, showChart: config.showChart)

        // ON entries first, in the elements' existing order (preserving their flags/colour)…
        var entries: [HRTileMetricEntry] = []
        var seen = Set<HROverlayMetric>()
        for el in elements where !seen.contains(el.metric) {
            seen.insert(el.metric)
            var e = HRTileMetricEntry(metric: el.metric, on: true, colorHex: el.colorHex)
            e.live = el.live
            e.animated = el.animated
            entries.append(e)
        }
        // …then every other metric, OFF, so toggling it on later is instant.
        for m in HROverlayMetric.allCases where !seen.contains(m) {
            entries.append(HRTileMetricEntry(metric: m, on: false))
        }

        let (center, size) = frame(for: elements, template: template)
        return HRTile(template: template, entries: entries, center: center, size: size,
                      showChart: config.showChart, zoneColored: config.zoneColored)
    }

    /// Template by element count (matches the catalog densities): chart-led → banner, 1–2 → pill,
    /// 3–5 → scorebug, many → bento.
    static func inferredTemplate(elementCount: Int, showChart: Bool) -> HRTileTemplate {
        if elementCount <= 1 && showChart { return .chartBanner }
        switch elementCount {
        case 0...2: return .hudPill
        case 3...5: return .scorebug
        default:    return .bento
        }
    }

    /// Centre = the midpoint of the elements' positions; size = their bounding box + padding. Falls
    /// back to the template default when there are no elements (chart-only migration).
    private static func frame(for elements: [HROverlayElement],
                              template: HRTileTemplate) -> (CGPoint, CGSize) {
        guard !elements.isEmpty else { return (template.defaultCenter, template.defaultSize) }
        let xs = elements.map(\.normalizedX), ys = elements.map(\.normalizedY)
        let minX = xs.min() ?? 0.5, maxX = xs.max() ?? 0.5
        let minY = ys.min() ?? 0.5, maxY = ys.max() ?? 0.5
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let padW = 0.18, padH = 0.10
        let size = CGSize(width: min(1, max(HRTile.minWidth, (maxX - minX) + padW)),
                          height: min(1, max(HRTile.minHeight, (maxY - minY) + padH)))
        return (center, size)
    }
}
