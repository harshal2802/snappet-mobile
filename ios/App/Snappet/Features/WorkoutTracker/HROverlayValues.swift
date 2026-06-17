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

    /// A resolved overlay reading: the string(s) to draw + the `#RRGGBB` colour. Equatable so the
    /// export's segment de-duping can coalesce identical consecutive readings.
    ///
    /// Carries **two render forms** (the tile redesign): `text` is the legacy full inline string
    /// ("142 avg bpm") still used by the free-floating badge path; `value` + `unit` are the split form
    /// the unified tile uses — `value` is the value-ONLY string ("142", "72", "Z3 · Aerobic") with the
    /// caption (`metric.tileCaption`) supplying the label (~40% narrower → a top cropping fix), and
    /// `unit` is the inline suffix ("BPM", "%", "MS", "KCAL") drawn small beside the hero / wide rows
    /// (nil where the value is self-describing, e.g. the zone pill or a recovery state).
    struct Reading: Equatable, Sendable {
        var text: String
        var hex: String
        var value: String
        var unit: String?
        /// A 0…1 ratio for the metrics a gauge/bar can fill proportionally (%HRR effort, redline share) —
        /// drives the Zone Ring sweep arc and the zone bars. `nil` for everything else.
        var fraction: Double?

        init(text: String, hex: String, value: String? = nil, unit: String? = nil, fraction: Double? = nil) {
            self.text = text
            self.hex = hex
            self.value = value ?? text
            self.unit = unit
            self.fraction = fraction
        }
    }

    private var effectiveMaxHR: Double { maxHR ?? HeartRateZone.defaultMaxHR }
    /// The max HR the readings resolved against (a real profile's, else the 190 default) — carried into
    /// the resolved tile so the export's zone-banded chart tints against the SAME bound as the preview.
    var resolvedMaxHR: Double { effectiveMaxHR }

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
            let n = Int(bpm.rounded())
            return Reading(text: "\(n) bpm", hex: zone.colorHex, value: "\(n)", unit: "BPM")
        case .zone:
            return zone == .none ? nil : Reading(text: zone.pillLabel, hex: zone.colorHex, value: zone.pillLabel)
        case .hrr:
            guard let h = hrrFraction(bpm: bpm) else { return nil }
            let p = Int((h * 100).rounded())
            return Reading(text: "\(p)% effort", hex: zone.colorHex, value: "\(p)", unit: "%", fraction: h)
        case .recovery:
            switch RecoveryReadiness.evaluate(currentBpm: bpm, restBpm: restHR, maxBpm: maxHR).state {
            case .ready:      return Reading(text: "Recovered", hex: "#34C759", value: "Recovered")
            case .recovering: return Reading(text: "Recovering", hex: "#FF9500", value: "Recovering")
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
            let n = Int(s.avgBpm.rounded())
            return Reading(text: "\(n) avg bpm", hex: z.colorHex, value: "\(n)", unit: "BPM")
        case .maxHR:
            guard let s = stats else { return nil }
            let z = HeartRateZone.forBpm(s.maxBpm, maxHR: effectiveMaxHR)
            let n = Int(s.maxBpm.rounded())
            return Reading(text: "\(n) max bpm", hex: z.colorHex, value: "\(n)", unit: "BPM")
        case .zone:
            guard let s = stats else { return nil }
            let z = HeartRateZone.forBpm(s.avgBpm, maxHR: effectiveMaxHR)
            return z == .none ? nil : Reading(text: z.pillLabel, hex: z.colorHex, value: z.pillLabel)
        case .hrr:
            guard let s = stats, let h = hrrFraction(bpm: s.maxBpm) else { return nil }
            let z = HeartRateZone.forBpm(s.maxBpm, maxHR: effectiveMaxHR)
            let p = Int((h * 100).rounded())
            return Reading(text: "\(p)% peak", hex: z.colorHex, value: "\(p)", unit: "%", fraction: h)
        case .redline:
            guard let s = stats, s.totalSeconds > 0 else { return nil }
            let p = Int((s.redlineFraction * 100).rounded())
            return Reading(text: "\(p)% redline", hex: fallbackHex, value: "\(p)", unit: "%", fraction: s.redlineFraction)
        case .strain:
            guard let s = stats else { return nil }
            let n = Int(s.edwardsTRIMP.rounded())
            return Reading(text: "Strain \(n)", hex: fallbackHex, value: "\(n)")
        case .hrv:
            guard let r = hrv.rmssd else { return nil }
            let n = Int(r.rounded())
            return Reading(text: "HRV \(n) ms", hex: fallbackHex, value: "\(n)", unit: "MS")
        case .calories:
            guard let kcal else { return nil }
            let n = Int(kcal.rounded())
            return Reading(text: "\(n) kcal", hex: fallbackHex, value: "\(n)", unit: "KCAL")
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

    /// Resolve an `HRTile` into a render-ready `ResolvedHRTile` — its template + geometry + each
    /// **enabled** metric's display segments — dropping metrics with no data (no profile for kcal, no
    /// RR for HRV, empty HR). Placement is NOT stored here: the pure `HRTileLayout` derives every slot
    /// from the template + the tile rect. Returns `nil` when the tile would draw nothing (no metric with
    /// data **and** no chart). Pure + `Sendable`.
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
                              zoneColored: tile.zoneColored, maxHR: resolvedMaxHR,
                              opacity: tile.opacity, metrics: resolved)
    }
}

/// One enabled metric of an `HRTile`, resolved to its time-tiled display **segments** (text + colour),
/// ready for the device render — with no per-element position (the pure `HRTileLayout` places it).
/// `Sendable` so it crosses the export actor boundary.
struct ResolvedTileMetric: Sendable, Equatable {
    var metricRaw: String
    var segments: [HROverlayValues.Segment]
    var metric: HROverlayMetric { HROverlayMetric(rawValue: metricRaw) ?? .bpm }
}

/// A fully-resolved HR stat **tile** ready to draw: the template + normalized geometry + which metrics
/// (with their segments) are on. The device-only `StudioOverlays.hrTileLayer` runs `HRTileLayout` over
/// this to place each metric inside one composite card and burns it in. Built by
/// `HROverlayValues.resolveTile(_:)`.
struct ResolvedHRTile: Sendable, Equatable {
    var templateRaw: String
    var centerX: Double, centerY: Double, width: Double, height: Double
    var showChart: Bool
    var zoneColored: Bool
    /// The max HR the readings resolved against — so the export's zone-banded chart tints against the
    /// SAME bound as the preview (WYSIWYG). Defaulted to the 190 fallback for back-compat decodes.
    var maxHR: Double = HeartRateZone.defaultMaxHR
    /// Whole-tile opacity the user set — applied to the export's content layer so the burn-in matches
    /// the preview. Defaulted to fully opaque for back-compat.
    var opacity: Double = 1.0
    var metrics: [ResolvedTileMetric]

    var template: HRTileTemplate { HRTileTemplate(rawValue: templateRaw) ?? .hero }
    var enabledMetrics: [HROverlayMetric] { metrics.map(\.metric) }
}

