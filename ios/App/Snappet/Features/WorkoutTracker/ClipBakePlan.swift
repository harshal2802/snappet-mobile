import Foundation

/// **Pure** decisions behind the Studio's bake lane (prompt 117 — "Save to original"): which projects
/// can bake, and how a DESTRUCTIVE bake re-points the app's records at the replacement asset. The
/// device-only Photos writes live in `ClipBakeService`; everything here runs in `SnappetTests`.
enum ClipBakePlan {

    /// The single source asset a bake writes into, or `nil` when baking isn't offered. A bake renders
    /// the COMPOSITION into ONE Photos asset, so it's only meaningful when every visible video clip
    /// references the same source (the "Edit this clip" scoped studio, or split parts of one asset) —
    /// a multi-asset composition exports as a new video instead.
    static func bakeTarget(clips: [TimelineClip]) -> String? {
        let ids = Set(clips.filter { !$0.isPhoto }.map(\.localIdentifier))
        return ids.count == 1 ? ids.first : nil
    }

    /// The `SessionMedia` field updates a destructive bake applies: the replacement asset IS the
    /// rendered composition, so its capture offset moves to where the kept footage started
    /// (`oldOffset + earliest trimStart`) and its duration becomes the rendered length. One pure rule
    /// so the session detail, the feed, and the HR windows stay time-aligned after the swap.
    static func mediaUpdate(oldOffsetSec: Double, earliestTrimStart: Double,
                            renderedDurationSec: Double?) -> (offsetSec: Double, durationSec: Double?) {
        (max(0, oldOffsetSec + max(0, earliestTrimStart)), renderedDurationSec)
    }

    /// Re-point a project's timeline at the replacement asset: swap the `localIdentifier` on every
    /// part of the old asset and RESET their trims/speed-invariant edit state that is now baked into
    /// the pixels (trims → whole clip; the new asset already plays the kept range). Filters, crop,
    /// speed, and overlays are also in the pixels, but resetting them is the caller's call via
    /// `resetBakedEdits` — kept separate so a REVERTIBLE bake (original untouched, project still the
    /// live source of truth) leaves the timeline alone.
    static func repointedClips(_ clips: [TimelineClip], from oldID: String, to newID: String) -> [TimelineClip] {
        clips.map { clip in
            guard clip.localIdentifier == oldID else { return clip }
            var c = clip
            c.localIdentifier = newID
            c.trimStart = 0
            c.trimEnd = nil
            return c
        }
    }

    /// The earliest kept `trimStart` across the parts of one asset (0 when untrimmed) — the amount
    /// the replacement asset's capture offset shifts forward by.
    static func earliestTrimStart(clips: [TimelineClip], localIdentifier: String) -> Double {
        clips.filter { !$0.isPhoto && $0.localIdentifier == localIdentifier }
            .map { max(0, $0.trimStart) }.min() ?? 0
    }
}
