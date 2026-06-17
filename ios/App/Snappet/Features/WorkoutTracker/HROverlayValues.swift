import Foundation
import HighlightEngine

/// Resolves an `HROverlayElement` to the **text + colour** to draw, for the configurable HR/fitness
/// video overlay (prompt 28). Pure — no AVFoundation, no SwiftUI rendering — so the value logic
/// (live-at-playhead, clip aggregates, and the animated-export segments) is unit-tested in
/// `SnappetTests`; the device-only Core-Animation renderer (`StudioOverlays`) and the SwiftUI preview
/// both consume this, so the burned-in file matches the preview.
///
/// Inputs are the clip's HR window already rebased to `[0, durationSec]` plus the profile bounds and
/// the precomputed energy (kcal needs the profile's age/weight/sex, resolved by the caller). Zone /
/// `%HRR` / recovery use `maxHR`/`restHR`; aggregates come from `WorkoutHRStats` over the window.
struct HROverlayValues {
    let samples: [HRPoint]
    let durationSec: Double
    let maxHR: Double?
    let restHR: Double?
    /// HR-based calorie estimate for this clip window (profile-gated; `nil` hides the calories element).
    let kcal: Double?
    /// HRV over this clip window (chest-strap RR only; `.empty` hides the HRV element).
    let hrv: HRVMetrics

    private let stats: WorkoutHRStats?

    init(samples: [HRPoint], durationSec: Double, maxHR: Double?, restHR: Double?,
         kcal: Double? = nil, hrv: HRVMetrics = .empty) {
        self.samples = samples
        self.durationSec = durationSec
        self.maxHR = maxHR
        self.restHR = restHR
        self.kcal = kcal
        self.hrv = hrv
        self.stats = WorkoutHRStats.make(from: samples, maxHR: maxHR ?? HeartRateZone.defaultMaxHR)
    }

    /// A resolved overlay reading: the string to draw + the `#RRGGBB` colour. Equatable so the export's
    /// segment de-duping can coalesce identical consecutive readings.
    struct Reading: Equatable, Sendable {
        var text: String
        var hex: String
    }

    private var effectiveMaxHR: Double { maxHR ?? HeartRateZone.defaultMaxHR }

    /// Smoothed bpm at a playhead fraction (0…1) — reuses the chart's interpolation.
    func bpm(atFraction f: Double) -> Double? { HRChartGeometry.sampleBPM(samples, atFraction: f) }

    private func hrrFraction(bpm: Double) -> Double? {
        guard let restHR, let mx = maxHR, mx > restHR else { return nil }
        return min(1, max(0, (bpm - restHR) / (mx - restHR)))
    }

    /// The live (playhead-tracking) reading for a time-varying metric, or `nil` if not live / no data.
    func live(_ metric: HROverlayMetric, atFraction f: Double, fallbackHex: String) -> Reading? {
        guard metric.supportsLive, let bpm = bpm(atFraction: f) else { return nil }
        let zone = HeartRateZone.forBpm(bpm, maxHR: effectiveMaxHR)
        switch metric {
        case .bpm:
            return Reading(text: "\(Int(bpm.rounded())) bpm", hex: zone.colorHex)
        case .zone:
            return zone == .none ? nil : Reading(text: zone.pillLabel, hex: zone.colorHex)
        case .hrr:
            guard let h = hrrFraction(bpm: bpm) else { return nil }
            return Reading(text: "\(Int((h * 100).rounded()))% effort", hex: zone.colorHex)
        case .recovery:
            switch RecoveryReadiness.evaluate(currentBpm: bpm, restBpm: restHR, maxBpm: maxHR).state {
            case .ready:      return Reading(text: "Recovered", hex: "#34C759")
            case .recovering: return Reading(text: "Recovering", hex: "#FF9500")
            case .unknown:    return nil
            }
        default:
            return nil
        }
    }

    /// The static (single clip-window value) reading for a metric, or `nil` when there's no data
    /// (empty HR, no profile for calories, no RR for HRV) — the caller hides the element.
    func staticValue(_ metric: HROverlayMetric, fallbackHex: String) -> Reading? {
        switch metric {
        case .bpm, .avgHR:
            guard let s = stats else { return nil }
            let z = HeartRateZone.forBpm(s.avgBpm, maxHR: effectiveMaxHR)
            return Reading(text: "\(Int(s.avgBpm.rounded())) avg bpm", hex: z.colorHex)
        case .maxHR:
            guard let s = stats else { return nil }
            let z = HeartRateZone.forBpm(s.maxBpm, maxHR: effectiveMaxHR)
            return Reading(text: "\(Int(s.maxBpm.rounded())) max bpm", hex: z.colorHex)
        case .zone:
            guard let s = stats else { return nil }
            let z = HeartRateZone.forBpm(s.avgBpm, maxHR: effectiveMaxHR)
            return z == .none ? nil : Reading(text: z.pillLabel, hex: z.colorHex)
        case .hrr:
            guard let s = stats, let h = hrrFraction(bpm: s.maxBpm) else { return nil }
            let z = HeartRateZone.forBpm(s.maxBpm, maxHR: effectiveMaxHR)
            return Reading(text: "\(Int((h * 100).rounded()))% peak", hex: z.colorHex)
        case .redline:
            guard let s = stats, s.totalSeconds > 0 else { return nil }
            return Reading(text: "\(Int((s.redlineFraction * 100).rounded()))% redline", hex: fallbackHex)
        case .strain:
            guard let s = stats else { return nil }
            return Reading(text: "Strain \(Int(s.edwardsTRIMP.rounded()))", hex: fallbackHex)
        case .hrv:
            guard let r = hrv.rmssd else { return nil }
            return Reading(text: "HRV \(Int(r.rounded())) ms", hex: fallbackHex)
        case .calories:
            guard let kcal else { return nil }
            return Reading(text: "\(Int(kcal.rounded())) kcal", hex: fallbackHex)
        case .recovery:
            return live(.recovery, atFraction: 1, fallbackHex: fallbackHex)   // end-of-clip state
        }
    }

    /// The reading to show for an element at a playhead fraction — live metrics track the playhead
    /// (falling back to the aggregate if the live read is unavailable), others show the aggregate.
    func reading(for element: HROverlayElement, atFraction f: Double) -> Reading? {
        if element.isLive {
            return live(element.metric, atFraction: f, fallbackHex: element.colorHex)
                ?? staticValue(element.metric, fallbackHex: element.colorHex)
        }
        return staticValue(element.metric, fallbackHex: element.colorHex)
    }

    /// One time-tiled display segment over the clip — `[start, end]` as fractions of the clip.
    struct Segment: Equatable, Sendable {
        var reading: Reading
        var start: Double
        var end: Double
    }

    /// The display segments over the whole clip for an element — for a **static** (or live-but-not-
    /// animated) element a single `[0,1]` segment; for an **animated live** element, the distinct
    /// readings over time (consecutive equal readings coalesced), tiled to cover `[0,1]`. Drives the
    /// export's opacity-keyframed text layers. Pure + deterministic → unit-tested.
    func segments(for element: HROverlayElement, steps: Int = 60) -> [Segment] {
        guard element.isAnimated else {
            // Static text for the whole clip (live-but-not-animated shows its clip-start reading).
            let f = element.isLive ? 0.0 : 0.0
            guard let r = reading(for: element, atFraction: f) else { return [] }
            return [Segment(reading: r, start: 0, end: 1)]
        }
        let n = max(2, steps)
        var raw: [(reading: Reading, f: Double)] = []
        for i in 0..<n {
            let f = Double(i) / Double(n - 1)
            if let r = reading(for: element, atFraction: f) { raw.append((r, f)) }
        }
        guard !raw.isEmpty else { return [] }
        // Coalesce consecutive equal readings into segments starting at each group's first fraction.
        var segs: [Segment] = []
        for item in raw {
            if segs.last?.reading == item.reading {
                segs[segs.count - 1].end = item.f
            } else {
                segs.append(Segment(reading: item.reading, start: item.f, end: item.f))
            }
        }
        // Tile to cover [0,1]: each segment runs until the next one begins; last extends to 1.
        for i in segs.indices {
            segs[i].start = i == 0 ? 0 : segs[i].start
            segs[i].end = i == segs.count - 1 ? 1 : segs[i + 1].start
        }
        return segs
    }

    /// Resolve a list of elements into render-ready overlays — placement + the display segments —
    /// dropping elements with no data (so the device renderer stays dumb and the same result feeds the
    /// preview and the export). Pure + `Sendable` → built where the session data lives, then handed to
    /// the AVFoundation render across the actor boundary.
    func resolve(_ elements: [HROverlayElement]) -> [ResolvedHROverlay] {
        elements.compactMap { el in
            let segs = segments(for: el)
            guard !segs.isEmpty else { return nil }
            return ResolvedHROverlay(normalizedX: el.normalizedX, normalizedY: el.normalizedY,
                                     scale: el.scale, segments: segs)
        }
    }

    /// Resolve an `HRTile` into a render-ready `ResolvedHRTile` — its template + geometry + each
    /// **enabled** metric's display segments — dropping metrics with no data (no profile for kcal, no
    /// RR for HRV, empty HR). Placement is NOT stored here: the pure `HRTileLayout` derives every slot
    /// from the template + the tile rect, so this is the tile twin of `resolve(_:)`. Returns `nil` when
    /// the tile would draw nothing (no metric with data **and** no chart). Pure + `Sendable`.
    func resolveTile(_ tile: HRTile) -> ResolvedHRTile? {
        let resolved: [ResolvedTileMetric] = tile.entries.filter(\.on).compactMap { entry in
            var el = HROverlayElement(metric: entry.metric, colorHex: entry.colorHex)
            el.live = entry.live
            el.animated = entry.animated
            let segs = segments(for: el)
            guard !segs.isEmpty else { return nil }
            return ResolvedTileMetric(metricRaw: entry.metricRaw, segments: segs)
        }
        guard !resolved.isEmpty || tile.showChart else { return nil }
        return ResolvedHRTile(templateRaw: tile.templateRaw, centerX: tile.centerX, centerY: tile.centerY,
                              width: tile.width, height: tile.height, showChart: tile.showChart,
                              zoneColored: tile.zoneColored, metrics: resolved)
    }
}

/// One enabled metric of an `HRTile`, resolved to its time-tiled display **segments** (text + colour),
/// ready for the device render — the tile analogue of `ResolvedHROverlay`, but with no per-element
/// position (the pure `HRTileLayout` places it). `Sendable` so it crosses the export actor boundary.
struct ResolvedTileMetric: Sendable, Equatable {
    var metricRaw: String
    var segments: [HROverlayValues.Segment]
    var metric: HROverlayMetric { HROverlayMetric(rawValue: metricRaw) ?? .bpm }
}

/// A fully-resolved HR stat **tile** ready to draw: the template + normalized geometry + which metrics
/// (with their segments) are on. The device-only `StudioOverlays.hrTileLayer` runs `HRTileLayout` over
/// this to place each metric inside one composite card and burns it in — the single-tile analogue of a
/// `[ResolvedHROverlay]`. Built by `HROverlayValues.resolveTile(_:)`.
struct ResolvedHRTile: Sendable, Equatable {
    var templateRaw: String
    var centerX: Double, centerY: Double, width: Double, height: Double
    var showChart: Bool
    var zoneColored: Bool
    var metrics: [ResolvedTileMetric]

    var template: HRTileTemplate { HRTileTemplate(rawValue: templateRaw) ?? .scorebug }
    var enabledMetrics: [HROverlayMetric] { metrics.map(\.metric) }
}

/// A fully-resolved overlay element ready to draw — placement + the time-tiled display segments (the
/// only thing the device-only Core-Animation / SwiftUI renderers need). `Sendable` so it crosses into
/// the AVFoundation export actor. Built by `HROverlayValues.resolve(_:)`.
struct ResolvedHROverlay: Sendable, Equatable {
    var normalizedX: Double
    var normalizedY: Double
    var scale: Double
    var segments: [HROverlayValues.Segment]
}
