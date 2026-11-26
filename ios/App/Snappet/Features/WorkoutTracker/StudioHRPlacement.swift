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

enum StudioHRPlacement {

    /// The range of the video the asset plays now that a clip's trims keep: `trimEnd` clamped to
    /// the video's length, `trimStart` to 0. What `ClipHeartRate` is asked about (prompt 309):
    /// the window, the samples and the numbers for that range are the resolver's, for the Studio
    /// (`StudioEditorViewModel.clipHeartRate`) as for the feed (`ClipHROverlay.request`). Speed
    /// does not change WHICH heart rate the footage shows, so it is not part of the range.
    static func renditionRange(trimStart: Double, trimEnd: Double?,
                               sourceDuration: Double?) -> (start: Double, end: Double) {
        let src = sourceDuration ?? trimEnd ?? 0
        let end = min(trimEnd ?? src, src > 0 ? src : (trimEnd ?? 0))
        return (max(0, trimStart), end)
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
            if let offset = resolveOffset(of: clip, byMediaID: byMediaID, byLocalID: byLocalID) {
                out[clip.id] = offset
            }
        }
        return out
    }

    /// The single-clip form of the rule above. Production reads the offset together with the
    /// asset's time map through `resolveClock` (prompt 305), which uses the same lookup, so the
    /// tested policy can't drift from the shipping one.
    static func resolveOffset(of clip: TimelineClip, byMediaID: [UUID: Double],
                              byLocalID: [String: Double]) -> Double? {
        resolve(of: clip, byMediaID: byMediaID, byLocalID: byLocalID)
    }

    /// The lookup itself: the media link first, then the Photos identifier.
    private static func resolve<Value>(of clip: TimelineClip, byMediaID: [UUID: Value],
                                       byLocalID: [String: Value]) -> Value? {
        clip.sessionMediaID.flatMap { byMediaID[$0] } ?? byLocalID[clip.localIdentifier]
    }

    /// A clip's capture clock (prompt 305): its row's offset AND time map, found by the same
    /// rule as `resolveOffset`, so the two always come from one row. What
    /// `StudioEditorViewModel.captureClock` routes through.
    static func resolveClock(of clip: TimelineClip, byMediaID: [UUID: ClipCaptureClock],
                             byLocalID: [String: ClipCaptureClock]) -> ClipCaptureClock? {
        resolve(of: clip, byMediaID: byMediaID, byLocalID: byLocalID)
    }
}
