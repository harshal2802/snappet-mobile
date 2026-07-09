import Foundation
import CoreGraphics

/// **Pure** model of a clip's *extended* HR window (prompt 115): the chart may show more of the
/// session's heart-rate story than the footage covers — a **lead-in** before `clip_start` and a
/// **tail** after `clip_end` (where a hard move's HR peak usually lands, 10–30 s after the effort) —
/// while the live playhead dot + BPM still track the video exactly across the footage span.
///
///     window = [clip_start − lead, clip_end + tail]      (capture-time seconds)
///     chart x-axis = the sliced window samples' `maxT`   (HRWindowSlicer clamps to real HR coverage)
///     live dot sweeps only [lead, lead + footage] of it
///
/// All fractions here are computed against the chart's own denominator (`maxT` — the LAST sliced
/// sample's window-local timestamp), NOT the nominal span, so a window that reaches past the session's
/// recorded HR (the slicer holds its endpoint at the data edge) keeps the dot, the region panes, and
/// the curve on one x-axis. Foundation-only → unit-tested in `SnappetTests` with no device.
struct HRClipWindow: Codable, Hashable, Sendable {
    /// Effective lead-in seconds (the builder clamps it so the window can't start before session t=0).
    var leadSec: Double
    /// Capture-time span of the visible (trimmed) footage. Speed doesn't change *which* HR the footage
    /// shows, so it plays no part here (fractions of the footage are speed-invariant).
    var footageSec: Double
    /// Requested tail seconds. Data-edge clamping is NOT applied here — it shows up naturally via the
    /// sliced samples' `maxT` (the slicer never fabricates samples past coverage).
    var tailSec: Double

    // Defaults + slider ranges (the approved wireframe: lead 0:05 of 0–0:30, tail 0:30 of 0–2:00).
    // 0/0 reproduces the pre-feature behaviour exactly (window == footage).
    static let defaultLeadSec: Double = 5
    static let defaultTailSec: Double = 30
    static let maxLeadSec: Double = 30
    static let maxTailSec: Double = 120

    /// A window that adds nothing around the footage — the pre-feature behaviour.
    static func footageOnly(_ footageSec: Double) -> HRClipWindow {
        HRClipWindow(leadSec: 0, footageSec: footageSec, tailSec: 0)
    }

    /// The nominal window span the slicer is asked for (lead + footage + tail), floored like the slicer.
    var spanSec: Double { max(0.001, leadSec + footageSec + tailSec) }

    /// Whether the window actually extends beyond the footage (drives the region panes — an
    /// unextended window renders exactly as before, no panes, no remap).
    var isExtended: Bool { leadSec > 0.0001 || tailSec > 0.0001 }

    /// The footage-start boundary as a fraction of the chart's x-axis (`maxT`).
    func footageStartFraction(maxT: Double) -> Double {
        maxT > 0 ? min(1, max(0, leadSec / maxT)) : 0
    }

    /// The footage-end boundary as a fraction of the chart's x-axis (`maxT`). Clamps to 1 when the
    /// data ends before the footage does (the dot then parks at the chart's right edge).
    func footageEndFraction(maxT: Double) -> Double {
        maxT > 0 ? min(1, max(footageStartFraction(maxT: maxT), (leadSec + footageSec) / maxT)) : 1
    }

    /// Map a **video-progress** fraction (0…1 of the footage, loop-folded/clamped by the caller) onto
    /// the chart's x-axis: the dot enters at the lead/footage boundary and parks at the footage/tail
    /// boundary — it never sweeps the off-camera regions.
    func chartFraction(videoFraction f: Double, maxT: Double) -> Double {
        guard maxT > 0 else { return 0 }
        let t = leadSec + min(1, max(0, f)) * footageSec
        return min(1, max(0, t / maxT))
    }
}

/// The "Variant A" styling for the extended window's chart regions — faint zone-tinted washes for the
/// off-camera lead/tail, a slightly brighter footage pane, and thin ember boundary ticks. ONE source of
/// truth for both renderers (SwiftUI `PremiumHRCurve` + the Core-Animation export), so preview == export.
/// The curve itself stays full-strength everywhere: the HR data is real, only camera coverage differs
/// (dashing is reserved for sparse/interpolated data, a different meaning).
enum HRWindowRegionStyle {
    /// Lead-in wash — Z2 teal (`HeartRateZone.easy`), "before the camera rolled".
    static let leadHex = "#30B0C7"
    static let leadAlpha: CGFloat = 0.12
    /// Footage wash — the Studio's ember accent, "what the video shows".
    static let footageHex = "#FF9645"
    static let footageAlpha: CGFloat = 0.12
    /// Tail wash — Z5-red-leaning, "the effort's after-story".
    static let tailHex = "#FF3B30"
    static let tailAlpha: CGFloat = 0.08
    /// The footage boundary ticks (ember, near-opaque, hairline).
    static let tickHex = "#FF9645"
    static let tickAlpha: CGFloat = 0.9
    static let tickWidth: CGFloat = 1

    /// One region pane, in chart-fraction space (`from`…`to` of the chart width).
    struct Pane: Equatable, Sendable {
        var from: Double
        var to: Double
        var hex: String
        var alpha: CGFloat
    }

    /// The pane segments for a chart whose footage occupies `[fs, fe]` of its x-axis — the ONE
    /// geometry both renderers consume (SwiftUI `PremiumHRCurve` + the Core-Animation export), so the
    /// epsilon/order/gating can't drift between preview and file. Zero-width panes are dropped.
    static func panes(footageStart fs: Double, footageEnd fe: Double) -> [Pane] {
        [Pane(from: 0, to: fs, hex: leadHex, alpha: leadAlpha),
         Pane(from: fs, to: fe, hex: footageHex, alpha: footageAlpha),
         Pane(from: fe, to: 1, hex: tailHex, alpha: tailAlpha)]
            .filter { $0.to - $0.from > 0.001 }
    }

    /// The boundary-tick x positions (chart fractions) for footage edges `fs`/`fe`: edge-adjacent
    /// ticks are dropped and a degenerate window (fs == fe) yields ONE tick, not two coincident ones
    /// (which would also collide as SwiftUI `ForEach` identities).
    static func tickXs(footageStart fs: Double, footageEnd fe: Double) -> [Double] {
        var xs = [fs, fe].filter { $0 > 0.001 && $0 < 0.999 }
        if xs.count == 2, abs(xs[0] - xs[1]) < 0.0001 { xs.removeLast() }
        return xs
    }
}

/// Which samples a clip tile's **aggregates** (AVG / PEAK / KCAL / HRV / effort) are computed over.
/// The chart always draws the full window; this only scopes the numbers.
enum HRMetricsScope: String, Codable, Hashable, Sendable, CaseIterable {
    /// Footage only — the pre-feature per-clip behaviour.
    case clip
    /// The full extended window — PEAK honestly includes an off-camera spike (the default: the
    /// feature exists to surface exactly that).
    case window

    static let `default`: HRMetricsScope = .window

    var label: String {
        switch self {
        case .clip:   return "Clip only"
        case .window: return "Full window"
        }
    }
}
