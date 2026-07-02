import Foundation

// MARK: - Clips feed — the ONE clip → HR+video overlay mapping (prompt 84)
//
// Single source of truth for how a single clip maps to its HR overlay AND its live video-playhead, shared
// by every Clips surface: the still poster (static), the inline player, and the fullscreen viewer. Before
// this, the poster (`ClipPosterView`) and the viewer (`PagedMediaViewer`) each rebuilt the window → values
// → tile chain by hand, and each surface that wanted a live playhead would have computed `fraction` its own
// way — three chances to drift between "what the poster shows", "what plays inline", and "what the viewer
// plays". Centralizing it here means they cannot disagree.
//
// Pure (Foundation + the app's HR value types; no SwiftUI / AVFoundation), so it unit-tests in `SnappetTests`.

enum ClipHROverlay {

    /// The render-ready HR overlay for one clip: the feed scorebug tile + its resolved values. `nil` when
    /// the clip's window holds no HR (the caller degrades to the name tag only — never an empty chart).
    /// `Sendable` — the Clips feed builds these on a background task (prompt 106).
    struct Payload: Sendable {
        var tile: HRTile
        var values: HROverlayValues
    }

    /// Build the overlay for `clip` from its owning session's HR context. `restHR` drives the scorebug's
    /// %HRR (dropped when absent, via `HRTile.feedClipScorebug`). The values' window is rebased to clip-local
    /// time, so it lines up with `fraction(videoTime:clip:)` below.
    ///
    /// `tile` overrides the house-style scorebug with the session's **saved Studio tile** (prompt 89,
    /// WYSIWYG) — its template / metrics / colours, rendered at the feed's own placement. `nil` (the
    /// default, and what the Recap viewer passes) keeps the fixed `.feedClipScorebug`.
    static func make(clip: MediaInput, hrSeries: [HRPoint], maxHR: Double, restHR: Double?,
                     tile: HRTile? = nil) -> Payload? {
        // Photos get NO overlay. A photo is a single instant, not a span of effort — a live HR scorebug
        // (a sweeping BPM + chart, AVG/PEAK computed over a *synthetic* `photoWindowSec` window) reads as
        // measured-over-time data the still doesn't carry, and there's no playhead for the dot to track.
        // Only a clip that plays through real time (a video) earns the overlay; a photo degrades to the
        // name tag, the same graceful path as the no-HR `nil` below. (Every caller already handles `nil`.)
        guard clip.kind == "video" else { return nil }
        let window = FeedMedia.clipHRWindow(offsetSec: clip.offsetSec, durationSec: clip.durationSec,
                                            hrSeries: hrSeries)
        guard !window.isEmpty else { return nil }
        let values = HROverlayValues(samples: window, durationSec: windowDuration(clip),
                                     maxHR: maxHR, restHR: restHR)
        // Use the saved Studio tile only if it would actually DRAW something with the feed's data — the
        // export/editor gate the same way via `resolveTile`. Otherwise fall back to the scorebug, so a
        // no-data custom tile (e.g. only kcal/HRV enabled with no chart) can't render an empty glass panel.
        let chosen: HRTile
        if let tile, values.resolveTile(tile) != nil { chosen = tile }
        else { chosen = .feedClipScorebug(restHR: restHR) }
        return Payload(tile: chosen, values: values)
    }

    /// The playhead `fraction` a NON-playing surface shows: the clip's at-end reading (the latest in-window
    /// HR), the still-poster default. One name so "still = at-end" isn't a bare `1.0` scattered across views.
    static let atEndFraction: Double = 1.0

    /// The clip-window length (seconds) the values' chart AND the playhead `fraction` BOTH measure against —
    /// one denominator so the live HR dot can't drift from the rendered window. A photo (nil duration) uses
    /// the same default window the HR slice does (`FeedMedia.photoWindowSec`).
    static func windowDuration(_ clip: MediaInput) -> Double {
        max(0.1, clip.durationSec ?? FeedMedia.photoWindowSec)
    }

    /// Map a playing clip's current video time (seconds; loop-relative is fine — folded modulo the clip
    /// duration) to the HR tile's playhead `fraction` (0…1). The inline player and the fullscreen viewer
    /// feed THIS into `HRTileView(fraction:)` so the live BPM + chart dot track the video; a still poster
    /// passes `1.0` (the clip's at-end reading). One definition of "video time → HR position".
    ///
    /// CRITICAL — normalize against the chart's axis, not the clip duration. `HRChartGeometry` (the dot,
    /// the live `bpm(atFraction:)`/`sampleBPM`, used by `PremiumHRCurve`/`HRTileView`) lays its x-axis on
    /// `maxT` = the LAST in-window HR sample's clip-local timestamp — NOT `durationSec`. The two only agree
    /// when HR samples reach the very end of the window; with realistic ~1s sampling (and badly in the
    /// sparse / ±8s-fallback window where `maxT ≪ duration`) they don't, so dividing by `durationSec` makes
    /// the live dot/BPM lag the true playhead. So: fold by the clip duration (the video's loop boundary),
    /// then normalize by `maxT` from the SAME window samples the chart draws.
    ///
    /// `loops` (default true) matches the inline carousel's `AVPlayerLooper`, where `videoTime == loop`
    /// wraps the video to frame 0 — so the dot must fold to 0 too. The fullscreen transport plays a
    /// NON-looping player (prompt 94) that parks at the last frame, so it passes `loops: false`: the time
    /// is clamped at `loop` (the dot rests at 1.0 at the end) instead of snapping back to the start.
    static func fraction(videoTime: Double, clip: MediaInput, payload: Payload, loops: Bool = true) -> Double {
        let loop = windowDuration(clip)                              // the video's loop boundary
        let maxT = payload.values.samples.map(\.t).max() ?? loop     // the chart's x-axis denominator
        guard loop > 0, maxT > 0, videoTime.isFinite else { return 0 }
        let t: Double
        if loops {
            let folded = videoTime.truncatingRemainder(dividingBy: loop)
            t = folded < 0 ? folded + loop : folded
        } else {
            t = min(loop, max(0, videoTime))   // non-looping: rest at the end, don't wrap to 0
        }
        return min(1, max(0, t / maxT))
    }
}
