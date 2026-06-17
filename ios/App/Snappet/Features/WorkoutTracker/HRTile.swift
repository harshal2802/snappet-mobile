import Foundation
import CoreGraphics

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

/// A tile design the user can pick from the catalog. Each lays the same metrics out differently;
/// the pure `HRTileLayout` knows the geometry per case. `scorebug` is the most intuitive default
/// (a broadcast-style lower-third bar led by a zone-colored bpm hero).
enum HRTileTemplate: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Broadcast lower-third strip — all metrics in one reflowing row, bpm hero leftmost. **Default.**
    case scorebug
    /// Single hero number (bpm) + zone pill; extras demoted to a small chip row.
    case hero
    /// 2×N grid card with the bpm hero spanning the top row.
    case bento
    /// Tall single-column label–value rail.
    case list
    /// Dial: a %HRR arc with the bpm centered, ring colored by current zone.
    case ring
    /// Minimal glass chip — bpm (+ up to two more) on one line.
    case hudPill
    /// Moving-playhead HR chart with a caption row of summary numbers under it.
    case chartBanner

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scorebug:    return "Scorebug"
        case .hero:        return "HR Hero"
        case .bento:       return "Stats Bento"
        case .list:        return "Metrics List"
        case .ring:        return "Zone Ring"
        case .hudPill:     return "HUD Pill"
        case .chartBanner: return "Chart Banner"
        }
    }

    /// SF Symbol for the catalog card.
    var systemImage: String {
        switch self {
        case .scorebug:    return "rectangle.bottomthird.inset.filled"
        case .hero:        return "heart.text.square.fill"
        case .bento:       return "square.grid.2x2.fill"
        case .list:        return "list.bullet.rectangle.fill"
        case .ring:        return "circle.dashed.inset.filled"
        case .hudPill:     return "capsule.fill"
        case .chartBanner: return "chart.xyaxis.line"
        }
    }

    /// Metrics that start **ON** when this template is first chosen. Compact templates (hero / pill)
    /// spawn a focused set so they don't look cluttered; every other template spawns **all** metrics —
    /// satisfying "by default all parameters are selected and shown". The user can toggle any of them.
    var spawnMetrics: [HROverlayMetric] {
        switch self {
        case .hero, .hudPill: return [.bpm, .zone]
        default:              return HROverlayMetric.allCases
        }
    }

    /// Whether the moving-playhead chart line is shown by default for this template.
    var spawnShowChart: Bool {
        switch self {
        case .chartBanner: return true     // the chart IS the point
        case .scorebug, .bento, .list, .ring, .hero, .hudPill: return false
        }
    }

    /// Default normalized centre (0…1, top-left) when the tile is first placed.
    var defaultCenter: CGPoint {
        switch self {
        case .scorebug:    return CGPoint(x: 0.5, y: 0.82)
        case .hero:        return CGPoint(x: 0.30, y: 0.30)
        case .bento:       return CGPoint(x: 0.5, y: 0.40)
        case .list:        return CGPoint(x: 0.80, y: 0.45)
        case .ring:        return CGPoint(x: 0.30, y: 0.32)
        case .hudPill:     return CGPoint(x: 0.5, y: 0.10)
        case .chartBanner: return CGPoint(x: 0.5, y: 0.80)
        }
    }

    /// Default normalized size (width, height as fractions of the canvas) when first placed.
    var defaultSize: CGSize {
        switch self {
        case .scorebug:    return CGSize(width: 0.88, height: 0.13)
        case .hero:        return CGSize(width: 0.46, height: 0.30)
        case .bento:       return CGSize(width: 0.52, height: 0.42)
        case .list:        return CGSize(width: 0.34, height: 0.52)
        case .ring:        return CGSize(width: 0.52, height: 0.30)
        case .hudPill:     return CGSize(width: 0.52, height: 0.08)
        case .chartBanner: return CGSize(width: 0.90, height: 0.26)
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

    static let minWidth = 0.14, minHeight = 0.06

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
