import Foundation
import CoreGraphics

/// A plain-value snapshot of a `StudioProject`'s editable state — the unit of undo/redo, the input
/// to the (device-only) `StudioComposer`, and what the **pure** `StudioProjectEditor` operations
/// transform. Keeping the edit model a value type means the whole editor (add / reorder / trim /
/// split / transition / filter / undo / redo) is testable with no device or SwiftData — the @Model
/// is only touched when reading/writing the snapshot on the main actor.
struct StudioProjectSnapshot: Codable, Hashable, Sendable {
    var title: String
    var aspectRaw: String
    var backgroundRaw: String
    var clips: [TimelineClip]
    var transitions: [StudioTransition]
    var overlays: [OverlayItem]
    var audioTracks: [AudioTrack]
    var hrOverlay: HROverlayConfig? = nil

    var aspect: ClipEditGeometry.OutputAspect {
        get { ClipEditGeometry.OutputAspect(rawValue: aspectRaw) ?? .portrait9x16 }
        set { aspectRaw = newValue.rawValue }
    }
}

@MainActor
extension StudioProjectSnapshot {
    /// Read the current state out of a `@Model`.
    init(_ p: StudioProject) {
        title = p.title; aspectRaw = p.aspectRaw; backgroundRaw = p.backgroundRaw
        clips = p.clips; transitions = p.transitions; overlays = p.overlays; audioTracks = p.audioTracks
        hrOverlay = p.hrOverlay
    }
    /// Write this snapshot back onto a `@Model` (used by undo/redo and after each edit).
    func apply(to p: StudioProject) {
        p.title = title; p.aspectRaw = aspectRaw; p.backgroundRaw = backgroundRaw
        p.clips = clips; p.transitions = transitions; p.overlays = overlays; p.audioTracks = audioTracks
        p.hrOverlay = hrOverlay
        p.updatedAt = .now
    }
}

/// **Pure** edit operations over a `StudioProjectSnapshot` — each returns a new snapshot, so they
/// compose, are trivially undoable (just keep the prior snapshot), and unit-test without a device.
/// Clip `order` is kept contiguous (0…n-1) after structural edits so the timeline stays well-formed.
enum StudioProjectEditor {

    /// Assign `order` from **array position** (the caller passes clips already in the desired
    /// sequence). Must NOT re-sort — that would discard a move/split's new ordering.
    private static func reindexed(_ clipsInOrder: [TimelineClip]) -> [TimelineClip] {
        clipsInOrder.enumerated().map { i, c in var c = c; c.order = i; return c }
    }

    static func addClip(_ s: StudioProjectSnapshot, _ clip: TimelineClip) -> StudioProjectSnapshot {
        var s = s
        s.clips = reindexed(StudioGeometry.ordered(s.clips) + [clip])
        return s
    }

    static func removeClip(_ s: StudioProjectSnapshot, id: UUID) -> StudioProjectSnapshot {
        var s = s
        s.clips = reindexed(StudioGeometry.ordered(s.clips).filter { $0.id != id })
        // Drop a transition that pointed at (after) the removed clip — it no longer has a successor.
        s.transitions = s.transitions.filter { $0.afterClipID != id }
        return s
    }

    /// Move the clip with `id` to `toIndex` in track order (clamped), reindexing the rest.
    static func moveClip(_ s: StudioProjectSnapshot, id: UUID, toIndex: Int) -> StudioProjectSnapshot {
        var s = s
        var seq = StudioGeometry.ordered(s.clips)
        guard let from = seq.firstIndex(where: { $0.id == id }) else { return s }
        let clip = seq.remove(at: from)
        let dest = min(max(0, toIndex), seq.count)
        seq.insert(clip, at: dest)
        s.clips = reindexed(seq)
        return s
    }

    static func trimClip(_ s: StudioProjectSnapshot, id: UUID, start: Double, end: Double?) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return s }
        s.clips[i].trimStart = max(0, start)
        s.clips[i].trimEnd = end
        return s
    }

    static func setClipSpeed(_ s: StudioProjectSnapshot, id: UUID, speed: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return s }
        s.clips[i].speed = StudioGeometry.clampSpeed(speed)
        return s
    }

    static func setClipFilter(_ s: StudioProjectSnapshot, id: UUID, filter: StudioFilter,
                              intensity: Double = 1) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return s }
        s.clips[i].filter = filter
        s.clips[i].filterIntensity = min(1, max(0, intensity))
        return s
    }

    /// Set (or clear) a clip's manual colour adjust. A neutral adjust is stored as `nil` so the
    /// compositor skips the Core Image pass for it.
    static func setClipAdjust(_ s: StudioProjectSnapshot, id: UUID, adjust: ClipAdjust?) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return s }
        s.clips[i].adjust = (adjust?.isNeutral ?? true) ? nil : adjust
        return s
    }

    /// Set a clip's original-audio volume (0…1). Full volume (≈1) is stored as `nil` so the
    /// compositor skips the audio mix for it.
    static func setClipVolume(_ s: StudioProjectSnapshot, id: UUID, volume: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return s }
        let v = max(0, min(1, volume))
        s.clips[i].volume = v >= 0.999 ? nil : v
        return s
    }

    /// Set an overlay's scale (PiP frame size as a fraction of the canvas), clamped 0.1…1.
    static func setOverlayScale(_ s: StudioProjectSnapshot, id: UUID, scale: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].scale = min(1, max(0.1, scale))
        return s
    }

    /// Set an overlay's base opacity (used when it has no opacity keyframes).
    static func setOverlayOpacity(_ s: StudioProjectSnapshot, id: UUID, opacity: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].opacity = max(0, min(1, opacity))
        return s
    }

    /// Add (or replace at the same time) an **opacity keyframe** on an overlay at `timeSec` — the
    /// marker button. With ≥2 keyframes of differing values the overlay's opacity animates (the export
    /// `StudioOverlays` samples `opacityKeyframes`).
    static func addOverlayOpacityKeyframe(_ s: StudioProjectSnapshot, id: UUID,
                                          timeSec: Double, value: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        var ks = s.overlays[i].opacityKeyframes.filter { abs($0.timeSec - timeSec) > 0.05 }
        ks.append(StudioKeyframe(timeSec: max(0, timeSec), value: max(0, min(1, value))))
        s.overlays[i].opacityKeyframes = ks.sorted { $0.timeSec < $1.timeSec }
        return s
    }

    /// Split a video clip at an **output** offset into two adjacent clips (the `ClipEditGeometry.split`
    /// idea, on the timeline). The offset is converted to source seconds via the clip's speed; a
    /// degenerate split (≤0 or ≥ the trimmed span) is a no-op. Photos aren't split.
    static func splitClip(_ s: StudioProjectSnapshot, id: UUID, atOutputOffset offset: Double,
                          sourceDuration: Double?) -> StudioProjectSnapshot {
        guard let clip = s.clips.first(where: { $0.id == id }), !clip.isPhoto else { return s }
        let src = sourceDuration ?? clip.trimEnd ?? 0
        let trimEnd = clip.trimEnd ?? src
        let cutSource = clip.trimStart + offset * StudioGeometry.clampSpeed(clip.speed)
        guard cutSource > clip.trimStart + 0.05, cutSource < trimEnd - 0.05 else { return s }

        var first = clip; first.trimEnd = cutSource
        var second = clip
        second.id = UUID(); second.trimStart = cutSource; second.trimEnd = trimEnd
        second.scaleKeyframes = []        // keyframes don't carry meaningfully across a split

        var seq = StudioGeometry.ordered(s.clips)
        guard let idx = seq.firstIndex(where: { $0.id == id }) else { return s }
        seq[idx] = first
        seq.insert(second, at: idx + 1)
        var s = s
        s.clips = reindexed(seq)
        return s
    }

    static func setTransition(_ s: StudioProjectSnapshot, afterClipID: UUID,
                              kind: StudioTransitionKind, durationSec: Double = 0.5) -> StudioProjectSnapshot {
        var s = s
        s.transitions.removeAll { $0.afterClipID == afterClipID }
        if kind != .none {
            s.transitions.append(StudioTransition(afterClipID: afterClipID, kind: kind, durationSec: durationSec))
        }
        return s
    }

    static func setAspect(_ s: StudioProjectSnapshot, _ aspect: ClipEditGeometry.OutputAspect) -> StudioProjectSnapshot {
        var s = s; s.aspect = aspect; return s
    }

    static func setBackground(_ s: StudioProjectSnapshot, _ bg: StudioBackground) -> StudioProjectSnapshot {
        var s = s; s.backgroundRaw = bg.rawValue; return s
    }

    static func addOverlay(_ s: StudioProjectSnapshot, _ overlay: OverlayItem) -> StudioProjectSnapshot {
        var s = s; s.overlays.append(overlay); return s
    }

    static func addAudioTrack(_ s: StudioProjectSnapshot, _ track: AudioTrack) -> StudioProjectSnapshot {
        var s = s; s.audioTracks.append(track); return s
    }

    static func removeAudioTrack(_ s: StudioProjectSnapshot, id: UUID) -> StudioProjectSnapshot {
        var s = s; s.audioTracks.removeAll { $0.id == id }; return s
    }

    static func removeOverlay(_ s: StudioProjectSnapshot, id: UUID) -> StudioProjectSnapshot {
        var s = s; s.overlays.removeAll { $0.id == id }; return s
    }

    /// Move an overlay to a normalized centre (`0…1`, top-left origin), clamped to the canvas — the
    /// commit point for the WYSIWYG drag on the preview canvas.
    static func setOverlayPosition(_ s: StudioProjectSnapshot, id: UUID, position: CGPoint) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].position = CGPoint(x: min(max(position.x, 0), 1), y: min(max(position.y, 0), 1))
        return s
    }

    /// Replace an overlay's text/content (the studio's "Edit text", or re-deriving a climb caption).
    static func setOverlayContent(_ s: StudioProjectSnapshot, id: UUID, content: String) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].content = content
        return s
    }

    /// Set an overlay's on-screen window `[start, end]` (output seconds) — the timeline lane's
    /// move/trim commit. Clamped to `start ≥ 0` with a minimum 0.2s length so the bar can't collapse.
    static func setOverlayTimeRange(_ s: StudioProjectSnapshot, id: UUID,
                                    start: Double, end: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        let minLen = 0.2
        let lo = max(0, min(start, end))
        let hi = max(lo + minLen, max(start, end))
        s.overlays[i].startSec = lo
        s.overlays[i].endSec = hi
        return s
    }

    /// Set a PiP (`.video`) overlay's per-axis frame: a normalized centre + size (fractions of the
    /// canvas, each clamped 0.1…1) — the commit point for corner-resize / grid placement.
    static func setOverlayFrame(_ s: StudioProjectSnapshot, id: UUID,
                                center: CGPoint, size: CGSize) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].position = CGPoint(x: min(max(center.x, 0), 1), y: min(max(center.y, 0), 1))
        s.overlays[i].pipSize = CGSize(width: min(1, max(0.1, size.width)),
                                       height: min(1, max(0.1, size.height)))
        return s
    }

    /// Arrange the PiP (`.video`) overlays into a collage `preset`, in track order, by assigning each
    /// the corresponding cell's frame. Overlays beyond the preset's capacity keep their frame.
    static func applyPiPGrid(_ s: StudioProjectSnapshot, preset: StudioGridLayout.Preset) -> StudioProjectSnapshot {
        var s = s
        let videoIdx = s.overlays.indices.filter { s.overlays[$0].kind == .video }
        let cells = StudioGridLayout.frames(preset: preset, count: videoIdx.count)
        for (n, i) in videoIdx.enumerated() where n < cells.count {
            s.overlays[i].position = cells[n].center
            s.overlays[i].pipSize = cells[n].size
        }
        return s
    }
}

/// A minimal generic undo/redo stack of immutable states. Pure and value-typed, so it's unit-tested
/// directly; the editor view model holds one of `StudioProjectSnapshot`.
struct UndoStack<State> {
    private(set) var current: State
    private var past: [State] = []
    private var future: [State] = []
    private let limit: Int

    init(_ initial: State, limit: Int = 50) { current = initial; self.limit = limit }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Record a new state as the current one; clears the redo branch.
    mutating func commit(_ next: State) {
        past.append(current)
        if past.count > limit { past.removeFirst(past.count - limit) }
        current = next
        future.removeAll()
    }

    mutating func undo() {
        guard let prev = past.popLast() else { return }
        future.append(current)
        current = prev
    }

    mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(current)
        current = next
    }
}
