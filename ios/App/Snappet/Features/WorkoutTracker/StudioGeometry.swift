import Foundation

/// **Pure** timeline + animation math for the full studio (S1) — Foundation only, no AVFoundation /
/// SwiftData / UIKit, so it runs in `SnappetTests` with no device (the `StudioComposer` that turns
/// the result into pixels is the device-only half). All inputs/outputs are seconds / scalars /
/// normalized values, so the same math holds at any render size — the `ClipEditGeometry` philosophy,
/// generalized from one clip to a multi-clip timeline.
enum StudioGeometry {

    /// Allowed playback-rate range (mirrors `ClipEditGeometry.clampSpeed`).
    static func clampSpeed(_ s: Double) -> Double { min(4.0, max(0.25, s)) }

    /// Clips in deterministic track order: by `order`, ties broken by `id` (so a render is stable).
    static func ordered(_ clips: [TimelineClip]) -> [TimelineClip] {
        clips.sorted { $0.order != $1.order ? $0.order < $1.order : $0.id.uuidString < $1.id.uuidString }
    }

    /// Restrict a clip list to the clips backed by one of `mediaIDs` (matching `sessionMediaID`).
    /// `nil` means "no filter" (the whole list) — the default the workout studio uses; a set scopes
    /// the shared studio to one clip (per-clip) or one climb's clips (per-climb). A clip with no
    /// `sessionMediaID` is excluded whenever a set is supplied (it can't be addressed by media id).
    static func filterByMedia(_ clips: [TimelineClip], to mediaIDs: Set<UUID>?) -> [TimelineClip] {
        guard let mediaIDs else { return clips }
        return clips.filter { $0.sessionMediaID.map(mediaIDs.contains) ?? false }
    }

    /// Restrict an OVERLAY list to the overlays whose owning clip is in scope — the overlay analogue of
    /// `filterByMedia`. Overlays key on `clipID` (a `TimelineClip.id`), NOT `sessionMediaID`, so they
    /// can't reuse `filterByMedia`; this bridges `clipID → owning clip → sessionMediaID → membership`.
    /// `nil` = no filter (the whole-workout view). A `clipID == nil` overlay (a whole-project text/sticker,
    /// or an unbound climb tag) is kept in EVERY scope; a clip-bound overlay is kept iff its owning clip
    /// (looked up in the FULL `clips`) is backed by one of `mediaIDs`; an orphan (clip gone / no media id)
    /// is dropped while scoping. Pure → unit-tested. (prompt 13: the single-clip editor + overlay lane +
    /// export were showing OTHER clips' per-clip climb tags because overlays were never scoped with clips.)
    static func filterOverlays(_ overlays: [OverlayItem], clips: [TimelineClip],
                               to mediaIDs: Set<UUID>?) -> [OverlayItem] {
        guard let mediaIDs else { return overlays }
        let visibleClipIDs = Set(clips.compactMap { clip in
            (clip.sessionMediaID.map(mediaIDs.contains) ?? false) ? clip.id : nil
        })
        return overlays.filter { ov in
            guard let clipID = ov.clipID else { return true }   // whole-project overlay → shows in every scope
            return visibleClipIDs.contains(clipID)
        }
    }

    /// Destination index in the **full** ordered list for moving `id` by `delta` positions among the
    /// *visible* subset — so a reorder inside a scoped studio swaps with the adjacent **visible**
    /// neighbor without disturbing the hidden clips' order. `visible` and `full` must already be
    /// `ordered(_:)`. Returns `nil` when the move runs off either end of the visible subset. With no
    /// scoping (`visible == full`) this is just the neighbor index — i.e. the plain `index + delta`.
    static func reorderDestination(id: UUID, by delta: Int,
                                   visible: [TimelineClip], full: [TimelineClip]) -> Int? {
        guard let vIdx = visible.firstIndex(where: { $0.id == id }) else { return nil }
        let target = vIdx + delta
        guard visible.indices.contains(target) else { return nil }
        return full.firstIndex(where: { $0.id == visible[target].id })
    }

    /// A clip's **output** (edited) duration. Photo → its on-screen duration. Video → the trimmed
    /// source span (`trimEnd ?? sourceDuration` minus `trimStart`, clamped to the source) divided by
    /// speed. `sourceDuration` is the asset's real length (nil until the asset loads).
    static func clipOutputDuration(_ clip: TimelineClip, sourceDuration: Double?) -> Double {
        if clip.isPhoto { return max(0, clip.photoDurationSec) }
        let src = sourceDuration ?? clip.trimEnd ?? 0
        let end = clip.trimEnd ?? src
        let trimmed = max(0, min(end, src) - clip.trimStart)
        return trimmed / clampSpeed(clip.speed)
    }

    /// A clip placed on the output timeline.
    struct PlacedClip: Equatable, Sendable {
        let clip: TimelineClip
        let startSec: Double
        let durationSec: Double
        var endSec: Double { startSec + durationSec }
    }

    /// Lay the clips end-to-end on the output timeline, pulling each clip earlier by any transition
    /// that follows the previous one (the transition is an **overlap** the two clips share, clamped
    /// to neither clip being shorter than the overlap). A `.none` transition is a hard cut (no
    /// overlap). `sourceDurations` maps clip id → source length (videos); photos use their own.
    static func timeline(clips: [TimelineClip], sourceDurations: [UUID: Double],
                         transitions: [StudioTransition]) -> [PlacedClip] {
        let seq = ordered(clips)
        var placed: [PlacedClip] = []
        var cursor = 0.0
        for (i, clip) in seq.enumerated() {
            let d = clipOutputDuration(clip, sourceDuration: sourceDurations[clip.id])
            placed.append(PlacedClip(clip: clip, startSec: cursor, durationSec: d))
            cursor += d
            guard i + 1 < seq.count,
                  let t = transitions.first(where: { $0.afterClipID == clip.id }), t.kind != .none
            else { continue }
            let next = seq[i + 1]
            let nextD = clipOutputDuration(next, sourceDuration: sourceDurations[next.id])
            cursor -= min(t.durationSec, d, nextD)   // overlap can't exceed either clip
        }
        return placed
    }

    /// Total output duration of the timeline (the end of the last-ending clip).
    static func totalDuration(clips: [TimelineClip], sourceDurations: [UUID: Double],
                              transitions: [StudioTransition]) -> Double {
        timeline(clips: clips, sourceDurations: sourceDurations, transitions: transitions)
            .map(\.endSec).max() ?? 0
    }

    // MARK: - Overlay windows against the end of the timeline (prompt 297)

    /// The shortest on-screen window an overlay can have (seconds) — the lane bar can't collapse
    /// below it, and a dragged bar keeps at least this much inside the timeline.
    static let minOverlayWindowSec = 0.2

    /// An overlay window `[start, end]` cut to the timeline `[0, total]`. Returns `nil` when the
    /// window starts at or after the end, so nothing of it would play. `total` of `nil` or `≤ 0`
    /// means the length is not known (no clips, or durations not loaded yet): the window is
    /// returned unchanged, so an overlay is never dropped on a guess.
    static func clampedWindow(start: Double, end: Double, total: Double?) -> (start: Double, end: Double)? {
        guard let total, total > 0 else { return (start, end) }
        let lo = max(0, start)
        guard lo < total else { return nil }
        return (lo, max(lo, min(end, total)))
    }

    /// Overlays as they are RENDERED on a timeline of length `total`: each window is cut to the
    /// timeline, and an overlay that starts at or after the end is left out. A trim, a speed change,
    /// a delete or a split can shorten the timeline under an overlay whose times are absolute
    /// (text, stickers, picture-in-picture); without this a picture-in-picture past the end makes
    /// the composition longer than its clips. The STORED overlays are not changed — this is a
    /// derived view, so undoing the edit or lengthening the timeline brings the full window back.
    static func clampedToTimeline(_ overlays: [OverlayItem], total: Double?) -> [OverlayItem] {
        overlays.compactMap { overlay in
            guard let w = clampedWindow(start: overlay.startSec, end: overlay.endSec, total: total)
            else { return nil }
            var ov = overlay
            ov.startSec = w.start
            ov.endSec = w.end
            return ov
        }
    }

    /// The share (`0…1`) of an overlay's stored window that plays on a timeline of length `total` —
    /// what the lane bar draws at full strength. `1` when the whole window is inside the timeline or
    /// the length is not known; `0` when the window starts at or after the end.
    static func playedFraction(start: Double, end: Double, total: Double?) -> Double {
        let length = end - start
        guard length > 0 else { return 1 }
        guard let w = clampedWindow(start: start, end: end, total: total) else { return 0 }
        return min(1, max(0, (w.end - w.start) / length))
    }

    /// Which part of an overlay's lane bar a drag moved.
    enum OverlayWindowDrag: Sendable { case move, leadingEdge, trailingEdge }

    /// The window an overlay bar drag asks for, given the stored window and the timeline length.
    /// - `.move` keeps the length, and keeps at least `minOverlayWindowSec` of the bar inside the
    ///   timeline (the bar cannot be left where none of it plays).
    /// - `.leadingEdge` moves the start, with the same limit.
    /// - `.trailingEdge` moves the end; dragging it later stops at the end of the timeline. An end
    ///   that is already past it is not pulled back by a drag that does not move it earlier.
    /// With `total` of `nil` or `≤ 0` (length not known) only the `start ≥ 0` limit applies.
    /// `StudioProjectEditor.setOverlayTimeRange` still applies the minimum length.
    static func overlayWindow(dragging part: OverlayWindowDrag, bySeconds delta: Double,
                              start: Double, end: Double, total: Double?) -> (start: Double, end: Double) {
        let known = total.flatMap { $0 > 0 ? $0 : nil }
        let latestStart = known.map { max(0, $0 - minOverlayWindowSec) } ?? .infinity
        switch part {
        case .move:
            let length = max(minOverlayWindowSec, end - start)
            let s = min(max(0, start + delta), latestStart)
            return (s, s + length)
        case .leadingEdge:
            return (min(max(0, start + delta), latestStart), end)
        case .trailingEdge:
            let asked = end + delta
            guard let known, delta > 0 else { return (start, asked) }
            return (start, max(end, min(asked, known)))
        }
    }

    // MARK: - Keyframes

    /// Eased progress `0…1` for a normalized input `t` (clamped). Pure; matches the `StudioEasing`
    /// cases the compositor animates with.
    static func ease(_ t: Double, _ easing: StudioEasing) -> Double {
        let x = min(1, max(0, t))
        switch easing {
        case .linear:    return x
        case .easeIn:    return x * x
        case .easeOut:   return 1 - (1 - x) * (1 - x)
        case .easeInOut: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        }
    }

    /// Sample a keyframe track at output time `t`. Before the first / after the last keyframe holds
    /// the endpoint value (no extrapolation); between two keyframes it interpolates with the *later*
    /// keyframe's easing. Empty track → `defaultValue`.
    static func value(of keyframes: [StudioKeyframe], at t: Double, default defaultValue: Double) -> Double {
        guard !keyframes.isEmpty else { return defaultValue }
        let ks = keyframes.sorted { $0.timeSec < $1.timeSec }
        if t <= ks.first!.timeSec { return ks.first!.value }
        if t >= ks.last!.timeSec { return ks.last!.value }
        for i in 0 ..< (ks.count - 1) {
            let a = ks[i], b = ks[i + 1]
            guard t >= a.timeSec, t <= b.timeSec else { continue }
            let span = b.timeSec - a.timeSec
            let p = span > 0 ? (t - a.timeSec) / span : 1
            return a.value + (b.value - a.value) * ease(p, b.easing)
        }
        return ks.last!.value
    }
}
