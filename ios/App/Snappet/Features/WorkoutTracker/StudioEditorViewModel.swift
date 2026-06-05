import SwiftUI
import SwiftData
import AVFoundation
import os

/// View model for the full-studio multi-clip editor (S1). Holds the `StudioProject` `@Model` and an
/// `UndoStack<StudioProjectSnapshot>`; every edit goes through the **pure** `StudioProjectEditor`
/// (so the logic is unit-tested) → commits to undo → writes the snapshot back to the `@Model` →
/// rebuilds the preview. The preview/export use the device-only `StudioComposer`; on the simulator
/// (no resolvable Photos assets) the player is nil and the view shows a device-only placeholder —
/// the timeline + all editing operations still work on the model.
@MainActor
@Observable
final class StudioEditorViewModel {
    let project: StudioProject
    private let context: ModelContext
    private let composer = StudioComposer()
    private var undo: UndoStack<StudioProjectSnapshot>

    /// When set, the studio is **scoped** to the clips backed by these `SessionMedia.id`s (per-clip or
    /// per-climb editing from Kilter). `nil` (the workout default) shows the whole project. Edits still
    /// target the full project by clip id — only the display, preview, timeline, and export are scoped,
    /// so a scoped edit carries into every other scope of the same shared project.
    let visibleClipMediaIDs: Set<UUID>?

    var selectedClipID: UUID?
    var selectedOverlayID: UUID?
    private(set) var sourceDurations: [UUID: Double] = [:]
    /// The session's heart-rate samples (for the HR chart overlay), loaded on appear from the FK.
    private(set) var hrSeries: [HRPoint] = []
    var previewPlayer: AVPlayer?
    var isBuildingPreview = false
    /// Set when the player rejects the composition (see `rebuildPreview`) — the studio stays open
    /// (no crash) and the canvas shows this instead of a silent black frame; export still works.
    var previewError: String?
    var exportState: ExportShareState = .idle

    // Transport (custom play/pause + live timecode + a scrub playhead, driving the edits-style UI).
    var isPlaying = false
    /// The playhead position in **output** seconds, updated by a periodic observer while playing and
    /// by scrubbing the timeline. Drives the timecode label and the timeline's centre playhead.
    var currentTime: Double = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    /// Output-quality preset for export, shown in the top bar and passed to `composer.export`.
    var exportQuality: StudioExportQuality = .hd1080

    private static let log = Logger(subsystem: "com.snappet.app", category: "studio")

    init(project: StudioProject, context: ModelContext, visibleClipMediaIDs: Set<UUID>? = nil) {
        self.project = project
        self.context = context
        self.visibleClipMediaIDs = visibleClipMediaIDs
        undo = UndoStack(StudioProjectSnapshot(project))
    }

    // MARK: Title

    var title: String { snapshot.title }
    func rename(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else { return }
        editOverlaysOnly { var s = $0; s.title = trimmed; return s }   // metadata-only: no rebuild
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }
    func play() {
        guard previewPlayer != nil else { return }
        if currentTime >= totalDuration - 0.05 { seek(to: 0) }   // restart from the top if at the end
        previewPlayer?.play(); isPlaying = true
    }
    func pause() { previewPlayer?.pause(); isPlaying = false }

    /// Move the playhead (and the player) to `seconds` (clamped to the timeline).
    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, totalDuration))
        currentTime = clamped
        previewPlayer?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func attachTransport(to player: AVPlayer) {
        detachTransport()
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }   // don't fight an active scrub/seek
                self.currentTime = t.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.seek(to: 0)
            }
        }
    }
    private func detachTransport() {
        if let timeObserver { previewPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    // MARK: Derived

    var snapshot: StudioProjectSnapshot { undo.current }
    /// The snapshot's clips restricted to the current scope (all of them when `visibleClipMediaIDs` is
    /// `nil`). Display/timeline/preview/export read this; the **edit** path still mutates the full
    /// `snapshot.clips` by id, so a scoped edit persists to the shared project.
    private var visibleSnapshotClips: [TimelineClip] {
        StudioGeometry.filterByMedia(snapshot.clips, to: visibleClipMediaIDs)
    }
    /// The snapshot handed to the composer for preview/export — scoped to the visible clips. Unscoped
    /// (`visibleClipMediaIDs == nil`) returns the snapshot untouched, so the workout studio is identical.
    private var scopedSnapshot: StudioProjectSnapshot {
        guard visibleClipMediaIDs != nil else { return snapshot }
        var s = snapshot
        s.clips = visibleSnapshotClips
        return s
    }
    var clips: [TimelineClip] { StudioGeometry.ordered(visibleSnapshotClips) }
    var canUndo: Bool { undo.canUndo }
    var canRedo: Bool { undo.canRedo }
    var selectedClip: TimelineClip? { clips.first { $0.id == selectedClipID } }
    var overlays: [OverlayItem] { snapshot.overlays }
    var selectedOverlay: OverlayItem? { overlays.first { $0.id == selectedOverlayID } }
    var aspect: ClipEditGeometry.OutputAspect { snapshot.aspect }
    /// Canvas width:height for placing the overlay layer over the preview. `.original` has no fixed
    /// ratio (it follows the source) — fall back to the studio's 9:16 default for the editing rect.
    var previewRatio: CGFloat { aspect.ratio ?? (9.0 / 16.0) }
    var totalDuration: Double {
        StudioGeometry.totalDuration(clips: visibleSnapshotClips, sourceDurations: sourceDurations,
                                     transitions: snapshot.transitions)
    }
    func transitionKind(afterClipID: UUID) -> StudioTransitionKind {
        snapshot.transitions.first { $0.afterClipID == afterClipID }?.kind ?? .none
    }
    func outputDuration(of clip: TimelineClip) -> Double {
        StudioGeometry.clipOutputDuration(clip, sourceDuration: sourceDurations[clip.id])
    }
    /// Clips placed on the output timeline (start/duration in seconds) — the layout the scrubbable
    /// timeline strip and the playhead share with the composition.
    var placedClips: [StudioGeometry.PlacedClip] {
        StudioGeometry.timeline(clips: visibleSnapshotClips, sourceDurations: sourceDurations,
                                transitions: snapshot.transitions)
    }
    /// The resolved source length for a clip (asset duration), or its trimmed end as a fallback.
    func sourceDuration(of clip: TimelineClip) -> Double {
        sourceDurations[clip.id] ?? clip.trimEnd ?? outputDuration(of: clip)
    }

    // MARK: Lifecycle

    func onAppear() async {
        loadHRSeries()
        for clip in clips where !clip.isPhoto && sourceDurations[clip.id] == nil {
            if let d = await composer.sourceDuration(localIdentifier: clip.localIdentifier) {
                sourceDurations[clip.id] = d
            }
        }
        await rebuildPreview()
    }

    /// Load the session's HR samples (FK by `sessionID`) so the HR chart overlay can render. The
    /// whole series maps across the whole video; the playhead dot tracks the video's progress.
    private func loadHRSeries() {
        guard hrSeries.isEmpty else { return }
        // The project's session may be a workout OR a Kilter board session (shared studio).
        hrSeries = SessionHRSeries.forSession(project.sessionID, in: context)
    }
    /// True when the session has enough HR data to draw a chart.
    var hasHRData: Bool { hrSeries.count >= 2 }
    var hrOverlay: HROverlayConfig? { snapshot.hrOverlay }

    /// Bumped on each rebuild so a slow, superseded rebuild (e.g. two quick PiP nudges) doesn't
    /// clobber the newer player once its async composition finally returns.
    private var rebuildGeneration = 0

    private func rebuildPreview() async {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        isBuildingPreview = true
        defer { if generation == rebuildGeneration { isBuildingPreview = false } }
        previewError = nil
        // Preserve the playhead across the rebuild — an edit (split/trim/filter/…) shouldn't snap it
        // back to the start. Restored (clamped to the new total) on the player below.
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        do {
            // `forPlayback` drops the Core Animation overlay tool, which AVPlayerItem rejects
            // (export-only). Overlays therefore don't show in the live preview — they DO in export.
            let (comp, vc, audioMix) = try await composer.makeComposition(
                for: scopedSnapshot, sourceDurations: sourceDurations, hrSamples: hrSeries, forPlayback: true)
            // A newer edit already kicked off a rebuild while we awaited — drop this stale result.
            guard generation == rebuildGeneration else { return }
            let item = AVPlayerItem(asset: comp)
            item.audioMix = audioMix
            // `AVPlayerItem.setVideoComposition` validates more strictly than the export path and
            // RAISES an NSException (not a Swift error) for a composition it rejects — which the
            // `do/catch` above can't catch, so it would abort the whole app on opening the studio.
            // Guard it via the ObjC bridge: on rejection, keep the studio open with an unstyled
            // preview (export, which tolerates the same composition, still works) and report why.
            if let vc, let ex = ObjCException.catching({ item.videoComposition = vc }) {
                let reason = ex.reason ?? ex.name.rawValue
                Self.log.error("AVPlayerItem rejected videoComposition: \(reason, privacy: .public)")
                previewError = "Preview unavailable: \(reason)"
                item.videoComposition = nil   // play the raw stitch rather than nothing
            }
            // REUSE the existing AVPlayer (swap only its item) rather than building a new one. A fresh
            // AVPlayer makes the player layer detach/reattach → a black flash on every edit (the PiP
            // "flicker"). `replaceCurrentItem` keeps the same render surface; paired with the asset
            // cache the swap is quick and seamless.
            detachTransport()
            isPlaying = false
            if let player = previewPlayer {
                player.replaceCurrentItem(with: item)
                attachTransport(to: player)
            } else {
                let player = AVPlayer(playerItem: item)
                previewPlayer = player
                attachTransport(to: player)
            }
            // Restore the playhead (clamped to the possibly-changed total) instead of resetting to 0.
            seek(to: resumeAt)
            if wasPlaying { play() }   // keep playing across a live edit instead of pausing.
        } catch {
            guard generation == rebuildGeneration else { return }
            previewPlayer = nil   // device-only: no resolvable assets on the simulator
        }
    }

    // MARK: Edits (all via the pure StudioProjectEditor → undo → persist → rebuild)

    private func edit(_ transform: (StudioProjectSnapshot) -> StudioProjectSnapshot) {
        undo.commit(transform(undo.current))
        persist()
        Task { await rebuildPreview() }
    }
    /// An edit that only touches **overlays** — they're not in the playback composition (overlays are
    /// the WYSIWYG SwiftUI layer on top of the preview), so skip the player rebuild to avoid a flicker
    /// / playback restart on every drag. Still commits to undo + persists.
    private func editOverlaysOnly(_ transform: (StudioProjectSnapshot) -> StudioProjectSnapshot) {
        undo.commit(transform(undo.current))
        persist()
    }
    func undoEdit() { undo.undo(); persist(); Task { await rebuildPreview() } }
    func redoEdit() { undo.redo(); persist(); Task { await rebuildPreview() } }
    private func persist() { undo.current.apply(to: project); try? context.save() }

    func select(_ id: UUID?) { selectedClipID = id }

    func deleteSelected() {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.removeClip($0, id: id) }
        selectedClipID = nil
    }
    func moveSelected(by delta: Int) {
        // `clips` is the (possibly scoped) visible list; map the move to an index in the FULL project
        // so a reorder inside a scoped studio swaps with the adjacent visible neighbor without
        // disturbing hidden clips. Unscoped, this is the plain `index + delta`.
        guard let id = selectedClipID,
              let dest = StudioGeometry.reorderDestination(
                id: id, by: delta, visible: clips, full: StudioGeometry.ordered(snapshot.clips))
        else { return }
        edit { StudioProjectEditor.moveClip($0, id: id, toIndex: dest) }
    }
    /// Split the selected video clip at its midpoint (a playhead-driven split lands in S1's timeline polish).
    func splitSelected() {
        guard let clip = selectedClip, !clip.isPhoto else { return }
        let mid = outputDuration(of: clip) / 2
        edit { StudioProjectEditor.splitClip($0, id: clip.id, atOutputOffset: mid,
                                             sourceDuration: sourceDurations[clip.id]) }
    }
    /// Split at the **playhead**: find the clip under `currentTime` and cut it there (the edits-style
    /// split). Falls back to splitting the selected clip at its midpoint if the playhead isn't over a
    /// video clip (e.g. before playback has moved it).
    func splitAtPlayhead() {
        let placed = StudioGeometry.timeline(clips: visibleSnapshotClips, sourceDurations: sourceDurations,
                                             transitions: snapshot.transitions)
        guard let p = placed.first(where: { currentTime >= $0.startSec && currentTime < $0.endSec }),
              !p.clip.isPhoto else { splitSelected(); return }
        selectedClipID = p.clip.id
        edit { StudioProjectEditor.splitClip($0, id: p.clip.id, atOutputOffset: currentTime - p.startSec,
                                             sourceDuration: sourceDurations[p.clip.id]) }
    }
    func setSelectedSpeed(_ speed: Double) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setClipSpeed($0, id: id, speed: speed) }
    }
    /// Commit a trim on the selected clip (seconds within the source). Clamped so the trimmed span
    /// keeps a minimum length. The timeline view drives this **once on drag-end** (the live handle
    /// feedback is view-local), so there's one undo entry + one preview rebuild per trim.
    func trimSelected(startSeconds: Double?, endSeconds: Double?) {
        guard let clip = selectedClip, !clip.isPhoto else { return }
        let src = sourceDuration(of: clip)
        let minLen = 0.1
        var start = startSeconds ?? clip.trimStart
        var end = endSeconds ?? clip.trimEnd ?? src
        start = max(0, min(start, end - minLen))
        end = min(src, max(end, start + minLen))
        edit { StudioProjectEditor.trimClip($0, id: clip.id, start: start, end: end) }
    }
    func setSelectedFilter(_ filter: StudioFilter) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setClipFilter($0, id: id, filter: filter) }
    }
    func setSelectedAdjust(_ adjust: ClipAdjust) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setClipAdjust($0, id: id, adjust: adjust) }
    }
    func setSelectedVolume(_ volume: Double) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setClipVolume($0, id: id, volume: volume) }
    }
    func setTransitionAfterSelected(_ kind: StudioTransitionKind) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setTransition($0, afterClipID: id, kind: kind) }
    }
    func setAspect(_ aspect: ClipEditGeometry.OutputAspect) {
        edit { StudioProjectEditor.setAspect($0, aspect) }
    }
    func addText(_ string: String) {
        let overlay = OverlayItem(kind: .text, content: string)
        editOverlaysOnly { StudioProjectEditor.addOverlay($0, overlay) }
        selectedOverlayID = overlay.id   // select the new overlay so it's ready to drag
    }

    /// Replace a text / climb-name overlay's content (the studio's "Edit text").
    func editOverlayText(_ id: UUID, _ text: String) {
        editOverlaysOnly { StudioProjectEditor.setOverlayContent($0, id: id, content: text) }
    }

    // MARK: - Climb-name overlay (auto-filled from the clip's assigned climb; mirrors the HR overlay)

    /// Overlay ids whose caption currently includes the setter (transient — the caption string itself
    /// is the persisted source of truth; this just remembers the toggle for re-deriving on change).
    private var climbSetterEnabled: Set<UUID> = []

    /// True when a climb resolves for the selected (or any) clip — gates the "Climb" action button.
    var hasClimbInfo: Bool { resolvedClimbUUID != nil }

    /// Add a climb-name overlay (a styled lower-third), prefilled with the resolved climb's
    /// name · grade · angle, positioned low-centre. The text stays freely editable afterwards.
    func addClimbNameOverlay() {
        guard let uuid = resolvedClimbUUID else { return }
        let caption = climbCaption(uuid: uuid, includeSetter: false)
        let overlay = OverlayItem(kind: .climbName, content: caption, startSec: 0,
                                  endSec: max(3, totalDuration),
                                  position: CGPoint(x: 0.5, y: 0.85))
        editOverlaysOnly { StudioProjectEditor.addOverlay($0, overlay) }
        selectedOverlayID = overlay.id
    }

    /// True when the selected climb-name overlay's caption includes the setter.
    var selectedClimbShowsSetter: Bool {
        guard let id = selectedOverlayID else { return false }
        return climbSetterEnabled.contains(id)
    }

    /// Toggle the setter on the selected climb-name overlay, re-deriving its caption from the climb.
    /// (Resets any manual text edit — the toggle re-fills from the climb data.)
    func setSelectedClimbShowsSetter(_ on: Bool) {
        guard let ov = selectedOverlay, ov.kind == .climbName, let uuid = resolvedClimbUUID else { return }
        if on { climbSetterEnabled.insert(ov.id) } else { climbSetterEnabled.remove(ov.id) }
        let caption = climbCaption(uuid: uuid, includeSetter: on)
        editOverlayText(ov.id, caption)
    }

    /// The climb uuid backing the caption: the selected clip's assignment, else the first assigned clip.
    private var resolvedClimbUUID: String? {
        if let u = assignedClimbUUID(for: selectedClip) { return u }
        return clips.lazy.compactMap { self.assignedClimbUUID(for: $0) }.first
    }

    /// A clip's assigned climb uuid via its `SessionMedia` (nil for unassigned / non-Kilter clips).
    private func assignedClimbUUID(for clip: TimelineClip?) -> String? {
        guard let mediaID = clip?.sessionMediaID else { return nil }
        var d = FetchDescriptor<SessionMedia>(predicate: #Predicate { $0.id == mediaID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.assignedClimbUUID
    }

    /// Build the caption for a climb: name · grade · angle from the persisted `KilterLogEntry`
    /// (queryable without the SQLite catalog); the setter from the read-only `KilterCatalog`.
    private func climbCaption(uuid: String, includeSetter: Bool) -> String {
        let entry = logEntry(climbUUID: uuid)
        let setter = includeSetter ? KilterCatalog.shared.climb(uuid)?.setter : nil
        return KilterClimbCaption.caption(name: entry?.climbName ?? "",
                                          gradeLabel: entry?.gradeLabel ?? "",
                                          angle: entry?.angle ?? 0,
                                          setter: setter, includeSetter: includeSetter)
    }

    /// The log entry for a climb — prefer one tagged to this session, else any entry for the climb.
    private func logEntry(climbUUID: String) -> KilterLogEntry? {
        let sid: UUID? = project.sessionID
        var inSession = FetchDescriptor<KilterLogEntry>(
            predicate: #Predicate { $0.climbUUID == climbUUID && $0.sessionId == sid })
        inSession.fetchLimit = 1
        if let hit = (try? context.fetch(inSession))?.first { return hit }
        var any = FetchDescriptor<KilterLogEntry>(predicate: #Predicate { $0.climbUUID == climbUUID })
        any.fetchLimit = 1
        return (try? context.fetch(any))?.first
    }

    // MARK: Overlay editing (WYSIWYG — SwiftUI layer over the preview, not in the composition)

    func selectOverlay(_ id: UUID?) { selectedOverlayID = id }

    /// Commit a dragged overlay to its new normalized centre (`0…1`, top-left). A `.video` (PiP)
    /// overlay is in the playback composition, so it rebuilds; text/sticker don't (no rebuild).
    func setOverlayPosition(_ id: UUID, normalized: CGPoint) {
        let isVideo = overlays.first { $0.id == id }?.kind == .video
        let t: (StudioProjectSnapshot) -> StudioProjectSnapshot = {
            StudioProjectEditor.setOverlayPosition($0, id: id, position: normalized)
        }
        isVideo ? edit(t) : editOverlaysOnly(t)
    }
    /// Resize an overlay. For text/sticker/climb-name this scales the font (no playback rebuild — they
    /// render via the export-only Core Animation tool); a PiP `.video` is in the composition so it
    /// rebuilds. PiP frame sizing normally goes through `setOverlayFrame` (per-axis); this is the
    /// uniform-scale path used by the Size slider / pinch.
    func setOverlayScale(_ id: UUID, _ scale: Double) {
        let isVideo = overlays.first { $0.id == id }?.kind == .video
        let t: (StudioProjectSnapshot) -> StudioProjectSnapshot = {
            StudioProjectEditor.setOverlayScale($0, id: id, scale: scale)
        }
        isVideo ? edit(t) : editOverlaysOnly(t)
    }

    // MARK: - Overlay timeline (how long an overlay stays on screen — the timeline lane)

    /// Overlays shown as bars in the timeline lane (every overlay carries a `[startSec, endSec]`).
    var timelineOverlays: [OverlayItem] { overlays }

    /// Set an overlay's on-screen window (output seconds) — the timeline lane's move/trim commit. A
    /// `.video` PiP is in the playback composition (rebuild); text/sticker/climbName are not.
    func setOverlayTimeRange(_ id: UUID, start: Double, end: Double) {
        let isVideo = overlays.first { $0.id == id }?.kind == .video
        let t: (StudioProjectSnapshot) -> StudioProjectSnapshot = {
            StudioProjectEditor.setOverlayTimeRange($0, id: id, start: start, end: end)
        }
        isVideo ? edit(t) : editOverlaysOnly(t)
    }

    // MARK: - PiP frames + collage grids (per-axis size; in the composition → rebuild)

    /// Whether dragging/resizing a PiP snaps to the alignment grid (rule-of-thirds / centre / edges).
    var snapEnabled = true

    /// Commit a PiP's per-axis frame (normalized centre + size), snapping to the grid when enabled.
    func setOverlayFrame(_ id: UUID, center: CGPoint, size: CGSize) {
        let c = snapEnabled ? StudioGridLayout.snap(center: center, size: size).center : center
        edit { StudioProjectEditor.setOverlayFrame($0, id: id, center: c, size: size) }
    }

    /// Arrange the PiP overlays into a one-tap collage layout.
    func applyPiPGrid(_ preset: StudioGridLayout.Preset) {
        edit { StudioProjectEditor.applyPiPGrid($0, preset: preset) }
    }

    // MARK: - Base-video frame (collage — the main video as a resizable cell; in the composition)

    /// The main video's collage frame, or `nil` when it fills the whole canvas (legacy).
    var baseFrame: StudioFrameRect? { snapshot.baseFrame }
    /// Whether the main video is currently framed into a sub-rect (drives the canvas handle + toggle).
    var baseFramed: Bool { snapshot.baseFrame != nil }

    /// Toggle base framing: on → a centred half-cell the user can then drag/resize; off → full canvas.
    func toggleBaseFrame() {
        if baseFramed { edit { StudioProjectEditor.clearBaseFrame($0) } }
        else {
            edit { StudioProjectEditor.setBaseFrame($0, center: StudioFrameRect.half.center,
                                                    size: StudioFrameRect.half.size) }
        }
    }

    /// Commit a dragged/resized base frame (normalized centre + size), snapping to the grid when on.
    func setBaseFrame(center: CGPoint, size: CGSize) {
        let c = snapEnabled ? StudioGridLayout.snap(center: center, size: size).center : center
        edit { StudioProjectEditor.setBaseFrame($0, center: c, size: size) }
    }

    // MARK: Heart-rate chart overlay (preview = SwiftUI layer; export = Core Animation; no rebuild)

    func toggleHROverlay() {
        let enable = hrOverlay == nil
        editOverlaysOnly { var s = $0; s.hrOverlay = enable ? .default : nil; return s }
    }
    func updateHROverlay(_ config: HROverlayConfig) {
        editOverlaysOnly { var s = $0; s.hrOverlay = config; return s }
    }
    /// Commit the dragged HR chart to a new normalized centre (0…1, top-left).
    func setHRPosition(_ normalized: CGPoint) {
        guard var c = hrOverlay else { return }
        c.position = CGPoint(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
        updateHROverlay(c)
    }
    /// Commit a pinch-resize of the HR chart (width as a fraction of the canvas).
    func setHRScale(_ scale: Double) {
        guard var c = hrOverlay else { return }
        c.scale = min(1, max(0.3, scale))
        updateHROverlay(c)
    }

    // MARK: Picture-in-picture (a second video composited over the main track)

    /// True when the project has at least one picture-in-picture overlay (gates the Grid tool).
    var hasPiP: Bool { overlays.contains { $0.kind == .video } }

    /// Source clips available to drop in as a PiP (the session's main-track video clips).
    var pipSources: [(id: UUID, label: String, localIdentifier: String)] {
        clips.enumerated().compactMap { i, c in
            c.isPhoto ? nil : (c.id, "Clip \(i + 1)", c.localIdentifier)
        }
    }
    /// Add a picture-in-picture overlay from a source clip's `localIdentifier`, defaulting to a small
    /// top-right frame spanning the whole timeline.
    func addPiP(localIdentifier: String) {
        let ov = OverlayItem(kind: .video, content: localIdentifier, startSec: 0,
                             endSec: max(3, totalDuration),
                             position: CGPoint(x: 0.72, y: 0.28), scale: 0.4)
        edit { StudioProjectEditor.addOverlay($0, ov) }
        selectedOverlayID = ov.id
    }

    func deleteOverlay(_ id: UUID) {
        let isVideo = overlays.first { $0.id == id }?.kind == .video
        let t: (StudioProjectSnapshot) -> StudioProjectSnapshot = { StudioProjectEditor.removeOverlay($0, id: id) }
        isVideo ? edit(t) : editOverlaysOnly(t)   // a PiP is in the composition → rebuild
        if selectedOverlayID == id { selectedOverlayID = nil }
    }
    func setOverlayOpacity(_ id: UUID, _ opacity: Double) {
        editOverlaysOnly { StudioProjectEditor.setOverlayOpacity($0, id: id, opacity: opacity) }
    }
    /// Capture the selected overlay's current opacity as a keyframe at the playhead (the marker
    /// button). Two keyframes of differing opacity → the overlay fades over output time.
    func addOverlayKeyframeAtPlayhead() {
        guard let ov = selectedOverlay else { return }
        editOverlaysOnly {
            StudioProjectEditor.addOverlayOpacityKeyframe($0, id: ov.id, timeSec: currentTime, value: ov.opacity)
        }
    }

    // MARK: Audio tracks (added music)

    var musicTracks: [AudioTrack] { snapshot.audioTracks.filter { $0.kind != .original } }

    /// Import a picked audio file as a background music track: copy it into the app's Documents (so it
    /// survives the security-scoped picker URL) and add an `AudioTrack` the composer mixes in.
    func addMusic(from pickedURL: URL) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let ext = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension
        let filename = "studio-music-\(UUID().uuidString).\(ext)"
        let dest = docs.appendingPathComponent(filename)
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
        do { try FileManager.default.copyItem(at: pickedURL, to: dest) }
        catch { Self.log.error("music import failed: \(error.localizedDescription, privacy: .public)"); return }
        let track = AudioTrack(kind: .music, sourceRef: filename, startSec: 0, volume: 0.8)
        edit { StudioProjectEditor.addAudioTrack($0, track) }
    }
    func removeMusic(_ id: UUID) { edit { StudioProjectEditor.removeAudioTrack($0, id: id) } }

    // MARK: Export (device-only render)

    func export() async {
        exportState = .exporting
        do {
            let url = try await composer.export(scopedSnapshot, sourceDurations: sourceDurations,
                                                hrSamples: hrSeries, quality: exportQuality)
            exportState = .exported(url)
        } catch {
            exportState = .failed((error as? LocalizedError)?.errorDescription ?? "Export failed.")
        }
    }
}
