import Foundation

/// **Pure** decisions behind the Studio's bake lane (prompt 117 — "Save to original"): which projects
/// can bake, and how a DESTRUCTIVE bake re-points the app's records at the replacement asset. The
/// device-only Photos writes live in `ClipBakeService`; everything here runs in `SnappetTests`.
enum ClipBakePlan {

    /// The single source asset a bake writes into, or `nil` when baking isn't offered. A bake renders
    /// the COMPOSITION into ONE Photos asset, so it's only meaningful when:
    /// - the visible timeline is **video-only** (a photo segment has no "original" to bake into) and
    ///   every clip references the same source (the "Edit this clip" scoped studio, or split parts);
    /// - the scope COVERS the asset: every clip of that asset in the FULL project is visible — a
    ///   scoped studio hiding another part of the same asset would render, re-point, and offset-shift
    ///   against footage the render doesn't contain.
    /// A multi-asset (or partially-scoped) composition exports as a new video instead.
    static func bakeTarget(visible: [TimelineClip], all: [TimelineClip]) -> String? {
        guard !visible.isEmpty, visible.allSatisfy({ !$0.isPhoto }) else { return nil }
        let ids = Set(visible.map(\.localIdentifier))
        guard ids.count == 1, let target = ids.first else { return nil }
        let visibleIDs = Set(visible.map(\.id))
        let allParts = all.filter { !$0.isPhoto && $0.localIdentifier == target }
        guard allParts.allSatisfy({ visibleIDs.contains($0.id) }) else { return nil }
        return target
    }

    /// Neutralize the edit state a bake just burned INTO the pixels, for the target asset's parts:
    /// trims (the rendition/replacement plays the kept range), speed, filter + manual adjust, crop,
    /// Ken-Burns keyframes, and volume. Without this, reopening the project would re-apply every edit
    /// ON TOP of the baked pixels (double speed, double filter, re-trimmed rendition) — the composer
    /// resolves the asset's CURRENT (baked) version. Both bake variants use it: after a bake, "the
    /// asset IS the edit" (flattening semantics; a Photos revert restores pixels, not project edits).
    static func neutralizedClips(_ clips: [TimelineClip], localIdentifier: String) -> [TimelineClip] {
        clips.map { clip in
            guard !clip.isPhoto, clip.localIdentifier == localIdentifier else { return clip }
            var c = clip
            c.trimStart = 0
            c.trimEnd = nil
            c.speed = 1
            c.filter = .none
            c.filterIntensity = 1
            c.adjust = nil
            c.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            c.scaleKeyframes = []
            c.volume = nil
            return c
        }
    }

    /// The `SessionMedia` field updates a destructive bake applies: the replacement asset IS the
    /// rendered composition, so its capture offset moves to where the kept footage started
    /// (`oldOffset + earliest trimStart`) and its duration becomes the rendered length. One pure rule
    /// so the session detail, the feed, and the HR windows stay time-aligned after the swap.
    static func mediaUpdate(oldOffsetSec: Double, earliestTrimStart: Double,
                            renderedDurationSec: Double?) -> (offsetSec: Double, durationSec: Double?) {
        (max(0, oldOffsetSec + max(0, earliestTrimStart)), renderedDurationSec)
    }

    /// Re-point a project's timeline at the replacement asset (destructive bake): neutralize the
    /// baked edit state (`neutralizedClips`) AND swap the `localIdentifier` on the old asset's parts.
    static func repointedClips(_ clips: [TimelineClip], from oldID: String, to newID: String) -> [TimelineClip] {
        neutralizedClips(clips, localIdentifier: oldID).map { clip in
            guard clip.localIdentifier == oldID else { return clip }
            var c = clip
            c.localIdentifier = newID
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
