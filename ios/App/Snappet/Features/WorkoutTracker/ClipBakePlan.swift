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

    // MARK: Flatten (prompt 294 — what leaves the project after a bake)

    /// True when the bake renders the WHOLE project: every clip is a video part of `target`. False
    /// for the "Edit this clip" scoped studio of a session with other clips — the common case, since
    /// one project is shared by the whole session.
    static func coversWholeProject(_ s: StudioProjectSnapshot, target: String) -> Bool {
        !s.clips.isEmpty && s.clips.allSatisfy { !$0.isPhoto && $0.localIdentifier == target }
    }

    /// Whether the composer mixed the added music into this render. It mirrors the path choice in
    /// `StudioComposer.assemble`: the transition path (a transition is set, no clip has a filter, no
    /// picture-in-picture) does not take the music tracks, so the file has no music and the tracks
    /// must stay in the project. Remove this mirror when the composer has one path.
    static func rendersMusic(_ rendered: StudioProjectSnapshot) -> Bool {
        let transitionPath = rendered.transitions.contains { $0.kind != .none }
            && !rendered.clips.contains { !$0.isPhoto && $0.filter != .none }
            && !rendered.overlays.contains { $0.kind == .video }
        return !transitionPath
    }

    /// The project after a bake of `target`, computed from the snapshot the render was made from.
    /// The rule is "remove exactly what is now in the pixels, and nothing that belongs to another
    /// clip":
    /// - The target's parts become ONE neutral clip in the first part's place (two split parts left
    ///   as two clips would each play the whole baked video). `replacedBy` re-points it at the new
    ///   asset after "Replace original".
    /// - Overlays bound to a target part are removed. Overlays bound to other clips are kept.
    /// - A transition after any part but the last was between two parts, so it is removed. A
    ///   transition after the last part leads to another clip, so it moves to the merged clip.
    /// - When the bake covers the whole project, everything project-wide was rendered too and is
    ///   removed: unbound text/stickers/climb tags, picture-in-picture, the HR tile, the base frame,
    ///   and the music (only if it was mixed — `rendersMusic`).
    /// - When other clips exist, project-wide items are KEPT, because the other clips still use
    ///   them. A picture-in-picture that showed the replaced asset is re-pointed at the new one.
    static func flattened(_ s: StudioProjectSnapshot, target: String,
                          replacedBy newID: String? = nil) -> StudioProjectSnapshot {
        let ordered = StudioGeometry.ordered(s.clips)
        let parts = ordered.filter { !$0.isPhoto && $0.localIdentifier == target }
        guard let first = parts.first, let last = parts.last else { return s }
        let whole = coversWholeProject(s, target: target)
        let musicWasMixed = rendersMusic(s)
        let partIDs = Set(parts.map(\.id))
        var out = s

        // Clips: one neutral clip in the first part's place.
        var merged = neutralizedClips([first], localIdentifier: target)[0]
        if let newID { merged.localIdentifier = newID }
        out.clips = ordered.filter { !partIDs.contains($0.id) || $0.id == first.id }
            .map { $0.id == first.id ? merged : $0 }
            .enumerated().map { i, c in var c = c; c.order = i; return c }

        // Transitions: those between parts are in the pixels; the one leaving the last part stays.
        out.transitions = s.transitions.compactMap { t in
            guard partIDs.contains(t.afterClipID) else { return t }
            guard !whole, t.afterClipID == last.id else { return nil }
            var t = t
            t.afterClipID = first.id
            return t
        }

        if whole {
            out.overlays = []
            out.hrOverlay = nil
            out.baseFrame = nil
            if musicWasMixed { out.audioTracks.removeAll { $0.kind != .original } }
        } else {
            out.overlays = s.overlays.compactMap { ov in
                if let clipID = ov.clipID, partIDs.contains(clipID) { return nil }
                guard let newID, ov.kind == .video, ov.content == target else { return ov }
                var ov = ov
                ov.content = newID
                return ov
            }
        }
        return out
    }

    /// The earliest kept `trimStart` across the parts of one asset (0 when untrimmed) — the amount
    /// the replacement asset's capture offset shifts forward by.
    static func earliestTrimStart(clips: [TimelineClip], localIdentifier: String) -> Double {
        clips.filter { !$0.isPhoto && $0.localIdentifier == localIdentifier }
            .map { max(0, $0.trimStart) }.min() ?? 0
    }
}
