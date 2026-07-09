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
    /// The resolved HR stat **tile** for this clip's window — one composite tile the composer draws at
    /// the clip's slot. `nil` when the clip has HR samples but no tile configured.
    var tile: ResolvedHRTile? = nil
}

/// One video clip's extended-window HR slice (prompt 115): the samples plus the window geometry the
/// renderers need to draw the region panes and confine the playhead to the footage span.
struct SampledClipHR: Sendable, Equatable {
    var samples: [HRPoint]
    var window: HRClipWindow
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

    /// The **extended** HR window for a clip (prompt 115): the footage capture window widened by the
    /// clip's lead-in/tail. The lead is clamped so the window can't start before session t=0 (the
    /// slicer would clamp anyway, but the *effective* lead must be known for the region/playhead math
    /// to stay aligned with what actually got sliced). The tail is passed through as requested — the
    /// slicer's coverage clamp surfaces via the sliced samples' `maxT`, which every fraction in
    /// `HRClipWindow` is computed against.
    static func extendedWindow(offset: Double, trimStart: Double, trimEnd: Double?,
                               sourceDuration: Double?, leadSec: Double, tailSec: Double)
        -> (start: Double, window: HRClipWindow) {
        let base = captureWindow(offset: offset, trimStart: trimStart, trimEnd: trimEnd,
                                 sourceDuration: sourceDuration)
        let lead = min(max(0, leadSec), base.start)
        let window = HRClipWindow(leadSec: lead, footageSec: base.span, tailSec: max(0, tailSec))
        return (base.start - lead, window)
    }

    /// Per-clip sliced + rebased HR samples for the placed **video** clips, keyed by clip id. A clip
    /// whose capture window has no HR (honestly out of coverage) is absent from the result, so the
    /// composer draws no HR for it (rather than a misleading borrowed reading). `offsets[clipID]` is
    /// the clip's `SessionMedia.offsetSec`; clips with no resolved offset are skipped.
    static func sample(clips: [TimelineClip], offsets: [UUID: Double],
                       sourceDurations: [UUID: Double], series: [HRPoint],
                       clampTolerance: Double = HRWindowSlicer.defaultClampTolerance) -> [UUID: [HRPoint]] {
        sampleExtended(clips: clips.map { var c = $0; c.hrLeadSec = 0; c.hrTailSec = 0; return c },
                       offsets: offsets, sourceDurations: sourceDurations, series: series,
                       clampTolerance: clampTolerance).mapValues(\.samples)
    }

    /// `sample`, but over each clip's **extended** window (its `hrWindowLeadSec`/`hrWindowTailSec`),
    /// returning the window geometry alongside the slice so the renderers can draw the region panes
    /// and confine the playhead to the footage span.
    static func sampleExtended(clips: [TimelineClip], offsets: [UUID: Double],
                               sourceDurations: [UUID: Double], series: [HRPoint],
                               clampTolerance: Double = HRWindowSlicer.defaultClampTolerance)
        -> [UUID: SampledClipHR] {
        guard !series.isEmpty else { return [:] }
        var out: [UUID: SampledClipHR] = [:]
        for clip in clips where !clip.isPhoto {
            guard let offset = offsets[clip.id] else { continue }
            let ext = extendedWindow(offset: offset, trimStart: clip.trimStart, trimEnd: clip.trimEnd,
                                     sourceDuration: sourceDurations[clip.id],
                                     leadSec: clip.hrWindowLeadSec, tailSec: clip.hrWindowTailSec)
            let sliced = HRWindowSlicer.slice(series, start: ext.start, span: ext.window.spanSec,
                                              clampTolerance: clampTolerance)
            if !sliced.isEmpty { out[clip.id] = SampledClipHR(samples: sliced, window: ext.window) }
        }
        return out
    }

    /// Resolve each clip's capture offset (seconds from session start): primary by its
    /// `SessionMedia.id` link, **falling back to the denormalized PHAsset `localIdentifier`** — this
    /// heals clips whose media link was lost (the "export burned the whole session's HR" bug: an
    /// unlinked clip used to fall through to the session-wide tile). Clips resolvable by neither are
    /// absent (the honest no-offset state).
    static func resolveOffsets(clips: [TimelineClip], byMediaID: [UUID: Double],
                               byLocalID: [String: Double]) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for clip in clips {
            if let offset = clip.sessionMediaID.flatMap({ byMediaID[$0] }) ?? byLocalID[clip.localIdentifier] {
                out[clip.id] = offset
            }
        }
        return out
    }
}
