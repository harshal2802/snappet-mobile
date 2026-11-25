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
    /// The clip's `baked` record is not edit state and is left alone.
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

    /// The `SessionMedia` field updates a "Save to original" bake applies (prompt 303). The
    /// length becomes the rendered length: it is what the asset now plays, and it is the
    /// timeline's fallback when the video is later not on this phone. The capture offset does
    /// NOT move, unlike `mediaUpdate`: the asset still holds the original video, "Revert to
    /// Original" in Photos brings it back, and the offset from before the bake is the only
    /// record of when that original starts. A rendered length that could not be read keeps the
    /// recorded one.
    static func revertibleMediaUpdate(oldOffsetSec: Double, oldDurationSec: Double?,
                                      renderedDurationSec: Double?) -> (offsetSec: Double, durationSec: Double?) {
        let rendered = renderedDurationSec.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return (oldOffsetSec, rendered ?? oldDurationSec)
    }

    /// The recorded length after "Revert to Original" was found: the asset's own length (the
    /// original video is back), or the recorded one when the asset's could not be read.
    static func revertedDuration(recorded: Double?, asset: Double?) -> Double? {
        asset.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? recorded
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
    ///   and the added music (the composer mixes it into every render — prompt 300).
    /// - When other clips exist, project-wide items are KEPT, because the other clips still use
    ///   them. A picture-in-picture that showed the replaced asset is re-pointed at the new one.
    ///   The merged clip gets a `baked` record of the kept items that are in its pixels (prompt
    ///   295), so the Studio does not draw them over it again. It is added to the record the parts
    ///   already had, and items no longer in the project are dropped from it.
    ///
    /// `hrTileDrawn` is false when the render had no HR tile to draw although the project has one
    /// (no heart-rate data for the clip); the record then does not claim the tile.
    static func flattened(_ s: StudioProjectSnapshot, target: String,
                          replacedBy newID: String? = nil,
                          hrTileDrawn: Bool = true) -> StudioProjectSnapshot {
        let ordered = StudioGeometry.ordered(s.clips)
        let parts = ordered.filter { !$0.isPhoto && $0.localIdentifier == target }
        guard let first = parts.first, let last = parts.last else { return s }
        let whole = coversWholeProject(s, target: target)
        let partIDs = Set(parts.map(\.id))
        // What the bake rendered: the parts, their overlays and the unbound ones, minus what an
        // earlier bake already put in the pixels.
        var scope = s
        scope.clips = parts
        scope.overlays = s.overlays.filter { $0.clipID.map(partIDs.contains) ?? true }
        let rendered = standingDown(scope, visible: parts)
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
            out.audioTracks.removeAll { $0.kind != .original }
        } else {
            out.overlays = s.overlays.compactMap { ov in
                if let clipID = ov.clipID, partIDs.contains(clipID) { return nil }
                guard let newID, ov.kind == .video, ov.content == target else { return ov }
                var ov = ov
                ov.content = newID
                return ov
            }
        }

        // The record (prompt 295). After a whole-project bake nothing project-wide is left, so
        // every part of it is pruned and it ends up `nil`.
        var record = parts.compactMap(\.baked).reduce(BakedItems()) { $0.union($1) }
        var overlayIDs = Set(record.overlayIDs)
        overlayIDs.formUnion(rendered.overlays
            .filter { $0.clipID == nil && ($0.kind == .video || !$0.content.isEmpty) }.map(\.id))
        var trackIDs = Set(record.audioTrackIDs)
        trackIDs.formUnion(rendered.audioTracks.filter { $0.kind != .original }.map(\.id))
        record.overlayIDs = BakedItems.sorted(overlayIDs.intersection(out.overlays.map(\.id)))
        record.audioTrackIDs = BakedItems.sorted(trackIDs.intersection(out.audioTracks.map(\.id)))
        record.hrTile = (record.hrTile || (hrTileDrawn && rendered.hrOverlay?.tile != nil))
            && out.hrOverlay != nil
        record.baseFrame = (record.baseFrame || rendered.baseFrame != nil) && out.baseFrame != nil
        if let i = out.clips.firstIndex(where: { $0.id == first.id }) {
            out.clips[i].baked = record.isEmpty ? nil : record
        }
        return out
    }

    // MARK: Stand-down (prompt 295 — what the Studio must not draw over a baked clip)

    /// The items that are in the pixels of EVERY visible clip. Empty when the timeline is empty or
    /// any visible clip has no record (never baked, baked before prompt 295, or a photo).
    static func bakedInEveryClip(_ visible: [TimelineClip]) -> BakedItems {
        guard let first = visible.first else { return BakedItems() }
        return visible.dropFirst().reduce(first.baked ?? BakedItems()) {
            $0.intersection($1.baked ?? BakedItems())
        }
    }

    /// The snapshot the Studio previews and renders. Nothing is stored: the project keeps every
    /// item for the clips that do not have it in their pixels.
    ///
    /// Project-wide items (overlays with no clip, added music, the HR tile, the base frame) span
    /// the whole output, so one is dropped only when every visible clip's `baked` record holds it.
    /// That is the "Edit this clip" scope of a baked clip. An item added after the bake is in no
    /// record and is kept. On a mixed timeline nothing is dropped here (the composer has no
    /// per-clip gate for these items); the HR tile is held back per clip by `hidesHRTile`.
    static func standingDown(_ s: StudioProjectSnapshot, visible: [TimelineClip]) -> StudioProjectSnapshot {
        let baked = bakedInEveryClip(visible)
        guard !baked.isEmpty else { return s }
        var out = s
        let overlayIDs = Set(baked.overlayIDs), trackIDs = Set(baked.audioTrackIDs)
        out.overlays.removeAll { $0.clipID == nil && overlayIDs.contains($0.id) }
        out.audioTracks.removeAll { $0.kind != .original && trackIDs.contains($0.id) }
        if baked.hrTile { out.hrOverlay = nil }
        if baked.baseFrame { out.baseFrame = nil }
        return out
    }

    /// True when the HR tile must not draw over this clip: its pixels have one.
    static func hidesHRTile(over clip: TimelineClip?) -> Bool { clip?.baked?.hrTile ?? false }

    /// The session-wide HR tile (the fallback for clips with no capture offset) is one layer over
    /// the whole output, so it cannot skip a clip. It is allowed only when no visible clip has a
    /// tile in its pixels.
    static func allowsSessionWideTile(visible: [TimelineClip]) -> Bool {
        !visible.contains { hidesHRTile(over: $0) }
    }

    /// The project after Photos reverted these assets to their originals: the pixels no longer
    /// carry anything, so the clips' records go and the project's items draw again.
    static func clearingBakeRecords(_ s: StudioProjectSnapshot, mediaIDs: Set<UUID>,
                                    localIdentifiers: Set<String>) -> StudioProjectSnapshot {
        var out = s
        for i in out.clips.indices where out.clips[i].baked != nil {
            let c = out.clips[i]
            if (c.sessionMediaID.map(mediaIDs.contains) ?? false) || localIdentifiers.contains(c.localIdentifier) {
                out.clips[i].baked = nil
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
