import Foundation

/// **Pure** per-clip HR windowing for the multi-clip Studio — the fix for the headline bug where the
/// Studio drew the **whole session's** HR across the concatenated composition instead of each clip's
/// own capture moment (so a clip filmed at minute 25 of a 30-min session showed the session-wide
/// chart/aggregates, crammed to a chart edge). The single-clip editor already slices per clip; this is
/// that same idea generalized to N clips placed on an output timeline.
///
/// Foundation only (no AVFoundation / SwiftData), so the alignment math runs in `SnappetTests` with no
/// device. It produces, for each **video** clip (photos aren't rendered in S1), the session HR sliced
/// to that clip's visible (trimmed) capture window and rebased to clip-local time via `HRWindowSlicer`
/// (so the bracket/clamp guarantee carries over). The composer then places each clip's samples at the
/// clip's slot on the output timeline; the chart normalizes its own x-axis (`HRChartGeometry`) so the
/// rebased scale only needs to be clip-local, not output-seconds.
/// Per-clip HR **content** for the Studio export — what to draw for one clip, keyed by clip id. The
/// device-only `StudioComposer` joins this with the clip's computed output slot (which it owns) to make
/// a `PlacedClipHR`, keeping the slot math in the composer and the (pure, app-side) sample/badge
/// resolution in the view model.
struct StudioClipHRContent: Sendable, Equatable {
    var samples: [HRPoint]
    var elements: [ResolvedHROverlay]
    /// The resolved HR stat **tile** for this clip's window (the overlay redesign). When set, the
    /// composer draws one composite tile for the clip instead of the free-floating `elements`. `nil`
    /// for legacy element-based overlays. Additive default → existing constructions stay source-compatible.
    var tile: ResolvedHRTile? = nil
}

enum StudioHRPlacement {

    /// The session-time window `[start, start + span]` covering a clip's **visible** footage: the
    /// trimmed sub-range `[trimStart, trimEnd]` of the asset, offset by the clip's capture time
    /// (`SessionMedia.offsetSec`). Speed doesn't change *which* HR the footage shows, only how fast it
    /// plays, so it's not part of the window (the chart's playhead duration handles speed at render).
    static func captureWindow(offset: Double, trimStart: Double, trimEnd: Double?,
                              sourceDuration: Double?) -> (start: Double, span: Double) {
        let src = sourceDuration ?? trimEnd ?? 0
        let end = min(trimEnd ?? src, src > 0 ? src : (trimEnd ?? 0))
        let span = max(0.001, end - max(0, trimStart))
        return (offset + max(0, trimStart), span)
    }

    /// Per-clip sliced + rebased HR samples for the placed **video** clips, keyed by clip id. A clip
    /// whose capture window has no HR (honestly out of coverage) is absent from the result, so the
    /// composer draws no HR for it (rather than a misleading borrowed reading). `offsets[clipID]` is
    /// the clip's `SessionMedia.offsetSec`; clips with no resolved offset are skipped.
    static func sample(clips: [TimelineClip], offsets: [UUID: Double],
                       sourceDurations: [UUID: Double], series: [HRPoint],
                       clampTolerance: Double = HRWindowSlicer.defaultClampTolerance) -> [UUID: [HRPoint]] {
        guard !series.isEmpty else { return [:] }
        var out: [UUID: [HRPoint]] = [:]
        for clip in clips where !clip.isPhoto {
            guard let offset = offsets[clip.id] else { continue }
            let w = captureWindow(offset: offset, trimStart: clip.trimStart,
                                  trimEnd: clip.trimEnd, sourceDuration: sourceDurations[clip.id])
            let sliced = HRWindowSlicer.slice(series, start: w.start, span: w.span,
                                              clampTolerance: clampTolerance)
            if !sliced.isEmpty { out[clip.id] = sliced }
        }
        return out
    }
}
