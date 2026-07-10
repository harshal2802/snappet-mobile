import Foundation

// MARK: - Clips feed — the ONE clip → HR+video overlay mapping (prompt 84 · extended prompt 116)
//
// Single source of truth for how a single clip maps to its HR overlay AND its live video-playhead, shared
// by every Clips surface: the still poster (static), the inline player, and the fullscreen viewer. Before
// this, the poster (`ClipPosterView`) and the viewer (`PagedMediaViewer`) each rebuilt the window → values
// → tile chain by hand, and each surface that wanted a live playhead would have computed `fraction` its own
// way — three chances to drift between "what the poster shows", "what plays inline", and "what the viewer
// plays". Centralizing it here means they cannot disagree.
//
// Prompt 116 (feed ⇄ Studio convergence): the mapping honours the clip's `MediaInput.edit` — the chart
// window is the **kept (trimmed) footage extended by the clip's lead/tail** (the SAME window the Studio
// preview shows and the export burns, via the shared `StudioHRPlacement.extendedWindow`), aggregates
// follow the clip's metrics scope, and the playhead maps **kept-range-relative** video time onto the
// chart via `HROverlayValues.chartFraction`. A clip with no Studio project gets the same defaults the
// Studio would apply (lead 0:05 · tail 0:30 · full-window scope) — never-edited clips tell the
// after-story too.
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
    /// %HRR (dropped when absent, via `HRTile.feedClipScorebug`). The values' window is rebased to
    /// window-local time and carries the clip's `HRClipWindow`, so it lines up with
    /// `fraction(videoTime:clip:)` below and `HRTileView` draws the same region panes the export burns.
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
        let edit = clip.edit ?? ClipStudioEdit()
        let rawDur = clip.durationSec ?? FeedMedia.photoWindowSec
        let kept = clip.durationSec.flatMap { edit.keptRange(rawDurationSec: $0) }
        // The SAME window builder the Studio preview + export use (prompt 115): footage = the kept
        // (trimmed) range — which the feed also PLAYS — widened by the clip's lead-in/tail, lead clamped
        // at session start.
        let ext = StudioHRPlacement.extendedWindow(offset: clip.offsetSec,
                                                   trimStart: kept?.lowerBound ?? 0,
                                                   trimEnd: kept?.upperBound,
                                                   sourceDuration: rawDur,
                                                   leadSec: edit.hrLeadSec, tailSec: edit.hrTailSec)
        let window = HRWindowSlicer.slice(hrSeries, start: ext.start, span: ext.window.spanSec)
        guard !window.isEmpty else { return nil }
        // Metrics scope (prompt 115 semantics): `.clip` re-slices the aggregates to the footage
        // sub-window; the chart always draws the full window.
        let clipScoped = edit.hrMetricsScope == .clip && ext.window.isExtended
        let scoped = clipScoped
            ? HRWindowSlicer.slice(window, start: ext.window.leadSec, span: ext.window.footageSec) : nil
        let values = HROverlayValues(samples: window, durationSec: ext.window.spanSec,
                                     maxHR: maxHR, restHR: restHR,
                                     window: ext.window,
                                     statsSamples: scoped,
                                     statsDurationSec: scoped != nil ? ext.window.footageSec : nil)
        // Use the saved Studio tile only if it would actually DRAW something with the feed's data — the
        // export/editor gate the same way via `resolveTile`. Otherwise fall back to the scorebug, so a
        // no-data custom tile (e.g. only kcal/HRV enabled with no chart) can't render an empty glass panel.
        let chosen: HRTile
        if let tile, values.resolveTile(tile) != nil { chosen = tile }
        else { chosen = .feedClipScorebug(restHR: restHR) }
        return Payload(tile: chosen, values: values)
    }

    /// The playhead `fraction` a NON-playing surface shows when it has no payload to consult — kept for
    /// initial `@State` values. With a payload, use `atEnd(for:)`: under an extended window the at-rest
    /// reading parks at the **footage/tail boundary** (the last on-camera reading — the peak label covers
    /// the tail), exactly where the export's dot parks.
    static let atEndFraction: Double = 1.0

    /// The at-rest (still poster / de-activated surface) playhead fraction for a clip's payload.
    static func atEnd(for payload: Payload?) -> Double {
        payload?.values.chartFraction(forVideoFraction: 1) ?? atEndFraction
    }

    /// The clip's PLAYED span (seconds): the kept (trimmed) range when the Studio trimmed it — the feed
    /// plays exactly that (prompt 116) — else the raw duration. One denominator for the loop fold and
    /// the video-fraction mapping. A photo (nil duration) uses the same default window the HR slice does.
    static func playedRange(_ clip: MediaInput) -> (start: Double, span: Double) {
        let rawDur = clip.durationSec ?? FeedMedia.photoWindowSec
        if let kept = clip.durationSec.flatMap({ (clip.edit ?? ClipStudioEdit()).keptRange(rawDurationSec: $0) }) {
            return (kept.lowerBound, max(0.1, kept.upperBound - kept.lowerBound))
        }
        return (0, max(0.1, rawDur))
    }

    /// Map a playing clip's current video time (seconds in ASSET time — what `player.currentTime()`
    /// reports for both the raw and the trimmed-range player; loop-relative is fine) to the HR tile's
    /// playhead `fraction` (0…1 of the chart's x-axis). The inline player and the fullscreen viewer feed
    /// THIS into `HRTileView(fraction:)` so the live BPM + chart dot track the video; a still poster
    /// shows `atEnd(for:)`.
    ///
    /// The mapping: asset time → kept-range-relative time (fold by the played span for the looping
    /// carousel; clamp for the fullscreen transport, which parks at the last frame) → video fraction →
    /// `HROverlayValues.chartFraction` — the SAME remap the Studio preview and the export keyframes use,
    /// so the dot enters at the lead/footage boundary and parks at the footage/tail boundary
    /// (normalized against the chart's real `maxT`, never the nominal span — decisions.md prompt-115).
    static func fraction(videoTime: Double, clip: MediaInput, payload: Payload, loops: Bool = true) -> Double {
        let played = playedRange(clip)
        guard videoTime.isFinite else { return atEnd(for: payload) }
        let rel = videoTime - played.start
        let t: Double
        if loops {
            let folded = rel.truncatingRemainder(dividingBy: played.span)
            t = folded < 0 ? folded + played.span : folded
        } else {
            t = min(played.span, max(0, rel))   // non-looping: rest at the end, don't wrap to 0
        }
        return payload.values.chartFraction(forVideoFraction: t / played.span)
    }
}
