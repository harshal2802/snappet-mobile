import SwiftUI
import SwiftData
import AVFoundation
import HighlightEngine
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
    /// Not private so a test can see what it keeps (`hasOpened`); nothing else reaches in.
    let composer = StudioComposer()
    /// Reports where the timeline's Photos videos are and downloads the iCloud ones (prompt 302).
    /// Asked before the composer, so the composer is only handed clips that are on this phone.
    private let availability: any StudioMediaAvailabilityChecking
    /// Writes the store. A property so a test can make the save fail; nothing else replaces it.
    @ObservationIgnored var saver: (ModelContext) throws -> Void = { try $0.save() }
    /// Reads a video's real length. `nil` (always, in the app) asks the composer; a test sets it,
    /// because the simulator has no Photos videos to read.
    @ObservationIgnored var sourceDurationLoader: (@MainActor (String) async -> Double?)?
    /// Makes the rendered file for a bake or an export. `nil` (always, in the app) renders with
    /// the composer; a test sets it, because the composer needs real Photos videos.
    @ObservationIgnored var renderOverride: (@MainActor () async throws -> URL)?
    /// What Photos says about a baked asset, for revert detection. `nil` (always, in the app)
    /// asks Photos (`ClipBakeService`); a test sets it, because the simulator has no baked asset
    /// to revert (prompt 305).
    @ObservationIgnored var bakedAssetProbe: (@Sendable (String) -> BakedAssetProbe)?
    /// Moves the player to a player time and calls back when it is there. `nil` (always, in the
    /// app) seeks the preview player; `useStandInPlayer` sets it for a test.
    @ObservationIgnored private var playerSeek: (@MainActor (Double, @escaping @MainActor () -> Void) -> Void)?
    private var undo: UndoStack<StudioProjectSnapshot>

    /// When set, the studio is **scoped** to the clips backed by these `SessionMedia.id`s (per-clip or
    /// per-climb editing from Kilter). `nil` (the workout default) shows the whole project. Edits still
    /// target the full project by clip id — only the display, preview, timeline, and export are scoped,
    /// so a scoped edit carries into every other scope of the same shared project.
    let visibleClipMediaIDs: Set<UUID>?

    /// A FREEFORM climb's caption ("Cave Roof · V5"), threaded from the Quick Session player when the
    /// opened clip belongs to a `.climbAttempt` exercise (prompt 09). A freeform climb has no Kilter
    /// `KilterLogEntry`, so `resolvedClimbUUID` is nil — this lets the "Add climb name" action still drop
    /// the same `.climbName` lower-third, seeded with this caption. `nil` for Kilter / non-climb clips.
    private let suggestedClimbCaption: String?

    /// The 1-based attempt number the focused clip belongs to (prompt 10), threaded from the Quick Session
    /// player when the opened clip is a single climb attempt. Gates + feeds the user-toggleable "Attempt #"
    /// option on the climb-name tag. `nil` when there's no single attempt to tag (whole-session reel /
    /// non-attempt clip / the combined "Edit all clips" view spanning many attempts).
    let suggestedAttemptNumber: Int?

    /// The editor's ONE state (prompt 301): selection, both render lanes, the preview's load state
    /// and the player's status. It changes only through `send(_:)`; the phase and what is allowed
    /// in it (`canEdit`, `canPlay`, `canExport`, `canClose`) are derived from it.
    private(set) var state = StudioEditorState()

    /// The one place the state changes. It also deletes the exported temp file the old state held
    /// and the new one does not (`ExportShareState.fileToDelete`, prompt 298).
    private func send(_ event: StudioEditorState.Event) {
        let next = state.reducing(event)
        if let stale = state.export.fileToDelete(movingTo: next.export) {
            try? FileManager.default.removeItem(at: stale)
        }
        if next != state { state = next }
    }

    /// The selection is one value (`StudioSelection`): a clip, an overlay, or nothing. These two
    /// read and write it by id, so callers that think in ids did not have to change.
    var selectedClipID: UUID? {
        get { state.selection.clipID }
        set { send(.select(state.selection.settingClip(newValue))) }
    }
    var selectedOverlayID: UUID? {
        get { state.selection.overlayID }
        set { send(.select(state.selection.settingOverlay(newValue))) }
    }
    /// Each video clip's REAL source length, read from the asset. Only clips that are on this
    /// phone have one. This is what the composer is handed.
    private(set) var sourceDurations: [UUID: Double] = [:]
    /// The length Snappet recorded when each video was added (`SessionMedia.durationSec`), by
    /// media id and by Photos identifier. The timeline's fallback for a clip that is not on this
    /// phone (prompt 303): its real length cannot be read, and without one it is 0 s long.
    private var recordedDurations: [UUID: Double] = [:]
    private var recordedDurationsByLocalID: [String: Double] = [:]
    /// Resolved oriented aspect ratio (w/h) per source `localIdentifier` — sizes a new PiP / base cell
    /// to its footage so the editor outline matches the aspect-fit video. Empty on the simulator.
    private(set) var sourceAspects: [String: CGFloat] = [:]
    /// The session's heart-rate samples (for the HR chart overlay), loaded on appear from the FK.
    private(set) var hrSeries: [HRPoint] = []
    /// `SessionMedia.id` → its capture clock (`offsetSec` and, for a baked asset, `bakeTimeMap`:
    /// prompt 305), loaded once, so each clip's HR can be sliced to the moment it was filmed
    /// (keyed by media id, not clip id, so a split clip inherits it).
    private var mediaClocks: [UUID: ClipCaptureClock] = [:]
    /// The `localIdentifier` → clock fallback for clips whose `sessionMediaID` link was lost.
    private var mediaClocksByLocalID: [String: ClipCaptureClock] = [:]
    /// The user's HR profile (set by the view via `loadOverlayContext`) — needed to resolve per-clip
    /// calorie/HRV badges over each clip's own window.
    private var hrProfile: UserHRProfile?
    /// The preview's player. Set and cleared only by `rebuildPreview` / `teardownPlayer`, together
    /// with `state.hasPlayer`.
    private(set) var previewPlayer: AVPlayer?
    var isBuildingPreview: Bool { state.isBuildingPreview }
    /// Set when the player rejects the composition (see `rebuildPreview`) or its item fails — the
    /// studio stays open (no crash) and the canvas shows this instead of a silent black frame;
    /// export still works.
    var previewError: String? { state.previewMessage }
    var exportState: ExportShareState { state.export }

    // Transport (custom play/pause + live timecode + a scrub playhead, driving the edits-style UI).
    /// What the play/pause button shows. READ from the real player's status (prompt 301), so an
    /// interruption, a stall or a failed item cannot leave it wrong.
    var isPlaying: Bool { state.showsPause }
    /// The playhead position in **output** seconds, updated by a periodic observer while playing and
    /// by scrubbing the timeline. Drives the timecode label and the timeline's centre playhead.
    private(set) var currentTime: Double = 0
    private var timeObserver: Any?
    private var endObservers: [NSObjectProtocol] = []
    private var playerObservations: [NSKeyValueObservation] = []
    /// The player the observers above are attached to (they must be removed from the same one).
    private var observedPlayer: AVPlayer?
    /// Which clock ticks may move the playhead: none while a seek is still in flight (prompt 303).
    @ObservationIgnored private var seekGate = StudioSeekGate()
    /// Bumped whenever the observers are attached or removed, so a callback from an item that has
    /// been replaced is ignored.
    private var transportGeneration = 0

    /// Output-quality preset for export, shown in the top bar and passed to `composer.export`.
    var exportQuality: StudioExportQuality = .hd1080

    private static let log = Logger(subsystem: "com.snappet.app", category: "studio")

    init(project: StudioProject, context: ModelContext, visibleClipMediaIDs: Set<UUID>? = nil,
         suggestedClimbCaption: String? = nil, suggestedAttemptNumber: Int? = nil,
         availability: any StudioMediaAvailabilityChecking = StudioMediaAvailabilityService()) {
        self.project = project
        self.context = context
        self.availability = availability
        self.visibleClipMediaIDs = visibleClipMediaIDs
        self.suggestedClimbCaption = suggestedClimbCaption?.isEmpty == false ? suggestedClimbCaption : nil
        self.suggestedAttemptNumber = (suggestedAttemptNumber ?? 0) > 0 ? suggestedAttemptNumber : nil
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
        guard state.canPlay, let player = previewPlayer else { return }
        // restart from the top if at the end (of what is played: a "preview without it" is shorter)
        if StudioTransport.restartsFromTop(
            position: playerGaps.playerTime(forTimelineTime: currentTime),
            duration: playerGaps.playableDuration(total: totalDuration)) { seek(to: 0) }
        player.play()
        syncTransport()
    }
    func pause() {
        previewPlayer?.pause()
        syncTransport()
    }

    /// Move the playhead (and the player) to `seconds` (clamped to the timeline).
    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, totalDuration))
        currentTime = clamped
        guard playerSeek != nil || previewPlayer != nil else { return }
        // Until the player has finished this seek its clock still reports the old position; the
        // gate keeps those ticks from moving the playhead back (prompt 303).
        let generation = seekGate.begin()
        let target = playerGaps.playerTime(forTimelineTime: clamped)
        if let playerSeek {
            playerSeek(target) { [weak self] in self?.seekGate.finish(generation) }
            return
        }
        guard let player = previewPlayer else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.seekGate.finish(generation) }
        }
    }

    /// The parts of the timeline the current preview leaves out ("Preview without it", prompt
    /// 302). Empty in every other case, when the player's clock IS the timeline's.
    private var playerGaps = StudioPreviewGaps()

    /// Copy the real player's status into the state. Called from the player's own observers and
    /// right after `play()` / `pause()`; it always reads the player, never a remembered intent.
    private func syncTransport() {
        let status: StudioPlayerStatus
        switch previewPlayer?.timeControlStatus {
        case .playing: status = .playing
        case .waitingToPlayAtSpecifiedRate: status = .waiting
        case .paused, .none: status = .paused
        @unknown default: status = .paused
        }
        playerStatusChanged(status)
    }

    private func playerStatusChanged(_ status: StudioPlayerStatus) {
        send(.playerStatusChanged(status))
    }

    /// For a test only: behave as if a preview was built and its player plays, with `seek`
    /// standing in for the player's seek. The simulator never has a preview player.
    func useStandInPlayer(seek: @escaping @MainActor (Double, @escaping @MainActor () -> Void) -> Void) {
        playerSeek = seek
        send(.previewBuilt(warning: nil))
        playerStatusChanged(.playing)
    }

    /// The player's clock reported this time. The playhead follows it only while the player
    /// really plays, and not while a seek is still on its way (the clock then still reports the
    /// position from before the seek). Called by the clock observer, and by a test.
    func playerClockTicked(_ seconds: Double) {
        guard StudioTransport.followsPlayerClock(state.player), seekGate.acceptsTick else { return }
        currentTime = playerGaps.timelineTime(forPlayerTime: seconds)
    }

    /// The thin device edge of the transport: observe the player's clock, its play/pause status,
    /// and its item's end and failure. Everything decided from them is in `StudioTransport` /
    /// `StudioEditorState`.
    private func attachTransport(to player: AVPlayer) {
        detachTransport()
        observedPlayer = player
        let generation = transportGeneration
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                // don't fight an active scrub/seek (`playerClockTicked`)
                guard let self, self.transportGeneration == generation else { return }
                self.playerClockTicked(t.seconds)
            }
        }
        // Play/pause as the PLAYER reports it: an audio interruption, a stall, the end of the item.
        playerObservations.append(player.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.transportGeneration == generation else { return }
                self.syncTransport()
            }
        })
        guard let item = player.currentItem else { return }
        playerObservations.append(item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let reason = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.transportGeneration == generation else { return }
                self.previewItemFailed(reason)
            }
        })
        endObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.transportGeneration == generation else { return }
                self.seek(to: 0)
                self.syncTransport()
            }
        })
        endObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?
                .localizedDescription
            MainActor.assumeIsolated {
                guard let self, self.transportGeneration == generation else { return }
                self.previewItemFailed(reason)
            }
        })
    }
    private func detachTransport() {
        transportGeneration += 1
        if let timeObserver { observedPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        playerObservations.forEach { $0.invalidate() }
        playerObservations = []
        endObservers.forEach { NotificationCenter.default.removeObserver($0) }
        endObservers = []
        observedPlayer = nil
    }

    /// Remove the player and everything attached to it: the observers, the playing status, and a
    /// playhead past the end. Used when a preview cannot be made and when its item fails.
    private func teardownPlayer() {
        detachTransport()
        previewPlayer?.pause()
        previewPlayer?.replaceCurrentItem(with: nil)
        previewPlayer = nil
        seekGate.reset()
        playerGaps = StudioPreviewGaps()
        currentTime = StudioTransport.resumePosition(positionNow: currentTime, total: totalDuration)
    }

    /// The item being played failed. The player goes; the next edit builds a new preview.
    private func previewItemFailed(_ reason: String?) {
        Self.log.error("preview item failed: \(reason ?? "unknown", privacy: .public)")
        teardownPlayer()
        send(.previewUnavailable(message: "Preview unavailable: \(reason ?? "the video could not be played")"))
    }

    // MARK: Derived

    var snapshot: StudioProjectSnapshot { undo.current }
    /// The snapshot's clips restricted to the current scope (all of them when `visibleClipMediaIDs` is
    /// `nil`). Display/timeline/preview/export read this; the **edit** path still mutates the full
    /// `snapshot.clips` by id, so a scoped edit persists to the shared project.
    private var visibleSnapshotClips: [TimelineClip] {
        StudioGeometry.filterByMedia(snapshot.clips, to: visibleClipMediaIDs)
    }
    /// Overlays restricted to the current scope — the OVERLAY analogue of `visibleSnapshotClips`. Without
    /// it the single-clip editor (and the overlay-timeline lane, and the export) showed OTHER clips'
    /// per-clip climb tags, since `visibleClipMediaIDs` scoped only the clips (prompt 13). Resolves
    /// `clipID → owning clip → sessionMediaID` against the FULL `snapshot.clips`; whole-project overlays
    /// (`clipID == nil`) always pass; unscoped (`visibleClipMediaIDs == nil`) returns all.
    ///
    /// Read from `standDownSnapshot`, so the canvas, the overlay lane and the render also agree on
    /// what a baked clip hides (prompt 295).
    private var scopedOverlays: [OverlayItem] { standDownSnapshot.overlays }

    /// The snapshot scoped to the visible clips and their overlays, minus the project-wide items a
    /// baked clip already has in its pixels (its `baked` record, prompt 295). The ONE source for the preview and the render; the
    /// stored project (`snapshot`) keeps every item, and the tool sheets still read it.
    private var standDownSnapshot: StudioProjectSnapshot {
        var s = snapshot
        let visible = visibleSnapshotClips
        if visibleClipMediaIDs != nil { s.clips = visible }
        s.overlays = StudioGeometry.filterOverlays(snapshot.overlays, clips: snapshot.clips,
                                                   to: visibleClipMediaIDs)
        return ClipBakePlan.standingDown(s, visible: visible)
    }
    /// The snapshot handed to the composer for preview/export — scoped to the visible clips, with every
    /// `.climbName` tag RENDER-RESOLVED (composed string + per-clip window) so the exported file matches
    /// the editor (prompt 12). Unscoped (`visibleClipMediaIDs == nil`) keeps all clips; either way the
    /// overlays are resolved, so a per-clip climb tag exports only over its clip's segment.
    private var scopedSnapshot: StudioProjectSnapshot {
        var s = standDownSnapshot   // scoped clips + overlays (prompt 13), baked stand-down (295)
        s.overlays = renderedOverlays(s.overlays)
        return s
    }
    var clips: [TimelineClip] { StudioGeometry.ordered(visibleSnapshotClips) }
    var canUndo: Bool { undo.canUndo }
    var canRedo: Bool { undo.canRedo }
    var selectedClip: TimelineClip? { clips.first { $0.id == selectedClipID } }
    var overlays: [OverlayItem] { snapshot.overlays }
    var selectedOverlay: OverlayItem? { overlays.first { $0.id == selectedOverlayID } }
    /// Overlays prepared for the WYSIWYG canvas: `.climbName` tags carry their composed string + their
    /// clip-resolved window (so the canvas time-gate matches export). Selection/ids are preserved (the
    /// resolution keeps each overlay's `id`), so dragging/selecting still target the right overlay.
    var canvasOverlays: [OverlayItem] { renderedOverlays(scopedOverlays) }
    var aspect: ClipEditGeometry.OutputAspect { snapshot.aspect }
    /// Canvas width:height for placing the overlay layer over the preview. `.original` has no fixed
    /// ratio (it follows the source) — fall back to the studio's 9:16 default for the editing rect.
    var previewRatio: CGFloat { aspect.ratio ?? (9.0 / 16.0) }
    var totalDuration: Double {
        StudioGeometry.totalDuration(clips: visibleSnapshotClips, sourceDurations: timelineDurations,
                                     transitions: snapshot.transitions)
    }
    /// The source lengths the timeline is laid out with: the real length where it has been read,
    /// and the recorded one for a clip that is not on this phone (prompt 303). The composer is
    /// handed `sourceDurations`, never this.
    private var timelineDurations: [UUID: Double] {
        StudioGeometry.timelineSourceDurations(clips: snapshot.clips, resolved: sourceDurations) {
            recordedDuration(of: $0)
        }
    }
    /// The recorded length of a clip whose video is not on this phone; `nil` for one that is
    /// (its real length is read instead) and when nothing was recorded.
    private func recordedDuration(of clip: TimelineClip) -> Double? {
        guard mediaStatus(of: clip) != .available else { return nil }
        return clip.sessionMediaID.flatMap { recordedDurations[$0] }
            ?? recordedDurationsByLocalID[clip.localIdentifier]
    }
    /// The length a trim of this clip is measured against, or `nil` when it is not known yet.
    private func trimSourceLength(of clip: TimelineClip) -> Double? {
        StudioGeometry.trimSourceLength(clip, resolved: sourceDurations[clip.id],
                                        recorded: recordedDuration(of: clip))
    }
    /// A clip can be trimmed once its source length is known (prompt 303). The timeline shows the
    /// trim handles only then.
    func canTrim(_ clip: TimelineClip) -> Bool { trimSourceLength(of: clip) != nil }
    func transitionKind(afterClipID: UUID) -> StudioTransitionKind {
        snapshot.transitions.first { $0.afterClipID == afterClipID }?.kind ?? .none
    }
    func outputDuration(of clip: TimelineClip) -> Double {
        StudioGeometry.clipOutputDuration(clip, sourceDuration: timelineDurations[clip.id])
    }
    /// Clips placed on the output timeline (start/duration in seconds) — the layout the scrubbable
    /// timeline strip and the playhead share with the composition.
    var placedClips: [StudioGeometry.PlacedClip] {
        StudioGeometry.timeline(clips: visibleSnapshotClips, sourceDurations: timelineDurations,
                                transitions: snapshot.transitions)
    }
    /// The resolved source length for a clip (asset duration; the recorded length while the video
    /// is not on this phone), or its trimmed end as a fallback.
    func sourceDuration(of clip: TimelineClip) -> Double {
        timelineDurations[clip.id] ?? clip.trimEnd ?? outputDuration(of: clip)
    }

    // MARK: - Overlay render resolution (per-clip window + composed string — prompt 12)

    /// The on-screen window for an overlay, RESOLVED at render time. A clip-bound overlay (a per-clip
    /// `.climbName` tag, `clipID != nil`) takes its **current** placed slot's `[startSec, endSec]` — so
    /// trim/reorder/split never desync the tag from its clip; if the clip is gone (e.g. mid-undo) it
    /// falls back to the stored window. A whole-project overlay (`clipID == nil`) keeps its stored
    /// window. Used by BOTH the canvas time-gate and the export window (re-derived into the overlay).
    func outputWindow(for overlay: OverlayItem) -> (start: Double, end: Double) {
        if let clipID = overlay.clipID,
           let slot = placedClips.first(where: { $0.clip.id == clipID }) {
            return (slot.startSec, slot.endSec)
        }
        return (overlay.startSec, overlay.endSec)
    }

    /// The **rendered** string for a `.climbName` overlay: the user-editable base `content`, plus the
    /// system-composed ` · by {setter}` (when `showsSetter`) and `Attempt N` (when `showsAttempt`)
    /// lines — composed via the pure `KilterClimbCaption.composeClimbTag` so user text and system lines
    /// never share an encoding. Non-climb overlays return their `content` unchanged. The setter is
    /// resolved from the overlay's owning clip's Kilter assignment (nil for freeform). Used by BOTH the
    /// canvas chip and the export (the model keeps the base, so a manual edit is never wiped).
    func renderedContent(for overlay: OverlayItem) -> String {
        guard overlay.kind == .climbName else { return overlay.content }
        let setter = (overlay.showsSetter ? resolvedSetter(for: overlay) : nil)
        return KilterClimbCaption.composeClimbTag(
            base: overlay.content, setter: setter, showSetter: overlay.showsSetter,
            attempt: overlay.attemptNumber, showAttempt: overlay.showsAttempt)
    }

    /// Resolve the setter name for a climb tag from its owning clip's Kilter assignment (read-only
    /// `KilterCatalog`); `nil` for a freeform tag (no `KilterLogEntry`/catalog entry).
    private func resolvedSetter(for overlay: OverlayItem) -> String? {
        guard let clipID = overlay.clipID,
              let clip = snapshot.clips.first(where: { $0.id == clipID }),
              let uuid = assignedClimbUUID(for: clip) else { return nil }
        return KilterCatalog.shared.climb(uuid)?.setter
    }

    /// The overlays prepared for RENDER (canvas + composer): each `.climbName` tag's `content` is the
    /// fully composed string and its `[startSec, endSec]` is re-derived from its clip's current slot, so
    /// preview and export read the identical, up-to-date strings/windows. Empty-content tags are dropped
    /// (matching the export filter), so a tag with no caption never shows an invisible chip. The
    /// PERSISTED model is untouched — this is a derived view only.
    ///
    /// Every window is then cut to the timeline (`StudioGeometry.clampedToTimeline`, prompt 297): text,
    /// stickers and picture-in-picture carry absolute times, so a trim / speed change / delete / split
    /// can leave them past the end. One that starts at or after the end is left out; the stored times
    /// stay, so undoing the edit brings the window back.
    func renderedOverlays(_ overlays: [OverlayItem]) -> [OverlayItem] {
        let resolved: [OverlayItem] = overlays.compactMap { overlay in
            guard overlay.kind == .climbName else { return overlay }
            var ov = overlay
            ov.content = renderedContent(for: overlay)
            let w = outputWindow(for: overlay)
            ov.startSec = w.start
            ov.endSec = w.end
            return ov.content.isEmpty ? nil : ov
        }
        return StudioGeometry.clampedToTimeline(resolved, total: totalDuration)
    }

    // MARK: Lifecycle

    func onAppear(liveSamples: () -> [HRPoint] = { [] }) async {
        loadHRSeries(liveSamples: liveSamples)
        loadMediaOffsets()
        // Where the clips are FIRST (prompt 302): the composer downloads an iCloud clip silently
        // and skips a deleted one silently, so it is only asked about clips that are on this phone.
        await checkMediaAvailability()
        await loadSourceInfo()
        await rebuildPreview()
    }

    /// Resolve the length and shape of every clip that is on this phone and not resolved yet.
    /// Called when the Studio opens, after a download (the clip's recorded length gives way to
    /// its real one), and after a bake with `refreshing` = the baked clip (its video changed).
    private func loadSourceInfo(refreshing: Set<UUID> = []) async {
        for clip in clips where !clip.isPhoto
            && (sourceDurations[clip.id] == nil || refreshing.contains(clip.id))
            && state.media.status(of: clip.localIdentifier) == .available {
            if let d = await readSourceDuration(clip.localIdentifier) {
                sourceDurations[clip.id] = d
            }
            if sourceAspects[clip.localIdentifier] == nil,
               let a = await composer.sourceAspect(localIdentifier: clip.localIdentifier) {
                sourceAspects[clip.localIdentifier] = a
            }
        }
        // The timeline's length may have changed, and with it which picture-in-picture windows
        // are inside it.
        send(.mediaSourcesChanged(mediaSources))
    }

    private func readSourceDuration(_ localIdentifier: String) async -> Double? {
        if let sourceDurationLoader { return await sourceDurationLoader(localIdentifier) }
        return await composer.sourceDuration(localIdentifier: localIdentifier)
    }

    // MARK: Media availability (prompt 302)

    /// The Photos videos the render needs (`StudioMediaPlan.sources`): the visible video clips in
    /// timeline order, then the sources of the picture-in-picture windows that are inside the
    /// timeline. One wholly past the end is not drawn, so it does not block the export.
    private var mediaSources: [StudioMediaPlan.Source] {
        StudioMediaPlan.sources(clips: clips, overlays: scopedOverlays, total: totalDuration)
    }

    /// Ask the service where every source is. Called when the Studio opens, before any preview.
    /// Every picture-in-picture source is asked about, also one that is past the end of the
    /// timeline now: an Undo can bring it back inside, and it must not be unknown then.
    func checkMediaAvailability() async {
        loadMediaOffsets()      // the recorded lengths, for clips that turn out not to be here
        let identifiers = clips.filter { !$0.isPhoto }.map(\.localIdentifier)
            + scopedOverlays.filter { $0.kind == .video }.map(\.content)
        let statuses = await availability.statuses(for: identifiers)
        send(.mediaChecked(sources: mediaSources, statuses: statuses))
        // The sources depend on the timeline's length, which the statuses just changed (a clip
        // that is not here now has its recorded length).
        send(.mediaSourcesChanged(mediaSources))
    }

    /// Where a clip's video is — the timeline marks a clip that is not on this phone.
    func mediaStatus(of clip: TimelineClip) -> StudioAssetStatus {
        clip.isPhoto ? .available : state.media.status(of: clip.localIdentifier)
    }

    /// The running download. The view model owns it so it can be cancelled.
    private(set) var downloadTask: Task<Void, Never>?

    /// "Download clip": fetch the clip the panel is about from iCloud, with progress.
    func downloadMissingClip() {
        guard downloadTask == nil, let problem = state.media.blocking, problem.status == .inCloud
        else { return }
        let id = problem.source.localIdentifier
        downloadRequests += 1
        let request = downloadRequests
        send(.downloadBegan(id, request: request))
        guard state.media.download?.request == request else { return }
        downloadTask = Task { [weak self] in await self?.runDownload(id, request: request) }
    }
    /// Numbers each download, so a progress report that arrives late (the service reports through
    /// tasks of its own) cannot move the next download's bar (prompt 303).
    @ObservationIgnored private var downloadRequests = 0

    private func runDownload(_ localIdentifier: String, request: Int) async {
        defer { downloadTask = nil }
        do {
            try await availability.download(localIdentifier: localIdentifier) { [weak self] fraction in
                self?.send(.downloadProgressed(fraction, request: request))
            }
            guard !Task.isCancelled else { send(.downloadCancelled); return }
            send(.downloadFinished(localIdentifier))
            await loadSourceInfo()
            await rebuildPreview()
        } catch {
            if error is CancellationError || Task.isCancelled {
                send(.downloadCancelled)
            } else {
                Self.log.error("clip download failed: \(error.localizedDescription, privacy: .public)")
                send(.downloadFailed(StudioMediaPlan.downloadFailedMessage))
            }
        }
    }

    /// The download's Cancel button: the bar goes at once, with no message.
    func cancelClipDownload() {
        downloadTask?.cancel()
        send(.downloadCancelled)
    }

    /// "Preview without it": play what is on this phone. Export stays off.
    func previewWithoutMissingClips() {
        send(.previewWithoutMissing)
        scheduleRebuild()
    }

    /// Back from "Preview without it" to the panel.
    func showMissingClipOptions() {
        send(.showMissingOptions)
        scheduleRebuild()
    }

    /// "Remove clip from video": the normal delete, so Undo brings the clip back and the
    /// deletion is remembered (prompt 296). A picture-in-picture source removes its overlay.
    func removeMissingClip() {
        guard let problem = state.media.blocking ?? state.media.problems.first else { return }
        switch problem.source.role {
        case .clip(let id, _):
            select(id)
            deleteSelected()
        case .pip(let overlayID):
            deleteOverlay(overlayID)
        }
    }

    /// The save-failed message's close button.
    func dismissSaveFailure() { send(.saveFailureDismissed) }

    /// Load the session's HR samples (FK by `sessionID`) so the HR chart overlay can render. The
    /// whole series maps across the whole video; the playhead dot tracks the video's progress.
    private func loadHRSeries(liveSamples: () -> [HRPoint] = { [] }) {
        guard hrSeries.isEmpty else { return }
        // The project's session may be a workout OR a Kilter board session (shared studio). For a
        // still-live session whose hrSeries isn't flushed yet, fall back to the live coordinator buffer
        // the view supplies (the VM has no AppModel).
        hrSeries = SessionHRSeries.forSession(project.sessionID, in: context,
                                              liveSamples: liveSamples())
    }

    /// Load each tagged media's capture `offsetSec` once (the session's `SessionMedia` rows), so the
    /// per-clip HR windows can be sliced to when each clip was filmed. Keyed BOTH by `SessionMedia.id`
    /// and by the denormalized PHAsset `localIdentifier` — the fallback that heals clips whose media
    /// link was lost (they used to silently fall through to the whole-session HR burn).
    private func loadMediaOffsets() {
        guard mediaClocks.isEmpty else { return }
        let sid = project.sessionID
        let media = (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid }))) ?? []
        mediaClocks = Dictionary(media.map { ($0.id, $0.captureClock) }, uniquingKeysWith: { a, _ in a })
        mediaClocksByLocalID = Dictionary(media.map { ($0.localIdentifier, $0.captureClock) },
                                          uniquingKeysWith: { a, _ in a })
        let lengths = media.compactMap { m in m.durationSec.map { (m.id, m.localIdentifier, $0) } }
        recordedDurations = Dictionary(lengths.map { ($0.0, $0.2) }, uniquingKeysWith: { a, _ in a })
        recordedDurationsByLocalID = Dictionary(lengths.map { ($0.1, $0.2) }, uniquingKeysWith: { a, _ in a })
    }

    /// A clip's capture clock (its `SessionMedia` row's offset from session start and, for a
    /// baked asset, its time map: prompt 305), falling back to the `localIdentifier` map for an
    /// unlinked clip — routed through the pure, tested rule (`StudioHRPlacement.resolveClock`) so
    /// the shipping policy IS the tested one. Every heart-rate window in the Studio (preview
    /// tile, HR-window sliders, export) starts from this.
    private func captureClock(of clip: TimelineClip) -> ClipCaptureClock? {
        StudioHRPlacement.resolveClock(of: clip, byMediaID: mediaClocks,
                                       byLocalID: mediaClocksByLocalID)
    }
    /// True when the session has enough HR data to draw a chart.
    var hasHRData: Bool { hrSeries.count >= 2 }
    var hrOverlay: HROverlayConfig? { snapshot.hrOverlay }

    /// Bumped on each rebuild so a slow, superseded rebuild (e.g. two quick PiP nudges) doesn't
    /// clobber the newer player once its async composition finally returns.
    private var rebuildGeneration = 0

    /// Rebuild the preview in a task of its own (an edit does not wait for it). `first` runs
    /// before the build, in the same task. The tasks are kept until they end so a test can wait
    /// for them (`previewBuildsFinished`) instead of sleeping.
    private func scheduleRebuild(after first: (@MainActor () async -> Void)? = nil) {
        rebuildTaskCount += 1
        let number = rebuildTaskCount
        rebuildTasks[number] = Task {
            await first?()
            await rebuildPreview()
            rebuildTasks[number] = nil
        }
    }
    @ObservationIgnored private var rebuildTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var rebuildTaskCount = 0
    /// How many preview builds have begun. Read by tests.
    @ObservationIgnored private(set) var previewBuildCount = 0

    /// Returns when no scheduled preview rebuild is left running. For tests.
    func previewBuildsFinished() async {
        while let task = rebuildTasks.values.first { await task.value }
    }

    private func rebuildPreview() async {
        // Nothing is known yet about where the videos are (prompt 303): an edit made in the
        // opening window must not start a build, because the composer downloads an iCloud clip
        // without a word. `onAppear` builds the preview as soon as the first result is in, from
        // the project as it is then, so the edit is in it.
        guard state.canBuildPreview else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        previewBuildCount += 1
        send(.previewBuildBegan)
        // A clip is not on this phone and the user has not decided what to do (prompt 302): no
        // preview, and the composer is not asked (it would download or skip the clip silently).
        guard state.media.blocking == nil else {
            teardownPlayer()
            send(.previewUnavailable(message: nil))
            return
        }
        // "Preview without it": the composer gets only what is on this phone, and the playhead is
        // mapped across the slots that were left out. Everything else that carries a timeline
        // time (picture-in-picture windows and keyframes, music) is mapped the same way.
        let unavailable = state.media.unavailableIdentifiers
        let gaps = StudioPreviewGaps(slots: placedClips
            .filter { !$0.clip.isPhoto && unavailable.contains($0.clip.localIdentifier) }
            .map { (start: $0.startSec, end: $0.endSec) })
        let playable = gaps.playable(scopedSnapshot, unavailable: unavailable)
        do {
            // `forPlayback` drops the Core Animation overlay tool, which AVPlayerItem rejects
            // (export-only). Overlays therefore don't show in the live preview — they DO in export.
            let (comp, vc, audioMix) = try await composer.makeComposition(
                for: playable, sourceDurations: sourceDurations, hrSamples: hrSeries, forPlayback: true)
            // A newer edit already kicked off a rebuild while we awaited — drop this stale result.
            guard generation == rebuildGeneration else { return }
            let item = AVPlayerItem(asset: comp)
            item.audioMix = audioMix
            // `AVPlayerItem.setVideoComposition` validates more strictly than the export path and
            // RAISES an NSException (not a Swift error) for a composition it rejects — which the
            // `do/catch` above can't catch, so it would abort the whole app on opening the studio.
            // Guard it via the ObjC bridge: on rejection, keep the studio open with an unstyled
            // preview (export, which tolerates the same composition, still works) and report why.
            var warning: String?
            if let vc, let ex = ObjCException.catching({ item.videoComposition = vc }) {
                let reason = ex.reason ?? ex.name.rawValue
                Self.log.error("AVPlayerItem rejected videoComposition: \(reason, privacy: .public)")
                warning = "Preview unavailable: \(reason)"
                item.videoComposition = nil   // play the raw stitch rather than nothing
            }
            // Read the playhead and the play status NOW, not before the await (prompt 301): an edit
            // (split/trim/filter/…) shouldn't snap the playhead back to the start, and a scrub or a
            // pause made while this rebuild ran must be kept.
            let resumeAt = StudioTransport.resumePosition(positionNow: currentTime, total: totalDuration)
            let resumePlaying = StudioTransport.resumesPlaying(state.player)
            // REUSE the existing AVPlayer (swap only its item) rather than building a new one. A fresh
            // AVPlayer makes the player layer detach/reattach → a black flash on every edit (the PiP
            // "flicker"). `replaceCurrentItem` keeps the same render surface; paired with the asset
            // cache the swap is quick and seamless.
            detachTransport()
            if let player = previewPlayer {
                player.replaceCurrentItem(with: item)
                attachTransport(to: player)
            } else {
                let player = AVPlayer(playerItem: item)
                previewPlayer = player
                attachTransport(to: player)
            }
            playerGaps = gaps
            send(.previewBuilt(warning: warning))
            seek(to: resumeAt)
            // keep playing across a live edit instead of pausing; either way end on the real status.
            if resumePlaying, state.canPlay { play() } else { pause() }
        } catch {
            guard generation == rebuildGeneration else { return }
            // device-only: no resolvable assets on the simulator. Nothing of the old player is left
            // behind: its observers, its playing status and a playhead past the end all go.
            teardownPlayer()
            send(.previewUnavailable(message: nil))
        }
    }

    // MARK: Edits (all via the pure StudioProjectEditor → undo → persist → rebuild)

    private func edit(_ transform: (StudioProjectSnapshot) -> StudioProjectSnapshot) {
        guard canEdit else { return }     // locked while a bake (294) or an export (301) renders
        endGesture()                      // a separate edit is its own undo step (prompt 299)
        undo.commit(transform(undo.current))
        persist()
        scheduleRebuild()
    }
    /// An edit that only touches **overlays** — they're not in the playback composition (overlays are
    /// the WYSIWYG SwiftUI layer on top of the preview), so skip the player rebuild to avoid a flicker
    /// / playback restart on every drag. Still commits to undo + persists.
    ///
    /// `live` marks a value that arrives many times during one continuous gesture (a slider tick).
    /// While a gesture is open (`beginGesture`) a live edit only replaces the current snapshot — the
    /// canvas follows the finger, but there is no undo step and no save until `endGesture`
    /// (prompt 299). With no gesture open, or for any other edit, it is a plain commit as before.
    private func editOverlaysOnly(live: Bool = false,
                                  _ transform: (StudioProjectSnapshot) -> StudioProjectSnapshot) {
        guard canEdit else { return }
        if live, undo.isInTransaction {
            undo.replaceCurrent(transform(undo.current))
            return
        }
        endGesture()
        undo.commit(transform(undo.current))
        persist()
    }

    /// A slider drag begins (`Slider(onEditingChanged:)` → true). Until `endGesture`, the slider's
    /// values update the snapshot live without growing undo or saving. Refused while a render runs.
    func beginGesture() {
        guard canEdit else { return }
        undo.beginTransaction()
    }
    /// The drag ended: exactly one undo step holding the value from before the drag, and one save —
    /// or neither, if the value ended where it started. Safe to call with no gesture open.
    ///
    /// Not guarded by `isBaking` on purpose: a gesture left open would swallow later edits, and
    /// closing it changes nothing a bake depends on — live edits are refused while it renders, so
    /// this saves exactly the snapshot the bake read when it started.
    ///
    /// A drag that changed a picture-in-picture rebuilds the preview here, once (prompt 300): the
    /// picture-in-picture is drawn by the compositor, not by the canvas.
    func endGesture() {
        guard undo.isInTransaction else { return }
        let rebuild = gestureChangedComposition
        gestureChangedComposition = false
        if undo.endTransactionIfChanged() {
            persist()
            if rebuild { scheduleRebuild() }
        }
    }
    /// Set by a live tick that changed something the compositor draws (prompt 300).
    private var gestureChangedComposition = false
    func undoEdit() {
        guard canEdit else { return }
        endGesture()                      // the open drag becomes a step first, then Undo removes it
        undo.undo(); persist(); scheduleRebuild()
    }
    func redoEdit() {
        guard canEdit else { return }
        endGesture()
        undo.redo(); persist(); scheduleRebuild()
    }
    /// The ONE place a snapshot is written to the project and the store (prompt 302). A failed
    /// save is reported through the state (a message the user can close); the edit stays in
    /// memory and in undo, and the next save that works clears the message.
    @discardableResult
    private func persist() -> Bool {
        undo.current.apply(to: project)
        send(.mediaSourcesChanged(mediaSources))   // the timeline may have gained or lost a clip
        return saveStore()
    }

    /// Save the store and report the result. Returns whether it was saved.
    @discardableResult
    private func saveStore() -> Bool {
        do {
            try saver(context)
            send(.saveSucceeded)
            return true
        } catch {
            Self.log.error("studio save failed: \(error.localizedDescription, privacy: .public)")
            send(.saveFailed)
            return false
        }
    }

    func select(_ id: UUID?) {
        // Tapping a CLIP shows the CLIP editor (trim/speed/filter/split). It must NOT also select the
        // clip's climb tag — that popped the OVERLAY editor and hid the clip's options (prompt 14). The
        // climb tag is selected only by tapping the tag itself (its overlay-lane bar / the canvas chip →
        // `selectOverlay`). Each tag is a per-clip property (clipID), so its Attempt# is intrinsic to its
        // own clip (see `effectiveAttemptNumber`) — the old "follow the selected clip" coupling is gone.
        // The selection is ONE value (prompt 301), so selecting a clip is also deselecting the overlay.
        send(.select(id.map(StudioSelection.clip) ?? .none))
    }

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
        let source = timelineDurations[clip.id]
        edit { StudioProjectEditor.splitClip($0, id: clip.id, atOutputOffset: mid,
                                             sourceDuration: source) }
    }
    /// Split at the **playhead**: find the clip under `currentTime` and cut it there (the edits-style
    /// split). Falls back to splitting the selected clip at its midpoint if the playhead isn't over a
    /// video clip (e.g. before playback has moved it).
    func splitAtPlayhead() {
        let durations = timelineDurations
        let placed = StudioGeometry.timeline(clips: visibleSnapshotClips, sourceDurations: durations,
                                             transitions: snapshot.transitions)
        guard let p = placed.first(where: { currentTime >= $0.startSec && currentTime < $0.endSec }),
              !p.clip.isPhoto else { splitSelected(); return }
        selectedClipID = p.clip.id
        edit { StudioProjectEditor.splitClip($0, id: p.clip.id, atOutputOffset: currentTime - p.startSec,
                                             sourceDuration: durations[p.clip.id]) }
    }
    func setSelectedSpeed(_ speed: Double) {
        guard let id = selectedClipID else { return }
        edit { StudioProjectEditor.setClipSpeed($0, id: id, speed: speed) }
    }
    /// Commit a trim on the selected clip (seconds within the source). Clamped so the trimmed span
    /// keeps a minimum length. The timeline view drives this **once on drag-end** (the live handle
    /// feedback is view-local), so there's one undo entry + one preview rebuild per trim.
    func trimSelected(startSeconds: Double?, endSeconds: Double?) {
        // Refused while the source length is not known (prompt 303): a never-trimmed clip whose
        // video is not on this phone and has no recorded length. Clamping to "0 s" stored
        // `trimEnd = 0`, and that stayed after the video was downloaded.
        guard let clip = selectedClip, !clip.isPhoto, let src = trimSourceLength(of: clip) else { return }
        let minLen = 0.1
        var start = startSeconds ?? clip.trimStart
        var end = endSeconds ?? clip.trimEnd ?? src
        start = max(0, min(start, end - minLen))
        end = min(src, max(end, start + minLen))
        // A trim of the start alone leaves the stored end as it was (none stays none): `src` may
        // be an estimate, the recorded length of a video that is not on this phone, and a stored
        // estimate would stay after the real length is read (prompt 303).
        let storedEnd = endSeconds == nil ? clip.trimEnd : end
        edit { StudioProjectEditor.trimClip($0, id: clip.id, start: start, end: storedEnd) }
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

    // MARK: - Rich text styling (colour / highlight / font / bold-italic — all overlay-only, no rebuild)

    func setOverlayColor(_ id: UUID, _ hex: String) {
        editOverlaysOnly { StudioProjectEditor.setOverlayColor($0, id: id, hex: hex) }
    }
    /// Set (hex) or clear (`nil`) the highlight/background behind a text/climb-name overlay.
    func setOverlayHighlight(_ id: UUID, _ hex: String?) {
        editOverlaysOnly { StudioProjectEditor.setOverlayHighlight($0, id: id, hex: hex) }
    }
    func setOverlayFont(_ id: UUID, _ font: StudioFont) {
        editOverlaysOnly { StudioProjectEditor.setOverlayFont($0, id: id, font: font) }
    }
    func setOverlayBold(_ id: UUID, _ on: Bool) {
        editOverlaysOnly { StudioProjectEditor.setOverlayStyle($0, id: id, bold: on) }
    }
    func setOverlayItalic(_ id: UUID, _ on: Bool) {
        editOverlaysOnly { StudioProjectEditor.setOverlayStyle($0, id: id, italic: on) }
    }

    // MARK: - Climb-name overlay (a PER-CLIP property — prompt 12: scoped · idempotent · correct attempt#)

    /// True when a climb resolves for the selected (or any) clip — gates the "Climb" action button.
    /// A Kilter climb resolves via `resolvedClimbUUID`; a FREEFORM climb (prompt 09) has no
    /// `KilterLogEntry`, so the threaded `suggestedClimbCaption` widens the gate for it.
    var hasClimbInfo: Bool { resolvedClimbUUID != nil || suggestedClimbCaption != nil }

    /// The existing `.climbName` overlay owned by the selected clip (its `clipID`), or — when no clip is
    /// selected — any whole-project climb tag (`clipID == nil`). Drives the idempotent add-or-select and
    /// the "Climb ✓" button state, so one tag per clip and tapping "Climb" never duplicates.
    var climbOverlayForSelectedClip: OverlayItem? {
        let target = selectedClip?.id
        return overlays.first { $0.kind == .climbName && $0.clipID == target }
    }
    /// True when the selected clip already has a climb tag — the "Climb ✓" selected state (like Music/HR).
    var hasClimbOverlay: Bool { climbOverlayForSelectedClip != nil }

    /// Add a climb-name overlay (a styled lower-third) for the selected clip, OR select the clip's
    /// existing tag (idempotent — never duplicates, prompt 12 BUG #2). The tag is a per-clip property:
    /// its `clipID` is the selected clip and its initial window is that clip's placed slot, so it shows
    /// ONLY during that clip's segment (BUG #1); the window is re-resolved at render time. A Kilter clip
    /// derives the caption from its `KilterLogEntry`; a FREEFORM clip falls back to the threaded
    /// `suggestedClimbCaption` (prompt 09). No-op when the resolved base caption is empty.
    func addClimbNameOverlay() {
        // Idempotent: if this clip already has a tag, just SELECT it — never duplicate, and never re-seed
        // its caption (that would wipe a manual edit; the lower-risk choice, prompt 12 BUG #2).
        if let existing = climbOverlayForSelectedClip {
            selectedOverlayID = existing.id
            return
        }
        let caption: String
        if let uuid = resolvedClimbUUID {
            caption = climbCaption(uuid: uuid, includeSetter: false)
        } else if let suggested = suggestedClimbCaption {
            caption = suggested
        } else {
            return
        }
        guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Anchor the tag to the selected clip's placed slot (whole-project fallback when none selected).
        let clipID = selectedClip?.id
        let slot = clipID.flatMap { id in placedClips.first { $0.clip.id == id } }
        let overlay = OverlayItem(kind: .climbName, content: caption,
                                  startSec: slot?.startSec ?? 0,
                                  endSec: slot?.endSec ?? max(3, totalDuration),
                                  position: CGPoint(x: 0.5, y: 0.85),
                                  clipID: clipID,
                                  attemptNumber: effectiveAttemptNumber)
        editOverlaysOnly { StudioProjectEditor.addOverlay($0, overlay) }
        selectedOverlayID = overlay.id
    }

    /// True when the selected climb-name overlay shows the setter (read from the model, not transient
    /// state — survives reopen/undo, prompt 12 STEP 6).
    var selectedClimbShowsSetter: Bool { selectedOverlay?.showsSetter ?? false }

    /// Whether the "Show setter" toggle should appear: a `.climbName` overlay AND a Kilter climb resolves
    /// for it (`resolvedClimbUUID != nil`) — HIDDEN for freeform climbs, where it would be a dead no-op
    /// (prompt 12 STEP 7b).
    var canShowClimbSetter: Bool {
        guard let ov = selectedOverlay, ov.kind == .climbName else { return false }
        return resolvedClimbUUID != nil
    }

    /// Toggle the setter on the selected climb-name overlay by flipping its persisted `showsSetter` flag.
    /// The rendered ` · by {setter}` is COMPOSED at render time (canvas + export) from the base caption,
    /// so a manual caption edit is never wiped (prompt 12 STEP 6).
    func setSelectedClimbShowsSetter(_ on: Bool) {
        guard let ov = selectedOverlay, ov.kind == .climbName else { return }
        editOverlaysOnly { StudioProjectEditor.setOverlayClimbFlags($0, id: ov.id, showsSetter: on) }
    }

    /// The 1-based attempt number a timeline clip belongs to — its backing `SessionMedia.assignedSetIndex
    /// + 1`. `nil` when the clip has no media link or isn't tied to a specific attempt. (prompt 11/14)
    private func attemptNumber(forClipID clipID: UUID?) -> Int? {
        guard let clipID,
              let mediaID = snapshot.clips.first(where: { $0.id == clipID })?.sessionMediaID else { return nil }
        var d = FetchDescriptor<SessionMedia>(predicate: #Predicate { $0.id == mediaID })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.assignedSetIndex.map { $0 + 1 }
    }

    /// The attempt number the "Attempt #" tag uses/shows. A climb tag is a PER-CLIP property, so its
    /// attempt is its OWN clip's (`overlay.clipID`) — NOT "whichever clip is selected" (that coupling made
    /// tapping a clip pop the overlay editor, prompt 14). When ADDING a tag (none selected yet) it's the
    /// clip being tagged; the threaded `suggestedAttemptNumber` is the final fallback (single-clip open).
    var effectiveAttemptNumber: Int? {
        return attemptNumber(forClipID: contextClip?.id) ?? suggestedAttemptNumber
    }

    /// Whether the "Attempt #" option is available for the selected overlay: a `.climbName` overlay exists
    /// AND an attempt number resolves for the current selection (prompt 11 — the SELECTED clip's, else the
    /// threaded fallback). Gates showing the toggle in the editor.
    var canShowClimbAttempt: Bool {
        guard effectiveAttemptNumber != nil, let ov = selectedOverlay else { return false }
        return ov.kind == .climbName
    }

    /// True when the selected climb-name overlay shows the "Attempt N" line (read from the model — survives
    /// reopen/undo, prompt 12 STEP 6).
    var selectedClimbShowsAttempt: Bool { selectedOverlay?.showsAttempt ?? false }

    /// Toggle the "Attempt N" line on the selected climb-name overlay by flipping its persisted
    /// `showsAttempt` flag (and stamping the current `effectiveAttemptNumber`). The line is COMPOSED at
    /// render time, so the base caption (incl. any manual edit) is preserved and there's no regex strip
    /// (prompt 12 STEP 6).
    func setSelectedClimbShowsAttempt(_ on: Bool) {
        guard let ov = selectedOverlay, ov.kind == .climbName,
              let attempt = effectiveAttemptNumber else { return }
        editOverlaysOnly {
            StudioProjectEditor.setOverlayClimbFlags($0, id: ov.id, showsAttempt: on,
                                                     attemptNumber: on ? attempt : nil)
        }
    }

    /// The clip the selection is about: the selected clip, or the clip a selected overlay belongs
    /// to (a per-clip climb tag's `clipID`). The selection is one value (prompt 301), so while a
    /// tag is selected no clip is; its own clip is the right one for its setter and attempt number.
    private var contextClip: TimelineClip? {
        if let clip = selectedClip { return clip }
        guard let clipID = selectedOverlay?.clipID else { return nil }
        return snapshot.clips.first { $0.id == clipID }
    }

    /// The climb uuid backing the caption: the selection's clip's assignment, else the first assigned clip.
    private var resolvedClimbUUID: String? {
        if let u = assignedClimbUUID(for: contextClip) { return u }
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

    /// Select an overlay (this deselects a clip — the selection is one value). `nil` deselects the
    /// overlay; a selected clip is left alone.
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
        // The Size slider is shown for non-video overlays only, so its ticks take the live path.
        isVideo ? edit(t) : editOverlaysOnly(live: true, t)
    }

    // MARK: - Overlay timeline (how long an overlay stays on screen — the timeline lane)

    /// Overlays shown as bars in the timeline lane (every overlay carries a `[startSec, endSec]`). Scoped
    /// to the visible clips (prompt 13) so a single-clip editor doesn't show another clip's tag as a bar.
    var timelineOverlays: [OverlayItem] { scopedOverlays }

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

    /// The main video's collage frame AS DRAWN, or `nil` when it fills the whole canvas (legacy).
    /// Also `nil` over a clip that was baked with it (prompt 295): the frame is in its pixels. `baseFramed` reads
    /// the stored value.
    var baseFrame: StudioFrameRect? { standDownSnapshot.baseFrame }
    /// The base (main) video's oriented source aspect — locks the base frame's resize to its footage.
    var baseSourceAspect: CGFloat? { clips.first.flatMap { sourceAspects[$0.localIdentifier] } }
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
        if hrOverlay == nil {
            // Enabling the overlay spawns the unified stat tile (the redesign, issue #163), defaulting to
            // the premium **Glass Hero Card with the sparkline ON** — the most legible + general-purpose
            // design, safest over any footage.
            var cfg = HROverlayConfig.default
            cfg.tile = HRTile.make(template: .hero)
            editOverlaysOnly { var s = $0; s.hrOverlay = cfg; return s }
        } else {
            editOverlaysOnly { var s = $0; s.hrOverlay = nil; return s }
        }
    }
    func updateHROverlay(_ config: HROverlayConfig) {
        editOverlaysOnly { var s = $0; s.hrOverlay = config; return s }
    }

    // MARK: - Unified HR stat tile (the overlay redesign)

    /// The current tile, or `nil` when the overlay is off / a (pre-migration) legacy element overlay.
    var hrTile: HRTile? { snapshot.hrOverlay?.tile }
    /// The tile the CANVAS draws: `hrTile`, or `nil` while the clip under the playhead was baked
    /// with a tile (prompt 295) — it is in the pixels. The builder sheet keeps reading `hrTile`.
    var canvasHRTile: HRTile? {
        ClipBakePlan.hidesHRTile(over: placedClipUnderPlayhead()?.clip) ? nil : hrTile
    }
    /// The per-metric toggle rows for the builder UI (ordered).
    var tileEntries: [HRTileMetricEntry] { hrTile?.entries ?? [] }

    /// How many toggled-on metrics (with data) the tile can't show at its current proportions — the
    /// layout's `hiddenCount`, computed on a nominal canvas scaled by the tile size (scale-invariant).
    /// Drives the builder's `+N · enlarge` hint so "toggle everything on" never silently crops.
    var tileHiddenCount: Int {
        guard let tile = hrTile else { return 0 }
        let enabled = tile.enabledMetrics.filter { metric in
            guard let e = tile.entry(for: metric) else { return false }
            var el = HROverlayElement(metric: metric, colorHex: e.colorHex)
            el.live = e.live; el.animated = e.animated
            return overlayValues.reading(for: el, atFraction: 1) != nil
        }
        let rect = CGRect(x: 0, y: 0, width: max(1, 1000 * tile.width), height: max(1, 1000 * tile.height))
        return HRTileLayout.layout(template: tile.template, enabledMetrics: enabled,
                                   tileRect: rect, hasChart: tile.showChart).hiddenCount
    }

    /// Mutate the tile in place and commit (one overlay-only edit → undo + persist, no preview rebuild).
    private func mutateTile(_ body: (inout HRTile) -> Void) {
        guard var cfg = snapshot.hrOverlay, var tile = cfg.tile else { return }
        body(&tile)
        cfg.tile = tile
        updateHROverlay(cfg)
    }

    /// Pick a tile design from the catalog, preserving the user's per-metric toggles/colours.
    func selectTileTemplate(_ template: HRTileTemplate) {
        mutateTile { tile in
            let switched = tile.switchingTemplate(to: template)
            tile = switched
            // Adopt the new template's default frame + chart only when first switching templates so the
            // tile sits where that design expects (the user can still drag/resize afterward).
            tile.center = template.defaultCenter
            tile.size = template.defaultSize
            tile.showChart = template.spawnShowChart
        }
    }
    /// Toggle a metric on/off (the ON/OFF control — all metrics start on).
    func toggleTileMetric(_ id: UUID) {
        mutateTile { tile in
            if let i = tile.entries.firstIndex(where: { $0.id == id }) { tile.entries[i].on.toggle() }
        }
    }
    func setTileMetricLive(_ id: UUID, _ live: Bool) {
        mutateTile { tile in
            if let i = tile.entries.firstIndex(where: { $0.id == id }) { tile.entries[i].live = live }
        }
    }
    func setTileMetricAnimated(_ id: UUID, _ animated: Bool) {
        mutateTile { tile in
            if let i = tile.entries.firstIndex(where: { $0.id == id }) { tile.entries[i].animated = animated }
        }
    }
    /// Set the whole-tile opacity (transparency control), clamped to the legible floor.
    /// Called per slider tick, so it takes the live path (one undo step per drag, prompt 299).
    func setTileOpacity(_ value: Double) {
        guard var cfg = snapshot.hrOverlay, var tile = cfg.tile else { return }
        tile.opacity = min(1, max(HRTile.minOpacity, value))
        cfg.tile = tile
        editOverlaysOnly(live: true) { var s = $0; s.hrOverlay = cfg; return s }
    }

    /// Show/hide the moving chart line as a tile register. Enabling it **nudges the tile height up** to
    /// the template's `minHeightWithChart` so the curve always has a readable register (the user sees the
    /// tile grow; preview == export). The pure layout carves the chart as a fraction, so this normalized
    /// floor — not an absolute point height — is what guarantees the curve is never cropped.
    func setTileShowChart(_ on: Bool) {
        mutateTile { tile in
            tile.showChart = on
            if on { tile.height = min(1, max(tile.height, tile.template.minHeightWithChart)) }
        }
    }
    /// Commit the tile's dragged/resized frame (normalized centre + size).
    func setTileFrame(center: CGPoint, size: CGSize) {
        mutateTile { $0.center = center; $0.size = size }
    }

    // MARK: - Extended HR window (prompt 115)

    /// The HR-window editor context for the targeted clip — computed ONCE per render and passed into
    /// `HRWindowControls` (it rebuilds the placed timeline, so callers must not poll it per field).
    /// `clipID` pins every slider write to THIS clip: the target is resolved when the view renders,
    /// not per slider tick, so a moving playhead can't retarget a drag mid-gesture. The lead/tail here
    /// are the EFFECTIVE values the chart actually draws (lead clamps at session start, tail at the
    /// recorded-HR edge); the stored/requested values ride alongside for the sliders + clamp hints.
    struct HRWindowEditorInfo: Equatable {
        var clipID: UUID
        /// Requested (stored-or-default) values — what the sliders show and write.
        var lead: Double
        var tail: Double
        /// Effective values — what the mini-map and the chart's panes actually cover.
        var effectiveLead: Double
        var effectiveTail: Double
        var footageSec: Double
        var scope: HRMetricsScope
        /// True when the clip stores any non-default value (shows the Reset row).
        var isCustomized: Bool
    }

    /// The context for the clip the HR-window section targets: the video clip under the playhead —
    /// the SAME clip the preview tile shows (shared `placedClipUnderPlayhead`), so what the sliders
    /// change is what the user is looking at. `nil` when there's no targetable video clip with a
    /// resolvable capture offset.
    var hrWindowInfo: HRWindowEditorInfo? {
        guard let clip = placedClipUnderPlayhead()?.clip, let clock = captureClock(of: clip) else { return nil }
        let ext = StudioHRPlacement.extendedWindow(offset: clock.offsetSec, trimStart: clip.trimStart,
                                                   trimEnd: clip.trimEnd,
                                                   sourceDuration: timelineDurations[clip.id],
                                                   leadSec: clip.hrWindowLeadSec,
                                                   tailSec: clip.hrWindowTailSec,
                                                   timeMap: clock.timeMap)
        let coverageEnd = hrSeries.last?.t ?? 0
        let footageEnd = ext.start + ext.window.leadSec + ext.window.footageSec
        return HRWindowEditorInfo(
            clipID: clip.id,
            lead: clip.hrWindowLeadSec, tail: clip.hrWindowTailSec,
            effectiveLead: ext.window.leadSec,
            effectiveTail: min(clip.hrWindowTailSec, max(0, coverageEnd - footageEnd)),
            footageSec: ext.window.footageSec, scope: clip.hrMetricsScope,
            isCustomized: clip.hrLeadSec != nil || clip.hrTailSec != nil || clip.hrMetricsScopeRaw != nil)
    }

    /// Set one HR-window field on the clip `id` (resolved by the view at render time — NOT re-resolved
    /// here, so a moving playhead can't retarget a slider drag), preserving the others' stored state
    /// (a stored `nil` stays `nil` = "track the default"). Overlay-only edit: the HR burn isn't in the
    /// playback composition, so no preview rebuild.
    func setHRWindowLead(_ seconds: Double, clipID: UUID) {
        mutateHRWindow(clipID: clipID) { (min(HRClipWindow.maxLeadSec, max(0, seconds)), $0.hrTailSec, $0.hrMetricsScopeRaw) }
    }
    func setHRWindowTail(_ seconds: Double, clipID: UUID) {
        mutateHRWindow(clipID: clipID) { ($0.hrLeadSec, min(HRClipWindow.maxTailSec, max(0, seconds)), $0.hrMetricsScopeRaw) }
    }
    func setHRWindowScope(_ scope: HRMetricsScope, clipID: UUID) {
        mutateHRWindow(clipID: clipID) { ($0.hrLeadSec, $0.hrTailSec, scope.rawValue) }
    }
    /// Reset the clip to the defaults (clears the stored values, so future default changes flow through).
    func resetHRWindow(clipID: UUID) {
        mutateHRWindow(clipID: clipID) { _ in (nil, nil, nil) }
    }
    private func mutateHRWindow(clipID: UUID,
                                _ next: (TimelineClip) -> (lead: Double?, tail: Double?, scopeRaw: String?)) {
        guard let clip = snapshot.clips.first(where: { $0.id == clipID }) else { return }
        let v = next(clip)
        editOverlaysOnly {
            StudioProjectEditor.setClipHRWindow($0, id: clipID, leadSec: v.lead, tailSec: v.tail,
                                                scope: v.scopeRaw.flatMap(HRMetricsScope.init(rawValue:)))
        }
    }

    /// Lazily upgrade a legacy free-floating-elements overlay into the unified tile (zero data loss).
    /// Idempotent (guards `tile == nil`); called on appear once the overlay context is loaded.
    func migrateHRTileIfNeeded() {
        guard var cfg = snapshot.hrOverlay, cfg.tile == nil,
              let tile = HRTileMigration.tile(from: cfg) else { return }
        cfg.tile = tile
        editOverlaysOnly { var s = $0; s.hrOverlay = cfg; return s }
    }

    // MARK: Configurable HR/fitness overlay builder (prompt 28 — Studio parity)

    /// Profile/session bounds for the overlays, set by the view from the session + `UserHRProfile`.
    /// The Studio's overlay spans the **whole session** HR, so these are session-wide values.
    private(set) var hrMaxHR: Double?
    private(set) var hrRestHR: Double?
    private(set) var hrKcal: Double?
    private(set) var hrHRV: HRVMetrics = .empty
    func setOverlayContext(maxHR: Double?, restHR: Double?, kcal: Double?, hrv: HRVMetrics) {
        hrMaxHR = maxHR; hrRestHR = restHR; hrKcal = kcal; hrHRV = hrv
    }

    /// Load the overlay context for the session (workout **or** Kilter) — the bounds for zones/%HRR/
    /// recovery plus the session-wide calorie + HRV figures (from the `UserHRProfile`, passed by the
    /// view since the VM has no `AppModel`). Call after `onAppear` (HR series loaded).
    func loadOverlayContext(profile: UserHRProfile) {
        hrProfile = profile
        let sid = project.sessionID
        var maxHR: Double?, restHR: Double?
        if let w = (try? context.fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.id == sid })))?.first {
            maxHR = w.maxHR; restHR = w.restHR
        } else if let k = (try? context.fetch(FetchDescriptor<KilterSession>(
            predicate: #Predicate { $0.id == sid })))?.first {
            maxHR = k.maxHR; restHR = k.restHR
        }
        let dur = hrSeries.last?.t ?? 0
        let kcal = profile.estimatedKcal(forSeries: hrSeries, durationSec: dur)
        let hrv = HRVMetrics.make(
            from: hrSeries.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) },
            start: 0, end: dur)
        setOverlayContext(maxHR: maxHR, restHR: restHR, kcal: kcal, hrv: hrv)
        migrateHRTileIfNeeded()   // upgrade any legacy free-floating-elements overlay to the unified tile
    }

    /// The pure resolver over the session HR — feeds the preview badges + the export burn-in.
    var overlayValues: HROverlayValues {
        HROverlayValues(samples: hrSeries, durationSec: hrSeries.last?.t ?? 0,
                        maxHR: hrMaxHR, restHR: hrRestHR, kcal: hrKcal, hrv: hrHRV)
    }
    /// The session-wide resolved HR stat **tile** (the overlay redesign), or `nil` when no tile is set.
    /// The composer uses it as the fallback for clips with no media link; per-clip tiles (each clip's own
    /// capture window) come from `clipHRContent()`.
    ///
    /// `nil` when any visible clip was baked with a tile (prompt 295): this tile is one layer over
    /// the whole output and would draw over that clip's own tile.
    private func resolvedSessionTile() -> ResolvedHRTile? {
        guard ClipBakePlan.allowsSessionWideTile(visible: visibleSnapshotClips),
              let tile = snapshot.hrOverlay?.tile else { return nil }
        return overlayValues.resolveTile(tile)
    }

    // MARK: - Per-clip HR (the fix: each clip shows its OWN capture-window HR, not the whole session)

    /// Per-clip HR content for **export**, keyed by clip id: the session series sliced to each visible
    /// video clip's capture window (`StudioHRPlacement` + `HRWindowSlicer`) plus that clip's resolved
    /// HR stat tile. Empty (→ composer falls back to the session-wide tile) when there's no HR, no media
    /// offsets, or no tile. The composer places each entry at the clip's output slot.
    /// Internal (not private) so a test can hand it to `StudioComposer.placedHR`, as the export does.
    func clipHRContent() -> [UUID: StudioClipHRContent] {
        guard !hrSeries.isEmpty else { return [:] }
        // A clip baked with a tile gets no entry (prompt 295): the tile is in its pixels.
        let videoClips = visibleSnapshotClips.filter { !$0.isPhoto && !ClipBakePlan.hidesHRTile(over: $0) }
        let clocks = Dictionary(uniqueKeysWithValues: videoClips.compactMap { c in
            captureClock(of: c).map { (c.id, $0) }
        })
        let offsets = clocks.mapValues(\.offsetSec)
        guard !offsets.isEmpty else { return [:] }
        // Each clip's EXTENDED window (prompt 115): footage widened by its lead-in/tail, so the burned
        // chart shows the effort's after-story while the dot sweeps only the on-camera span.
        // A baked asset's time map (prompt 305) goes with its offset: both from one clock.
        let sampled = StudioHRPlacement.sampleExtended(clips: videoClips, offsets: offsets,
                                                       sourceDurations: sourceDurations, series: hrSeries,
                                                       timeMaps: clocks.compactMapValues(\.timeMap))
        guard !sampled.isEmpty else { return [:] }
        // One composite tile per clip, resolved over the clip's own capture window. No tile → no per-clip
        // HR content (legacy free-floating badges were removed once everything migrates to a tile).
        guard let tile = snapshot.hrOverlay?.tile else { return [:] }
        var out: [UUID: StudioClipHRContent] = [:]
        for (id, s) in sampled {
            let scope = videoClips.first { $0.id == id }?.hrMetricsScope ?? .default
            out[id] = StudioClipHRContent(
                samples: s.samples,
                tile: scopedOverlayValues(samples: s.samples, window: s.window, scope: scope).resolveTile(tile))
        }
        return out
    }

    /// Build the overlay VALUES for one clip's (possibly extended) window — per-clip avg/max/zone/
    /// calories/HRV, not the session-wide values; bounds (max/rest HR) stay session-wide. Under a
    /// `.clip` metrics scope the aggregates re-slice to the footage sub-window (`[lead, lead+footage]`
    /// of the already window-local samples) while the chart keeps the full window. ONE builder for the
    /// preview badges AND the export burn-in, so the two can't diverge (WYSIWYG).
    private func scopedOverlayValues(samples: [HRPoint], window: HRClipWindow?,
                                     scope: HRMetricsScope) -> HROverlayValues {
        let span = samples.last?.t ?? 0
        let clipScoped = scope == .clip && (window?.isExtended ?? false)
        let scoped: [HRPoint]
        let scopedSpan: Double
        if clipScoped, let w = window {
            scoped = HRWindowSlicer.slice(samples, start: w.leadSec, span: w.footageSec)
            scopedSpan = scoped.last?.t ?? w.footageSec
        } else {
            scoped = samples
            scopedSpan = span
        }
        let kcal = hrProfile?.estimatedKcal(forSeries: scoped, durationSec: scopedSpan)
        let hrv = HRVMetrics.make(
            from: scoped.map { HRSample(t: $0.t, bpm: $0.bpm, rrIntervalsMs: $0.rrIntervalsMs) },
            start: 0, end: scopedSpan)
        return HROverlayValues(samples: samples, durationSec: span, maxHR: hrMaxHR, restHR: hrRestHR,
                               kcal: kcal, hrv: hrv, window: window,
                               statsSamples: clipScoped ? scoped : nil,
                               statsDurationSec: clipScoped ? scopedSpan : nil)
    }

    /// The preview's per-clip HR context: the clip under the playhead, its (possibly extended) HR
    /// window slice, and its clip-local playhead time — WYSIWYG with the export.
    struct PreviewHR {
        var samples: [HRPoint]
        /// Clip-local output-time playhead (seconds into the clip's slot).
        var currentTime: Double
        /// The clip's output-slot duration.
        var totalDuration: Double
        /// The extended window, `nil` on the whole-session fallback (clip with no resolvable offset).
        var window: HRClipWindow?
        var scope: HRMetricsScope
    }

    /// The video clip that OWNS the playhead's moment (last clip when the playhead is at the very
    /// end) — the ONE "clip under the playhead" rule shared by the preview tile (`previewHR`) and
    /// the HR-window controls (`hrWindowInfo`), so the sliders can't target a different clip than
    /// the tile renders. During a transition the outgoing clip owns the first half and the
    /// incoming clip the second (`StudioGeometry.ownedWindows`, prompt 303) — the same rule the
    /// export gates each clip's tile with, so the preview's tile changes where the file's does.
    private func placedClipUnderPlayhead() -> StudioGeometry.PlacedClip? {
        let placed = StudioGeometry.timeline(clips: visibleSnapshotClips.filter { !$0.isPhoto },
                                             sourceDurations: timelineDurations,
                                             transitions: snapshot.transitions)
        return StudioGeometry.ownerIndex(at: currentTime, in: placed).map { placed[$0] } ?? placed.last
    }

    /// Per-clip HR for the **preview** chart (WYSIWYG with export): the clip under the playhead sliced
    /// to its own extended window, with the clip-local playhead time + duration so the dot tracks
    /// within the footage span. Falls back to the whole-session series for a clip with no media link.
    var previewHR: PreviewHR {
        guard let p = placedClipUnderPlayhead(), let clock = captureClock(of: p.clip) else {
            return PreviewHR(samples: hrSeries, currentTime: currentTime,
                             totalDuration: max(0.01, totalDuration), window: nil, scope: .default)
        }
        let ext = StudioHRPlacement.extendedWindow(offset: clock.offsetSec, trimStart: p.clip.trimStart,
                                                   trimEnd: p.clip.trimEnd,
                                                   sourceDuration: timelineDurations[p.clip.id],
                                                   leadSec: p.clip.hrWindowLeadSec,
                                                   tailSec: p.clip.hrWindowTailSec,
                                                   timeMap: clock.timeMap)
        let samples = HRWindowSlicer.slice(hrSeries, start: ext.start, span: ext.window.spanSec)
        return PreviewHR(samples: samples, currentTime: currentTime - p.startSec,
                         totalDuration: max(0.01, p.durationSec), window: ext.window,
                         scope: p.clip.hrMetricsScope)
    }

    /// The preview tile's VALUES + playhead fraction, computed together from ONE `previewHR` pass
    /// (one timeline build, one slice, one `HROverlayValues` init per render — the split accessors
    /// each redid all of it). The fraction routes through `values.chartFraction(forVideoFraction:)`,
    /// the SAME remap the export's segments use, so the maxT rule lives in exactly one place.
    var previewTile: (values: HROverlayValues, fraction: Double) {
        let p = previewHR
        let values = scopedOverlayValues(samples: p.samples, window: p.window, scope: p.scope)
        let videoF = p.totalDuration > 0 ? min(1, max(0, p.currentTime / p.totalDuration)) : 0
        return (values, values.chartFraction(forVideoFraction: videoF))
    }

    // MARK: Picture-in-picture (a second video composited over the main track)

    /// True when the project has at least one picture-in-picture overlay (gates the Grid tool).
    var hasPiP: Bool { overlays.contains { $0.kind == .video } }

    /// Source clips available to drop in as a PiP (the session's main-track video clips).
    var pipSources: [(id: UUID, label: String, localIdentifier: String)] {
        clips.enumerated().compactMap { i, c in
            // A clip that is not on this phone cannot be a picture-in-picture source (prompt 302).
            c.isPhoto || mediaStatus(of: c) != .available ? nil : (c.id, "Clip \(i + 1)", c.localIdentifier)
        }
    }
    /// Add a picture-in-picture overlay from a source clip's `localIdentifier`, defaulting to a small
    /// top-right frame (sized to the source's aspect, so the outline matches the aspect-fit video).
    func addPiP(localIdentifier: String) {
        let size = defaultPiPSize(localIdentifier: localIdentifier)
        let ov = OverlayItem(kind: .video, content: localIdentifier, startSec: 0,
                             endSec: max(3, totalDuration),
                             position: CGPoint(x: 0.72, y: 0.28),
                             normalizedWidth: size.width, normalizedHeight: size.height)
        edit { StudioProjectEditor.addOverlay($0, ov) }
        selectedOverlayID = ov.id
    }

    /// A default PiP frame (fraction of canvas) whose **on-screen** aspect matches the source footage —
    /// so the aspect-fit PiP fills its frame with no letterbox. Falls back to a square when the source
    /// aspect isn't resolved (simulator). `pipSize.w/pipSize.h = sourceAspect / canvasAspect` because the
    /// frame is normalized to the (non-square) canvas.
    private func defaultPiPSize(localIdentifier: String) -> CGSize {
        let canvasAspect = previewRatio
        guard let a = sourceAspects[localIdentifier], a > 0, canvasAspect > 0 else {
            return CGSize(width: 0.4, height: 0.4)
        }
        let ratio = a / canvasAspect       // pipSize.width / pipSize.height
        let base = 0.45
        return ratio >= 1
            ? CGSize(width: base, height: min(1, base / ratio))
            : CGSize(width: min(1, base * ratio), height: base)
    }

    func deleteOverlay(_ id: UUID) {
        let isVideo = overlays.first { $0.id == id }?.kind == .video
        let t: (StudioProjectSnapshot) -> StudioProjectSnapshot = { StudioProjectEditor.removeOverlay($0, id: id) }
        isVideo ? edit(t) : editOverlaysOnly(t)   // a PiP is in the composition → rebuild
        if selectedOverlayID == id { selectedOverlayID = nil }
    }
    /// A text, sticker or tag is drawn by the canvas, so its opacity needs no preview rebuild. A
    /// picture-in-picture is in the composition (prompt 300): during a slider drag the value is
    /// stored live and the preview is rebuilt once, in `endGesture`; outside a drag it is a plain
    /// edit, which rebuilds.
    func setOverlayOpacity(_ id: UUID, _ opacity: Double) {
        let change: (StudioProjectSnapshot) -> StudioProjectSnapshot = {
            StudioProjectEditor.setOverlayOpacity($0, id: id, opacity: opacity)
        }
        guard snapshot.overlays.first(where: { $0.id == id })?.kind == .video else {
            editOverlaysOnly(live: true, change)
            return
        }
        guard undo.isInTransaction else { edit(change); return }
        if !isBaking { gestureChangedComposition = true }
        editOverlaysOnly(live: true, change)
    }
    /// Capture the selected overlay's current opacity as a keyframe at the playhead (the marker
    /// button). Two keyframes of differing opacity → the overlay fades over output time.
    func addOverlayKeyframeAtPlayhead() {
        guard let ov = selectedOverlay else { return }
        let t: (StudioProjectSnapshot) -> StudioProjectSnapshot = {
            StudioProjectEditor.addOverlayOpacityKeyframe($0, id: ov.id, timeSec: self.currentTime, value: ov.opacity)
        }
        // A picture-in-picture is drawn by the compositor, which now renders its opacity keyframes
        // (prompt 300), so its preview must be rebuilt; other overlays are drawn by the canvas.
        ov.kind == .video ? edit(t) : editOverlaysOnly(t)
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

    // MARK: Bake to original (prompt 117 — device-only render + Photos write)

    /// The bake lane's state machine (separate from `exportState`: a bake has no share sheet). The
    /// type is the pure `StudioBakeState`; the value lives in `state`.
    typealias BakeState = StudioBakeState
    /// The view model moves it through `send(_:)`. The setter writes it directly: it is the seam the
    /// lock tests use to stand in for a bake in flight (a real bake needs a device).
    var bakeState: BakeState {
        get { state.bake }
        set {
            var next = state
            next.bake = newValue
            state = next
        }
    }
    /// The result alert closed.
    func acknowledgeBake() { send(.bakeAcknowledged) }

    /// Bake is offered only when the composition renders into ONE source asset that this session
    /// actually tracks (a `SessionMedia` row exists to stamp/re-point). `ClipBakePlan` owns the rule
    /// (video-only visible timeline; the scope must cover every part of that asset).
    var canBakeToOriginal: Bool {
        guard let target = ClipBakePlan.bakeTarget(visible: visibleSnapshotClips, all: snapshot.clips)
        else { return false }
        // Not offered while a clip is not on this phone (prompt 302): the render would leave it out.
        return mediaClocksByLocalID[target] != nil && state.media.allAvailable
    }

    /// A render is already in flight (either lane) — the Export menu disables so two full
    /// AVFoundation exports can't run concurrently.
    /// (A cancelled export is idle at once, but its session may still be stopping — prompt 298;
    /// `state.exportTaskRunning` is true for as long as `exportTask` is alive.)
    var isRendering: Bool { state.isRendering }

    /// The project may be changed: no render is running in either lane (prompt 301). Every edit
    /// path checks it, and the view dims and disables the editor when it is false.
    var canEdit: Bool { state.canEdit }

    /// A bake is in flight. The project is LOCKED for its whole length (prompt 294): every edit path
    /// (`edit`, `editOverlaysOnly`, undo, redo) refuses, and the view disables the editor. A bake
    /// ends by replacing the project with a flattened copy of the snapshot it rendered, so an edit
    /// made in between would either be thrown away or be reset as if it were in the pixels.
    var isBaking: Bool { state.isBaking }

    /// The ONE render both lanes share — `export()` (share as new) and `bake()` (write into the
    /// asset) must produce the identical file for the identical project.
    /// `progress` is used by the export lane only (prompt 298); a bake passes none.
    private func renderComposition(
        progress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let renderOverride { return try await renderOverride() }
        return try await composer.export(scopedSnapshot, sourceDurations: sourceDurations,
                                  hrSamples: hrSeries,
                                  hrTile: resolvedSessionTile(),
                                  clipHRByID: clipHRContent(),
                                  quality: exportQuality,
                                  progress: progress)
    }

    /// Render the composition (same pipeline as `export()`) and write it INTO the Photos asset —
    /// revertible rendition (`replaceOriginal: false`) or save-as-new + delete-original. BOTH paths
    /// then FLATTEN the project for the baked asset (`ClipBakePlan`): the pixels now carry the edit,
    /// so trims/speed/filter/crop/keyframes reset and the burned overlays/HR tile leave the project —
    /// otherwise reopening would re-apply everything on top of the baked rendition. The flatten is an
    /// undo BARRIER (history resets): a post-bake Undo could otherwise rewind the timeline to a
    /// deleted asset / re-arm the double-apply.
    ///
    /// The video's `SessionMedia` rows are read BEFORE anything is rendered or written (prompt
    /// 303). If they cannot be read the bake is refused with a message: it would re-point the
    /// project at the baked video and leave the rows on the old one.
    func bake(replaceOriginal: Bool, service: any ClipBaking = ClipBakeService()) async {
        guard state.canExport,
              ClipBakePlan.bakeTarget(visible: visibleSnapshotClips, all: snapshot.clips) != nil
        else { return }
        // A row's time map is composed into this bake's map, so it is trusted only after Photos
        // was asked NOW (prompt 305): a "Revert to Original" made since the Studio opened would
        // otherwise leave a stale map in the new one. Awaited before the snapshot is read; the
        // guard is checked again after it, so two bakes cannot both get through.
        await reconcileBakedRows()
        guard state.canExport,
              let target = ClipBakePlan.bakeTarget(visible: visibleSnapshotClips, all: snapshot.clips)
        else { return }
        // Read ONCE, before the first await: the snapshot the render is made from is also the one
        // the flatten and the offset shift are computed from (prompt 294). `isBaking` keeps it
        // current; holding it here means the result never depends on that.
        let base = undo.current
        let bakedClips = visibleSnapshotClips
        // How the rendered video's time maps back to the asset's CURRENT video (prompt 305), from
        // the same clips, lengths and transitions the render is made from. Composed with each
        // row's own map below.
        let bakedDurations = sourceDurations
        let bakedTransitions = base.transitions
        // Whether this render draws an HR tile, for the clip's `baked` record (prompt 295). The
        // same two inputs `renderComposition` hands the composer, read before the first await.
        let clipHR = clipHRContent()
        let hrTileDrawn = clipHR.isEmpty ? resolvedSessionTile() != nil
                                         : clipHR.values.contains { $0.tile != nil }
        pause()                 // the preview does not play under a render
        send(.bakeBegan)
        let sid = project.sessionID
        let rows: [SessionMedia]
        do {
            rows = try context.fetch(FetchDescriptor<SessionMedia>(
                predicate: #Predicate { $0.sessionID == sid && $0.localIdentifier == target }))
        } catch {
            Self.log.error("bake: media rows unreadable: \(error.localizedDescription, privacy: .public)")
            rows = []
        }
        guard !rows.isEmpty else {
            send(.bakeFailed(StudioBakeState.recordsUnreadableMessage))
            return
        }
        do {
            let url = try await renderComposition()
            defer { try? FileManager.default.removeItem(at: url) }   // no share sheet needs the temp file
            // The baked video's length: it is the new length of the one clip the bake leaves.
            let renderedDur = (try? await AVURLAsset(url: url).load(.duration))?.seconds
            var changedAssets: Set<String> = [target]
            let flattened: StudioProjectSnapshot
            if replaceOriginal {
                // Re-point ONLY after the service confirms deletion — a cancelled iOS dialog throws
                // `deletionCancelled` and the app's records stay on the (surviving) original.
                let newID = try await service.replaceOriginal(renderedURL: url, oldLocalIdentifier: target)
                changedAssets.insert(newID)
                for m in rows {
                    // The offset moves to the earliest kept footage, and the row always gets a
                    // not-revertible record (`ClipBakePlan.replacedMediaUpdate`).
                    let map = ClipBakePlan.timeMap(parts: bakedClips, sourceDurations: bakedDurations,
                                                   transitions: bakedTransitions,
                                                   existing: m.bakeTimeMap, isRevertible: false)
                    let update = ClipBakePlan.replacedMediaUpdate(oldOffsetSec: m.offsetSec,
                                                                  renderedDurationSec: renderedDur,
                                                                  timeMap: map)
                    m.localIdentifier = newID
                    m.offsetSec = update.offsetSec
                    m.durationSec = update.durationSec
                    m.bakeTimeMap = update.timeMap
                    m.aspectRatio = nil        // the render canvas can differ — lazily re-resolved
                    m.isBaked = true
                }
                flattened = ClipBakePlan.flattened(base, target: target, replacedBy: newID,
                                                   hrTileDrawn: hrTileDrawn)
                // The clock caches key by media id AND localIdentifier — both changed; reload.
                mediaClocks = [:]
                mediaClocksByLocalID = [:]
                loadMediaOffsets()
            } else {
                try await service.saveToOriginal(renderedURL: url, localIdentifier: target,
                                                 projectID: project.id)
                for m in rows {
                    // The length is the rendered one; the capture offset stays, because Photos
                    // can bring the original back. What the bake did to the timing is the time
                    // map, written with the other values (`ClipBakePlan.revertibleMediaUpdate`).
                    let map = ClipBakePlan.timeMap(parts: bakedClips, sourceDurations: bakedDurations,
                                                   transitions: bakedTransitions,
                                                   existing: m.bakeTimeMap)
                    let update = ClipBakePlan.revertibleMediaUpdate(oldOffsetSec: m.offsetSec,
                                                                    oldDurationSec: m.durationSec,
                                                                    renderedDurationSec: renderedDur,
                                                                    timeMap: map,
                                                                    existing: m.bakeTimeMap)
                    m.offsetSec = update.offsetSec
                    m.durationSec = update.durationSec
                    m.bakeTimeMap = update.timeMap
                    m.isBaked = true
                }
                flattened = ClipBakePlan.flattened(base, target: target, hrTileDrawn: hrTileDrawn)
                // The recorded lengths and the time maps are cached with the offsets; read them again.
                mediaClocks = [:]
                mediaClocksByLocalID = [:]
                loadMediaOffsets()
            }
            // `ClipBakePlan.flattened` removed what is now in the pixels and kept what belongs to
            // other clips. Reset undo (barrier), persist. The updatedAt bump also feeds the Clips
            // feed's rebuild key (a revertible bake changes only SessionMedia rows).
            undo = UndoStack(flattened)
            if let id = selectedClipID, !flattened.clips.contains(where: { $0.id == id }) { selectedClipID = nil }
            if let id = selectedOverlayID, !flattened.overlays.contains(where: { $0.id == id }) { selectedOverlayID = nil }
            // Photos has the video now. If the project cannot be saved, that is NOT a success
            // (prompt 302): the message says the video was saved and the project was not.
            let projectSaved = persist()
            // The baked asset's video changed under its identifier (a revertible bake), or the
            // clip points at a new one: the length read before the bake and the composer's
            // opened asset are both stale (prompt 303). Until the real length is read again the
            // clip has the rendered file's.
            let staleAssets = changedAssets
            let bakedClipIDs = Set((base.clips + flattened.clips)
                .filter { staleAssets.contains($0.localIdentifier) }.map(\.id))
            let bakedLength = renderedDur.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            for id in bakedClipIDs {
                sourceDurations[id] = flattened.clips.contains { $0.id == id } ? bakedLength : nil
            }
            for asset in staleAssets { sourceAspects[asset] = nil }
            scheduleRebuild { [self] in
                await composer.forget(localIdentifiers: staleAssets)
                await loadSourceInfo(refreshing: bakedClipIDs)
            }
            switch StudioBakeState.afterPhotosWrite(replaced: replaceOriginal, projectSaved: projectSaved) {
            case .savedProjectNotUpdated(let replaced): send(.bakeSavedProjectNotUpdated(replaced: replaced))
            default: send(.bakeSaved(replaced: replaceOriginal))
            }
        } catch {
            send(.bakeFailed((error as? LocalizedError)?.errorDescription
                             ?? "Couldn't save to the original video."))
        }
    }

    /// Revert detection (the flag's one clearing path): a baked asset whose edited rendition is GONE
    /// (the user tapped "Revert to Original" in Photos) drops `isBaked`, so the feed's live overlay
    /// stands back up. A `nil` probe (asset unreachable — simulator, iCloud eviction) clears nothing.
    /// The Photos probes run OFF the main actor (one fetch + resource enumeration per baked row —
    /// this fires on the Studio's already-busy onAppear); the clears apply back on main.
    ///
    /// Called when the Studio opens and when the app comes back to the foreground with the Studio
    /// open (the user may have been in Photos). `bake()` awaits the same check itself.
    /// Returns the task so a test can wait for it; the app ignores it.
    @discardableResult
    func reconcileBakedFlags() -> Task<Void, Never>? {
        guard hasBakedRows else { return nil }
        return Task { [weak self] in await self?.reconcileBakedRows() }
    }

    private func bakedRows() -> [SessionMedia] {
        let sid = project.sessionID
        return (try? context.fetch(FetchDescriptor<SessionMedia>(
            predicate: #Predicate { $0.sessionID == sid && $0.isBakedRaw == true }))) ?? []
    }
    private var hasBakedRows: Bool { !bakedRows().isEmpty }

    /// The check itself. What "no edited rendition" means for a row is read from its bake record
    /// (`ClipBakePlan.revertFinding`, prompt 305): a "Replace original" asset has nothing to
    /// revert and is left alone; a "Save to original" over a replaced video goes back to that
    /// video's record; anything else goes back to the recording.
    private func reconcileBakedRows() async {
        let rows = bakedRows()
        guard !rows.isEmpty else { return }
        let probes = rows.map { (id: $0.id, localIdentifier: $0.localIdentifier) }
        let probe = bakedAssetProbe ?? { localIdentifier in
            BakedAssetProbe(
                hasEditedRendition: ClipBakeService.hasEditedRendition(localIdentifier: localIdentifier),
                currentDuration: ClipBakeService.currentDuration(localIdentifier: localIdentifier))
        }
        // For an asset with no edited rendition, also the length of the video it plays now.
        let found: [UUID: Double?] = await Task.detached(priority: .utility) {
            var out: [UUID: Double?] = [:]
            for row in probes {
                let answer = probe(row.localIdentifier)
                if answer.hasEditedRendition == false { out[row.id] = answer.currentDuration }
            }
            return out
        }.value
        // A bake in flight replaces the project when it ends, and an export renders the project
        // as it is; leave everything for the next check.
        guard !found.isEmpty, canEdit else { return }
        var changed: [SessionMedia] = []        // the asset plays another video than recorded
        var backToRecording: [SessionMedia] = []
        for m in rows where found[m.id] != nil {
            switch ClipBakePlan.revertFinding(map: m.bakeTimeMap) {
            case .nothingToRevert:
                continue                        // the asset IS the bake: flag, record and map stay
            case .backToReplaced(let replaced):
                m.bakeTimeMap = replaced        // still a baked video: the flag stays
                changed.append(m)
            case .backToRecording:
                // The asset plays the original recording again: the map goes with the flag.
                m.isBaked = false
                m.bakeTimeMap = nil
                changed.append(m)
                backToRecording.append(m)
            }
            // The bake recorded the rendered length; the earlier video's is back (prompt 303).
            m.durationSec = ClipBakePlan.revertedDuration(recorded: m.durationSec,
                                                          asset: found[m.id] ?? nil)
        }
        guard !changed.isEmpty else { return }
        mediaClocks = [:]
        mediaClocksByLocalID = [:]
        loadMediaOffsets()
        // The reverted asset's pixels carry nothing any more, so its clips' `baked` records
        // go and the project's items draw over it again (prompt 295). Like a bake, this is
        // an undo barrier: an older step would bring the record back.
        let cleared = ClipBakePlan.clearingBakeRecords(
            undo.current, mediaIDs: Set(backToRecording.map(\.id)),
            localIdentifiers: Set(backToRecording.map(\.localIdentifier)))
        let recordsCleared = cleared != undo.current
        if recordsCleared {
            undo = UndoStack(cleared)
            cleared.apply(to: project)
        }
        project.updatedAt = .now   // SessionMedia-only change → nudge the feed's rebuild key
        saveStore()
        // The asset's video changed under its identifier: the length read earlier and the
        // composer's opened asset are stale, as after a bake.
        let assets = Set(changed.map(\.localIdentifier))
        let clipIDs = Set(snapshot.clips.filter { assets.contains($0.localIdentifier) }.map(\.id))
        let stale = clipIDs.contains { sourceDurations[$0] != nil }
        if stale {
            await composer.forget(localIdentifiers: assets)
            await loadSourceInfo(refreshing: clipIDs)
        }
        if recordsCleared || stale { await rebuildPreview() }
    }

    // MARK: Export (device-only render)

    /// The running export. The view model owns it so it can be cancelled (prompt 298); it is `nil`
    /// again only when the render has really stopped, which is what `isRendering` reads.
    private var exportTask: Task<Void, Never>?

    /// Start "Export as new video". Refused while either lane renders, and until the first preview
    /// has loaded. Editing is locked for its whole length (prompt 301).
    func startExport() {
        guard state.canExport else { return }
        pause()                 // the preview does not play under a render
        send(.exportBegan)      // also deletes the last export's file
        exportTask = Task { [weak self] in await self?.runExport() }
    }

    private func runExport() async {
        defer {
            exportTask = nil
            send(.exportTaskEnded)
        }
        do {
            // Per-clip HR (each clip's own capture-window) supersedes the session-wide hrSamples in the
            // composer; the session-wide tile stays as the fallback for clips with no media link.
            let url = try await renderComposition { [weak self] fraction in
                self?.send(.exportProgressed(fraction))
            }
            // Cancelled in the moment the render finished: nobody will share this file.
            guard !Task.isCancelled, case .exporting = exportState else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            send(.exportSucceeded(url))
        } catch {
            // The composer deleted the partial file. A cancel shows no message.
            if error is CancellationError || Task.isCancelled {
                send(.exportCancelled)
            } else {
                send(.exportFailed((error as? LocalizedError)?.errorDescription ?? "Export failed."))
            }
        }
    }

    /// The Cancel button: the indicator goes at once; the session stops and deletes its partial
    /// file in the background (`isRendering` stays true until it has).
    func cancelExport() {
        exportTask?.cancel()
        send(.exportCancelled)
    }

    /// The share sheet closed: the rendered file has been handed over, delete it.
    func shareSheetDismissed() { send(.shareDismissed) }

    /// The failure alert closed.
    func acknowledgeExportFailure() { send(.exportFailureAcknowledged) }

    /// The Studio closed: stop a running export and delete the exported file. A bake is not
    /// touched (it cannot be cancelled, and it deletes its own temp file).
    func studioClosed() {
        exportTask?.cancel()
        send(.studioClosed)
        cancelClipDownload()
    }
}
