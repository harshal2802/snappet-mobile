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
// preview shows and the export burns: all three ask `ClipHeartRate`, the one resolver), aggregates
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
        // A BAKED clip's HR tile is in the pixels ("Save to original", prompt 117) — drawing the live
        // overlay on top would double-render the chart. The name-tag-only degrade, like photos.
        // A posted HIGHLIGHT REEL (highlights P2) is the same case: its glass scorebug was burned in
        // by ReelExporter, so the feed, browser, and fullscreen viewer all play it raw.
        // (Prompt 305: this is why the feed needs no time map for a baked clip. It is passed below
        // all the same, so a row that carries a map without the flag is still read through the
        // one rule and not from `offsetSec` alone.)
        guard !clip.isBaked, !clip.isReel else { return nil }
        // The one resolver (prompt 309): the kept (trimmed) footage, which the feed also PLAYS, read
        // through the clip's capture clock and widened by the clip's lead-in / tail. The Studio's
        // preview, its export and the poster chip ask the same function, so they cannot disagree.
        guard let values = resolve(clip: clip, hrSeries: hrSeries, maxHR: maxHR, restHR: restHR).data?.values
        else { return nil }
        // Use the saved Studio tile only if it would actually DRAW something with the feed's data — the
        // export/editor gate the same way via `resolveTile`. Otherwise fall back to the scorebug, so a
        // no-data custom tile (e.g. only kcal/HRV enabled with no chart) can't render an empty glass panel.
        let chosen: HRTile
        // `wouldDraw` = the resolveTile gate without building segments — this runs for EVERY clip on every
        // feed compose (prompt 163 made the tile explicit for all of them), so the full resolve cost 5.7 s.
        if let tile, values.wouldDraw(tile) { chosen = tile }
        else { chosen = .feedClipScorebug(restHR: restHR) }
        return Payload(tile: chosen, values: values)
    }

    /// What the resolver is asked for a feed clip: its kept footage and its own HR window (the
    /// clip's Studio edit, or the Studio's defaults for a clip never edited). ONE place, so the
    /// overlay (`make`), the poster chip (`FeedMedia.clipHR`) and the activity pages' average
    /// (`ActivityMediaIndex.averageBPM`) ask the same question.
    static func request(for clip: MediaInput, maxHR: Double?, restHR: Double?)
        -> (renditionStart: Double, renditionEnd: Double, options: ClipHROptions) {
        let footage = keptFootage(clip)
        let range = StudioHRPlacement.renditionRange(trimStart: footage.start,
                                                     trimEnd: footage.start + footage.span,
                                                     sourceDuration: footage.rawDur)
        return (range.start, range.end, .clip(edit: clip.edit, maxHR: maxHR, restHR: restHR))
    }

    /// A feed clip's heart rate from `ClipHeartRate`, the one resolver (prompt 309).
    static func resolve(clip: MediaInput, hrSeries: [HRPoint], maxHR: Double?, restHR: Double?) -> ClipHRResult {
        let ask = request(for: clip, maxHR: maxHR, restHR: restHR)
        return ClipHeartRate.resolve(series: hrSeries, clock: clip.captureClock,
                                     renditionStart: ask.renditionStart, renditionEnd: ask.renditionEnd,
                                     options: ask.options)
    }

    /// The peak and the average printed NEXT to a clip (the Recap poster chip, the activity
    /// pages' "♥ 132"): the numbers its overlay shows as PEAK and AVG, from the same resolver with
    /// the same request, without building a chart. A photo is one moment: its numbers are over
    /// `ClipHROptions.photo` (10 s either side). `nil` = no heart rate near the clip.
    static func summary(clip: MediaInput, hrSeries: [HRPoint]) -> ClipHRSummary? {
        guard clip.kind == "video" else {
            return ClipHeartRate.summary(series: hrSeries, clock: ClipCaptureClock(offsetSec: clip.offsetSec),
                                         renditionStart: 0, renditionEnd: 0, options: .photo)
        }
        let ask = request(for: clip, maxHR: nil, restHR: nil)
        return ClipHeartRate.summary(series: hrSeries, clock: clip.captureClock,
                                     renditionStart: ask.renditionStart, renditionEnd: ask.renditionEnd,
                                     options: ask.options)
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

    /// The clip's kept FOOTAGE — the one derivation shared by the chart window (`make`), the loop
    /// fold (`playedRange` == this), the poster, and the players, so they can't disagree about
    /// whether/where a clip is trimmed. Evaluated against the STORED (approximate) `durationSec` —
    /// every consumer uses the same input by design; the players additionally clamp the range's END
    /// against the real loaded duration for AVFoundation safety without changing the trim VERDICT
    /// (`ClipStudioEdit.keptRange` is the verdict rule). A nil-duration video falls back to the
    /// photo-window span (the pre-116 degenerate path).
    static func keptFootage(_ clip: MediaInput) -> (start: Double, span: Double, rawDur: Double) {
        let rawDur = clip.durationSec ?? FeedMedia.photoWindowSec
        if let kept = clip.durationSec.flatMap({ (clip.edit ?? ClipStudioEdit()).keptRange(rawDurationSec: $0) }) {
            return (kept.lowerBound, max(0.1, kept.upperBound - kept.lowerBound), rawDur)
        }
        return (0, max(0.1, rawDur), rawDur)
    }

    /// The clip's PLAYED range (seconds): the kept (trimmed) range when the Studio trimmed it — the
    /// feed plays exactly that (prompt 116) — else the raw duration. One denominator for the loop fold
    /// and the video-fraction mapping.
    static func playedRange(_ clip: MediaInput) -> (start: Double, span: Double) {
        let f = keptFootage(clip)
        return (f.start, f.span)
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
