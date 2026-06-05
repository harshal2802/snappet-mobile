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
