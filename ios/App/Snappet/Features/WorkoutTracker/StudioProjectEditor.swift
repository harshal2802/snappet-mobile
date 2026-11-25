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
    var baseFrame: StudioFrameRect? = nil
    /// Media the user deleted from the timeline (prompt 296) — see `StudioProject.removedMediaIDs`.
    /// Part of the snapshot so undoing a delete also forgets the deletion.
    var removedMediaIDs: [UUID]? = nil

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
        baseFrame = p.baseFrame
        removedMediaIDs = p.removedMediaIDs
    }
    /// Write this snapshot back onto a `@Model` (used by undo/redo and after each edit).
    func apply(to p: StudioProject) {
        p.title = title; p.aspectRaw = aspectRaw; p.backgroundRaw = backgroundRaw
        p.clips = clips; p.transitions = transitions; p.overlays = overlays; p.audioTracks = audioTracks
        p.hrOverlay = hrOverlay
        p.baseFrame = baseFrame
        p.removedMediaIDs = removedMediaIDs
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

    /// Remove a clip. When that was the LAST clip of its media item (no other split part of the same
    /// `sessionMediaID` is left), the media id is remembered in `removedMediaIDs` (prompt 296) so the
    /// next open of the Studio does not add the clip back (`StudioEntry.reconciled`). Deleting one
    /// split part while another survives records nothing: the media is still on the timeline.
    static func removeClip(_ s: StudioProjectSnapshot, id: UUID) -> StudioProjectSnapshot {
        var s = s
        let removedMedia = s.clips.first { $0.id == id }?.sessionMediaID
        s.clips = reindexed(StudioGeometry.ordered(s.clips).filter { $0.id != id })
        if let removedMedia {
            // Rebuilt against the clips that are left, so an id never stays listed while a clip of
            // that media is on the timeline.
            let present = Set(s.clips.compactMap(\.sessionMediaID))
            var removed = (s.removedMediaIDs ?? []).filter { !present.contains($0) }
            if !present.contains(removedMedia), !removed.contains(removedMedia) { removed.append(removedMedia) }
            s.removedMediaIDs = removed.isEmpty ? nil : removed
        }
        // Drop a transition that pointed at (after) the removed clip — it no longer has a successor.
        s.transitions = s.transitions.filter { $0.afterClipID != id }
        // Prompt 12 STEP 7a: garbage-collect any overlay bound to the removed clip (its per-clip climb
        // tag) so it doesn't float orphaned over the remaining clips.
        s.overlays.removeAll { $0.clipID == id }
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

    /// Set a clip's extended-HR-window config (prompt 115). `nil` values reset that field to the
    /// default (the stored optional is cleared, not pinned to the current default — so a later default
    /// change flows through). Lead/tail clamp to the slider ranges.
    static func setClipHRWindow(_ s: StudioProjectSnapshot, id: UUID,
                                leadSec: Double?, tailSec: Double?,
                                scope: HRMetricsScope?) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.clips.firstIndex(where: { $0.id == id }) else { return s }
        s.clips[i].hrLeadSec = leadSec.map { min(HRClipWindow.maxLeadSec, max(0, $0)) }
        s.clips[i].hrTailSec = tailSec.map { min(HRClipWindow.maxTailSec, max(0, $0)) }
        s.clips[i].hrMetricsScopeRaw = scope?.rawValue
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

    /// Set an overlay's `scale`. For text/sticker/climb-name overlays this multiplies the rendered
    /// font/symbol size (so it ranges past 1 — bigger text); clamped to a sane 0.2…6. A PiP's frame
    /// size is set per-axis via `setOverlayFrame`, not here.
    static func setOverlayScale(_ s: StudioProjectSnapshot, id: UUID, scale: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].scale = min(6, max(0.2, scale))
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
    ///
    /// A transition is keyed `afterClipID` and means "between this clip and the next". The first
    /// half keeps the original id, so the transition that led OUT of the original clip is re-keyed
    /// to the second half (prompt 297); left alone it would play between the two halves. The halves
    /// join with a cut.
    static func splitClip(_ s: StudioProjectSnapshot, id: UUID, atOutputOffset offset: Double,
                          sourceDuration: Double?) -> StudioProjectSnapshot {
        guard let clip = s.clips.first(where: { $0.id == id }), !clip.isPhoto else { return s }
        let src = sourceDuration ?? clip.trimEnd ?? 0
        let trimEnd = clip.trimEnd ?? src
        let cutSource = clip.trimStart + offset * StudioGeometry.clampSpeed(clip.speed)
        guard cutSource > clip.trimStart + 0.05, cutSource < trimEnd - 0.05 else { return s }

        var first = clip; first.trimEnd = cutSource
        var second = clip
        // The second half ends where the clip ended. A clip with no stored end keeps none: the
        // length used above may be an estimate (the recorded length of a video that is not on
        // this phone), and a stored estimate would stay after the real length is read (prompt 303).
        second.id = UUID(); second.trimStart = cutSource; second.trimEnd = clip.trimEnd
        second.scaleKeyframes = []        // keyframes don't carry meaningfully across a split

        var seq = StudioGeometry.ordered(s.clips)
        guard let idx = seq.firstIndex(where: { $0.id == id }) else { return s }
        seq[idx] = first
        seq.insert(second, at: idx + 1)
        var s = s
        s.clips = reindexed(seq)
        s.transitions = s.transitions.map { t in
            guard t.afterClipID == id else { return t }
            var t = t; t.afterClipID = second.id; return t
        }
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

    /// Set a text/climb-name overlay's text colour (hex).
    static func setOverlayColor(_ s: StudioProjectSnapshot, id: UUID, hex: String) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].colorHex = hex
        return s
    }

    /// Set (hex) or clear (`nil`) a text/climb-name overlay's highlight/background colour.
    static func setOverlayHighlight(_ s: StudioProjectSnapshot, id: UUID, hex: String?) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].highlightHex = hex
        return s
    }

    /// Set a text/climb-name overlay's font preset.
    static func setOverlayFont(_ s: StudioProjectSnapshot, id: UUID, font: StudioFont) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].font = font
        return s
    }

    /// Set a text/climb-name overlay's bold / italic style (each optional → leave unchanged when nil).
    static func setOverlayStyle(_ s: StudioProjectSnapshot, id: UUID,
                                bold: Bool? = nil, italic: Bool? = nil) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        if let bold { s.overlays[i].bold = bold }
        if let italic { s.overlays[i].italic = italic }
        return s
    }

    /// Replace an overlay's text/content (the studio's "Edit text", or re-deriving a climb caption).
    static func setOverlayContent(_ s: StudioProjectSnapshot, id: UUID, content: String) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        s.overlays[i].content = content
        return s
    }

    /// Set a climb-name tag's **persisted** compose flags (prompt 12): whether it shows the setter and/or
    /// the "Attempt N" line, and which attempt number. Each parameter is optional → leave unchanged when
    /// `nil`, EXCEPT `attemptNumber`, which is set unconditionally (a passed `nil` clears it — call it
    /// without the argument to leave it alone). The rendered string is composed from these + the base
    /// `content` at render time, so user text and the system lines never share an encoding.
    static func setOverlayClimbFlags(_ s: StudioProjectSnapshot, id: UUID,
                                     showsSetter: Bool? = nil, showsAttempt: Bool? = nil,
                                     attemptNumber: Int?? = nil) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        if let showsSetter { s.overlays[i].showsSetter = showsSetter }
        if let showsAttempt { s.overlays[i].showsAttempt = showsAttempt }
        if let attemptNumber { s.overlays[i].attemptNumber = attemptNumber }
        return s
    }

    /// Set an overlay's on-screen window `[start, end]` (output seconds) — the timeline lane's
    /// move/trim commit. Clamped to `start ≥ 0` with a minimum 0.2s length so the bar can't collapse.
    static func setOverlayTimeRange(_ s: StudioProjectSnapshot, id: UUID,
                                    start: Double, end: Double) -> StudioProjectSnapshot {
        var s = s
        guard let i = s.overlays.firstIndex(where: { $0.id == id }) else { return s }
        let minLen = StudioGeometry.minOverlayWindowSec
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

    /// Enable / move / resize the **base-video frame** (collage): place the main track into a
    /// normalized centre + size sub-rect of the canvas. Clamped via `StudioFrameRect`'s own init.
    static func setBaseFrame(_ s: StudioProjectSnapshot, center: CGPoint, size: CGSize) -> StudioProjectSnapshot {
        var s = s
        s.baseFrame = StudioFrameRect(centerX: center.x, centerY: center.y,
                                      width: size.width, height: size.height)
        return s
    }

    /// Clear base framing — the main video fills the whole canvas again (legacy behaviour).
    static func clearBaseFrame(_ s: StudioProjectSnapshot) -> StudioProjectSnapshot {
        var s = s; s.baseFrame = nil; return s
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
    /// The open gesture, if any: the value before it began, and whether it replaced the value yet
    /// (prompt 299).
    private var transaction: (base: State, replaced: Bool)?

    init(_ initial: State, limit: Int = 50) { current = initial; self.limit = limit }

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Record a new state as the current one; clears the redo branch.
    mutating func commit(_ next: State) {
        endTransaction()
        push(current)
        current = next
    }

    mutating func undo() {
        endTransaction()
        guard let prev = past.popLast() else { return }
        future.append(current)
        current = prev
    }

    mutating func redo() {
        endTransaction()
        guard let next = future.popLast() else { return }
        past.append(current)
        current = next
    }

    /// Add one undo step holding `state`, drop the oldest beyond the limit, clear the redo branch.
    private mutating func push(_ state: State) {
        past.append(state)
        if past.count > limit { past.removeFirst(past.count - limit) }
        future.removeAll()
    }

    // MARK: One step per gesture (prompt 299)

    /// True between `beginTransaction()` and the call that ends it.
    var isInTransaction: Bool { transaction != nil }

    /// Open a transaction: a continuous gesture (a slider drag) whose many values are one edit.
    /// Nothing changes yet — not the history, not the redo branch. Opening one that is already open
    /// does nothing.
    mutating func beginTransaction() {
        if transaction == nil { transaction = (current, false) }
    }

    /// Set the current value WITHOUT adding an undo step, any number of times, while a transaction
    /// is open. With no transaction open this is a plain `commit`.
    mutating func replaceCurrent(_ next: State) {
        guard transaction != nil else { commit(next); return }
        transaction?.replaced = true
        current = next
    }

    /// Close the transaction. If the value was replaced — and `changed(before, after)` agrees it is
    /// different — this adds exactly ONE undo step holding the value from before the gesture and
    /// clears the redo branch once. Otherwise the stack is exactly as it was before the gesture.
    /// Returns whether a step was added. Does nothing (false) when no transaction is open.
    /// `commit`, `undo` and `redo` close an open transaction first.
    @discardableResult
    mutating func endTransaction(where changed: (_ before: State, _ after: State) -> Bool = { _, _ in true }) -> Bool {
        guard let open = transaction else { return false }
        transaction = nil
        guard open.replaced, changed(open.base, current) else { return false }
        push(open.base)
        return true
    }
}

extension UndoStack where State: Equatable {
    /// `endTransaction` that adds no step when the gesture ended on the value it started from.
    @discardableResult
    mutating func endTransactionIfChanged() -> Bool { endTransaction(where: !=) }
}
