import Foundation

// MARK: - Clips feed ⇄ Studio convergence (prompt 116)
//
// The per-clip Studio edit info the feed **live-reflects**: the kept trim range (the feed plays it —
// looper time-range / fullscreen end-time / poster frame) and the extended-HR-window config (the same
// lead/tail/scope the export burns, prompt 115). Resolved ONCE per feed compose from the session's
// `StudioProject.clips` and stamped onto `MediaInput.edit`; every surface (poster, inline player,
// fullscreen, HR payload) reads that one value.
//
// Deliberately NOT here: speed / filters / crop / text / PiP — those need a rendered composition per
// feed cell (the Core-Animation overlay tool is offline-only, and per-cell compositions would undo the
// prompt 97/106 carousel-perf work). They reach the feed via the bake lane (prompt 117) instead.
//
// Pure (Foundation + the app's pure Studio value types) → unit-tested in `SnappetTests`.

struct ClipStudioEdit: Sendable, Hashable {
    /// Kept-range start within the source asset (seconds). `nil`/0 = from the top.
    var trimStart: Double? = nil
    /// Kept-range end within the source asset (seconds). `nil` = to the natural end.
    var trimEnd: Double? = nil
    /// Extended-HR-window config (prompt 115) — mirrors `TimelineClip.hrWindow*`'s defaults, so a
    /// never-edited clip renders the same chart the Studio would.
    var hrLeadSec: Double = HRClipWindow.defaultLeadSec
    var hrTailSec: Double = HRClipWindow.defaultTailSec
    var hrMetricsScope: HRMetricsScope = .default

    /// A kept range shorter than this plays the raw clip instead (a degenerate trim would loop a blink).
    static let minKeptSec: Double = 0.5

    /// Whether the Studio kept a sub-range of the source (drives the feed's EDITED chip + the
    /// trimmed playback path). A ~0 trimStart with no trimEnd is the untrimmed identity.
    var isTrimmed: Bool { (trimStart ?? 0) > 0.01 || trimEnd != nil }

    /// The kept range clamped into `[0, rawDuration]`, or `nil` when the clip should play RAW:
    /// untrimmed, a degenerate (< `minKeptSec`) or out-of-bounds trim, or an unknown duration.
    /// One validity rule for the looper, the fullscreen transport, the poster, and the HR window.
    func keptRange(rawDurationSec: Double) -> ClosedRange<Double>? {
        guard isTrimmed, rawDurationSec > 0 else { return nil }
        let start = min(max(0, trimStart ?? 0), rawDurationSec)
        let end = min(trimEnd ?? rawDurationSec, rawDurationSec)
        guard end - start >= Self.minKeptSec else { return nil }
        // A range that spans (effectively) the whole clip is the untrimmed identity.
        if start <= 0.01 && end >= rawDurationSec - 0.01 { return nil }
        return start...end
    }

    /// Resolve one edit per **physical asset** from a project's timeline clips, keyed by
    /// `SessionMedia.id`. Rules (the wireframe's):
    /// - Videos only; a clip resolvable by neither `sessionMediaID` nor `localIdentifier` is skipped
    ///   (same fallback policy as `StudioHRPlacement.resolveOffset`).
    /// - **Split clips** (one asset → several timeline clips with adjacent trims) collapse to the kept
    ///   ENVELOPE `[min trimStart … max trimEnd]` — one feed item per asset stays the rule; a split
    ///   part reaching the natural end (nil trimEnd) makes the envelope end nil too.
    /// - HR window fields come from the earliest (`order`) part, matching what the Studio preview
    ///   shows first.
    /// - A media id with NO surviving timeline clip is absent — the feed falls back to the raw clip
    ///   (a Studio removal must never hide feed media).
    static func byMedia(clips: [TimelineClip],
                        mediaIDByLocalID: [String: UUID] = [:]) -> [UUID: ClipStudioEdit] {
        var grouped: [UUID: [TimelineClip]] = [:]
        for clip in clips where !clip.isPhoto {
            guard let mediaID = clip.sessionMediaID ?? mediaIDByLocalID[clip.localIdentifier] else { continue }
            grouped[mediaID, default: []].append(clip)
        }
        var out: [UUID: ClipStudioEdit] = [:]
        for (mediaID, parts) in grouped {
            let ordered = parts.sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }
            guard let first = ordered.first else { continue }
            let start = ordered.map { max(0, $0.trimStart) }.min() ?? 0
            let end: Double? = ordered.contains { $0.trimEnd == nil } ? nil : ordered.compactMap(\.trimEnd).max()
            out[mediaID] = ClipStudioEdit(trimStart: start > 0.01 ? start : nil,
                                          trimEnd: end,
                                          hrLeadSec: first.hrWindowLeadSec,
                                          hrTailSec: first.hrWindowTailSec,
                                          hrMetricsScope: first.hrMetricsScope)
        }
        return out
    }
}
