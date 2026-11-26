import Foundation

/// The pure state of the Studio editor (prompt 301): ONE value the view model holds, changed only by
/// `reducing(_:)`, from which the editor's phase and what is allowed in it are derived. No
/// AVFoundation / Photos / SwiftData / SwiftUI, so every transition and permission is unit-tested
/// without a device (`StudioEditorStateTests`), in the style of `ExportShareState`.
///
/// The two render lanes keep their own tested machines (`ExportShareState`, `StudioBakeState`) as
/// fields here; `phase` is DERIVED from them and the preview's load state. See decisions.md
/// (prompt 301) for why they are not payloads of the phase.

// MARK: - Selection

/// What is selected in the editor: nothing, one clip, or one overlay. Never a clip and an overlay
/// at once (the two optional ids this replaced could both be set).
enum StudioSelection: Equatable, Sendable {
    case none
    case clip(UUID)
    case overlay(UUID)

    var clipID: UUID? {
        if case .clip(let id) = self { return id }
        return nil
    }
    var overlayID: UUID? {
        if case .overlay(let id) = self { return id }
        return nil
    }

    /// Select a clip. `nil` clears a clip selection and leaves an overlay selection alone.
    func settingClip(_ id: UUID?) -> StudioSelection {
        if let id { return .clip(id) }
        if case .clip = self { return .none }
        return self
    }
    /// Select an overlay. `nil` clears an overlay selection and leaves a clip selection alone.
    func settingOverlay(_ id: UUID?) -> StudioSelection {
        if let id { return .overlay(id) }
        if case .overlay = self { return .none }
        return self
    }
}

// MARK: - Bake lane

/// The bake lane's state ("Save to original" / "Replace original"). Separate from the export
/// lane's `ExportShareState`: a bake has no share sheet, no progress and no cancel (prompt 298).
enum StudioBakeState: Equatable, Sendable {
    case idle, baking
    case saved(replaced: Bool)
    case failed(String)
    /// The video was written to Photos, but the project could not be saved afterwards
    /// (prompt 302). Not a success and not a plain failure: the message says both halves.
    case savedProjectNotUpdated(replaced: Bool)

    /// What a bake ends as once Photos has taken the video: a success only if the project was
    /// saved too.
    static func afterPhotosWrite(replaced: Bool, projectSaved: Bool) -> StudioBakeState {
        projectSaved ? .saved(replaced: replaced) : .savedProjectNotUpdated(replaced: replaced)
    }

    static let projectNotUpdatedTitle = "Video saved, but this project was not updated"

    /// The message for `savedProjectNotUpdated`.
    static func projectNotUpdatedMessage(replaced: Bool) -> String {
        let video = replaced
            ? "The edited video replaced the original in Photos."
            : "The edit was saved into the video in Photos."
        return video + " Snappet could not save the change to this project, so the project may "
            + "still show the old edits. Keep the Studio open and make any change: Snappet will "
            + "try to save again."
    }

    /// A bake is refused before anything is written when the video's own records cannot be read
    /// (prompt 303): the bake would re-point the project and leave the records behind.
    static let recordsUnreadableMessage = "Snappet couldn't read this video's record, so nothing "
        + "was changed. Close the Studio, open it again and try once more."
}

// MARK: - Transport

/// What the real player is doing, mirrored from `AVPlayer.timeControlStatus`.
enum StudioPlayerStatus: Equatable, Sendable {
    /// Not playing, and not trying to.
    case paused
    /// Asked to play, but not moving yet (buffering, a stall).
    case waiting
    case playing
}

/// The pure transport decisions. The view model observes the player (the device edge) and asks
/// these what to show and where to resume.
enum StudioTransport {
    /// The play/pause button shows "pause" whenever the player is playing or trying to: tapping it
    /// then stops the attempt. It shows "play" only when the player is really paused.
    static func showsPause(_ status: StudioPlayerStatus) -> Bool { status != .paused }

    /// The playhead follows the player's clock only while it really plays. While paused or
    /// waiting, the playhead belongs to the user's scrub.
    static func followsPlayerClock(_ status: StudioPlayerStatus) -> Bool { status == .playing }

    /// Where the playhead goes when a rebuilt preview replaces the old one: the position at the
    /// moment of the swap (so a scrub made while the rebuild ran is kept), held inside the new length.
    static func resumePosition(positionNow: Double, total: Double) -> Double {
        guard positionNow.isFinite, total.isFinite else { return 0 }
        return max(0, min(positionNow, max(0, total)))
    }

    /// Whether the rebuilt preview starts playing: only if the player was playing or trying to at
    /// the moment of the swap (a pause made while the rebuild ran is kept).
    static func resumesPlaying(_ statusNow: StudioPlayerStatus) -> Bool { statusNow != .paused }

    /// Play pressed at the end starts again from the top.
    static func restartsFromTop(position: Double, duration: Double) -> Bool {
        position >= duration - 0.05
    }
}

/// Which player-clock ticks may move the playhead (prompt 303). A seek is not instant: until the
/// player has finished it, the periodic observer still reports times from before it — the end of
/// the video after "play to the end" has sought back to 0, or 0 from a rebuilt preview's new item
/// before it has sought to where the playhead was. Each seek gets a number; a tick counts only
/// when the latest seek has finished.
struct StudioSeekGate: Equatable, Sendable {
    private(set) var latest = 0
    private(set) var finished = 0

    /// A seek was asked of the player. Returns its number, to hand back to `finish`.
    mutating func begin() -> Int {
        latest += 1
        return latest
    }

    /// The player finished (or dropped) seek number `generation`. An older seek ending after a
    /// newer one began does not open the gate.
    mutating func finish(_ generation: Int) {
        finished = max(finished, min(generation, latest))
    }

    /// The player is gone: no seek is waiting any more.
    mutating func reset() { finished = latest }

    /// The player's clock may move the playhead: no seek is still in flight.
    var acceptsTick: Bool { finished >= latest }
}

// MARK: - Presentation

/// The bottom-sheet tool invoked from the action bar (Speed · Filter · Transition · Canvas) — keeps
/// the bar to one tap and the value-picking in a focused sheet (the edits pattern).
enum StudioTool: String, Identifiable, Sendable {
    case speed, volume, filter, adjust, transition, aspect, hr, grid
    var id: String { rawValue }
}

/// The one sheet / dialog the user opened over the editor. Only one can be up at a time, so it is
/// one value (the view held a Bool per sheet). The result alerts (bake saved / failed, export
/// failed) are not here: they are independent and read the export and bake states themselves.
enum StudioEditorSheet: Equatable, Sendable {
    /// The share sheet for the exported file.
    case share
    case tool(StudioTool)
    case textStyle
    case addText
    case rename
    case editOverlayText
    case musicImporter
    case pipChooser
    case confirmReplace

    var tool: StudioTool? {
        if case .tool(let tool) = self { return tool }
        return nil
    }
}

// MARK: - Editor state

struct StudioEditorState: Equatable {

    /// Which render is running.
    enum RenderLane: Equatable {
        /// "Export as new video", with the fraction done (0…1).
        case export(progress: Double)
        /// "Save to original" / "Replace original". No progress is known.
        case bake
    }

    /// The render the user asked for. Photos is asked about the baked clips before it starts.
    enum RenderKind: Equatable, Sendable {
        case export, bake

        /// Photos was asked before the render and a baked clip had been reverted there (prompt
        /// 305): the render does not start, because the preview and the trims on screen were
        /// made against the video that is gone. Shown by the lane's own failure alert.
        var revertedInPhotosMessage: String {
            switch self {
            case .bake: return "This clip was reverted in Photos. Check it and save again."
            case .export: return "This clip was reverted in Photos. Check it and export again."
            }
        }
    }

    /// What a finished render left.
    enum Finish: Equatable {
        /// The exported file, waiting in the share sheet.
        case exported(URL)
        /// The edit was written into the original video.
        case savedToOriginal(replaced: Bool)
    }

    /// The editor is always in exactly one of these.
    enum Phase: Equatable {
        /// The first preview is being made. The project can already be edited.
        case loading
        /// Everything is allowed.
        case ready
        /// The user asked for a render and Photos is being asked whether a baked clip was
        /// reverted (prompt 305). Editing, closing and starting another render are locked from
        /// the tap: what the check finds can change the clips, and the render must be made from
        /// what the user saw.
        case checking(RenderKind)
        /// A render runs: editing is locked.
        case rendering(RenderLane)
        /// A render ended and its result is on screen.
        case finished(Finish)
        /// A clip the video needs is not on this phone (prompt 302). The panel says which and
        /// offers what can be done. The project can be edited; it cannot be played or exported.
        case clipMissing(StudioMediaPlan.Panel)
    }

    /// Everything that moves the state.
    enum Event: Equatable {
        case select(StudioSelection)

        // Preview
        case previewBuildBegan
        /// A player holds the new preview. `warning` is shown over it (the styled preview was
        /// rejected and the plain one plays).
        case previewBuilt(warning: String?)
        /// There is no player: the preview could not be made, or its item failed while playing.
        case previewUnavailable(message: String?)
        case playerStatusChanged(StudioPlayerStatus)

        // The check before a render (prompt 305)
        /// The user asked for a render and Photos has to be asked first.
        case checkBegan(RenderKind)
        /// Nothing was reverted: the render may begin.
        case checkPassed
        /// A baked clip was reverted in Photos: the render does not begin, and the lane's
        /// failure alert says why.
        case checkFoundRevert

        // Export lane
        case exportBegan
        case exportProgressed(Double)
        case exportCancelled
        case exportSucceeded(URL)
        case exportFailed(String)
        /// The export's task has really stopped (after a finish, a failure or a cancel).
        case exportTaskEnded
        case shareDismissed
        case exportFailureAcknowledged
        case studioClosed

        // Bake lane
        case bakeBegan
        case bakeSaved(replaced: Bool)
        case bakeFailed(String)
        /// Photos took the video and the project could not be saved (prompt 302).
        case bakeSavedProjectNotUpdated(replaced: Bool)
        case bakeAcknowledged

        // Media availability (prompt 302)
        /// The service reported where the timeline's videos are.
        case mediaChecked(sources: [StudioMediaPlan.Source], statuses: [String: StudioAssetStatus])
        /// The timeline changed (an edit, undo, redo).
        case mediaSourcesChanged([StudioMediaPlan.Source])
        case previewWithoutMissing
        case showMissingOptions
        /// `request` numbers the download; its progress reports carry the same number (prompt 303).
        case downloadBegan(String, request: Int)
        case downloadProgressed(Double, request: Int)
        case downloadFinished(String)
        case downloadFailed(String)
        case downloadCancelled

        // Saving the project (prompt 302)
        case saveSucceeded
        case saveFailed
        case saveFailureDismissed
    }

    var selection: StudioSelection = .none
    var export: ExportShareState = .idle
    var bake: StudioBakeState = .idle
    /// The render that waits for the answer from Photos (prompt 305), or `nil`.
    var checkingFor: RenderKind?
    /// The export's task is still alive. A cancelled export is idle at once, but its session may
    /// still be stopping (prompt 298); no other render may start until it has.
    var exportTaskRunning = false

    /// The first preview build has ended (with or without a player).
    var previewLoaded = false
    var isBuildingPreview = false
    /// A player holds a preview.
    var hasPlayer = false
    /// Shown over the preview: why it is plain, or why there is none.
    var previewMessage: String?
    var player: StudioPlayerStatus = .paused

    /// Where the timeline's videos are, and what the user chose to do about the ones that are not
    /// on this phone (prompt 302).
    var media = StudioMediaPlan()
    /// The last save of the project failed and the user has not closed the message. The next
    /// save that works clears it.
    var saveFailure: StudioSaveFailure?

    // MARK: Derived

    var phase: Phase {
        if bake == .baking { return .rendering(.bake) }
        if case .exporting(let progress) = export { return .rendering(.export(progress: progress)) }
        if let kind = checkingFor { return .checking(kind) }
        if let panel = media.panel { return .clipMissing(panel) }
        if !previewLoaded { return .loading }
        if let url = export.exportedURL { return .finished(.exported(url)) }
        if case .saved(let replaced) = bake { return .finished(.savedToOriginal(replaced: replaced)) }
        return .ready
    }

    /// The empty preview area says "Building preview…": the first preview is not made yet, or a
    /// later one is being made. Keyed on the phase (prompt 303) — in the opening window, before
    /// the first build has begun, `isBuildingPreview` is still false and the area used to say
    /// the preview could not be made.
    var showsBuildingPreview: Bool {
        if case .loading = phase { return true }
        return isBuildingPreview
    }

    /// A preview may be built: the first availability result is in (prompt 303). Before it,
    /// nothing is known about where the videos are, and the composer would download an iCloud
    /// clip without a word. The Studio's opening builds the preview right after the result.
    var canBuildPreview: Bool { media.isChecked }

    /// A bake is in flight (prompt 294).
    var isBaking: Bool { bake == .baking }

    /// A render is in flight in either lane, or a cancelled export has not stopped yet.
    var isRendering: Bool {
        if case .exporting = export { return true }
        return isBaking || exportTaskRunning
    }

    /// Photos is being asked before a render (prompt 305).
    var isChecking: Bool { checkingFor != nil }

    /// The project may be changed. Locked while either lane renders, and while Photos is asked
    /// before a render.
    var canEdit: Bool {
        switch phase {
        case .rendering, .checking: return false
        case .loading, .ready, .finished, .clipMissing: return true
        }
    }

    /// The preview can be played: there is a player, no render is running, and no missing clip
    /// is waiting for a decision.
    var canPlay: Bool {
        if case .clipMissing = phase { return false }
        return hasPlayer && canEdit
    }

    /// A render may start: the first load is done, no render is in flight, and every clip the
    /// video needs is on this phone.
    var canExport: Bool { previewLoaded && !isRendering && !isChecking && media.allAvailable }

    /// Why Export is off although nothing is rendering ("Export needs all clips").
    var exportBlockedReason: String? { media.exportBlockedReason }

    /// The Studio may be closed. A bake cannot be cancelled, so it blocks closing; closing during
    /// an export is allowed and cancels it (prompt 298).
    /// The check before a render blocks it too (prompt 305): a bake that the check lets through
    /// writes to Photos, and nobody would see its result.
    var canClose: Bool { !isBaking && !isChecking }

    /// The one line shown while editing is locked.
    var lockReason: String? {
        switch phase {
        case .rendering(.export): return "Editing is locked while exporting"
        case .rendering(.bake): return "Editing is locked while saving to the original"
        case .checking: return "Checking this video in Photos"
        case .loading, .ready, .finished, .clipMissing: return nil
        }
    }

    var showsPause: Bool { StudioTransport.showsPause(player) }

    // MARK: Reducer

    func reducing(_ event: Event) -> StudioEditorState {
        var s = self
        switch event {
        case .select(let selection):
            s.selection = selection

        case .previewBuildBegan:
            s.isBuildingPreview = true
            s.previewMessage = nil
        case .previewBuilt(let warning):
            s.isBuildingPreview = false
            s.previewLoaded = true
            s.hasPlayer = true
            s.previewMessage = warning
        case .previewUnavailable(let message):
            s.isBuildingPreview = false
            s.previewLoaded = true
            s.hasPlayer = false
            s.previewMessage = message
            s.player = .paused
        case .playerStatusChanged(let status):
            s.player = s.hasPlayer ? status : .paused

        case .checkBegan(let kind):
            guard canExport else { return self }
            s.checkingFor = kind
        case .checkPassed:
            s.checkingFor = nil
        case .checkFoundRevert:
            guard let kind = checkingFor else { return self }
            s.checkingFor = nil
            switch kind {
            case .bake: s.bake = .failed(kind.revertedInPhotosMessage)
            case .export: s.export = export.failed(kind.revertedInPhotosMessage)
            }

        case .exportBegan:
            guard canExport else { return self }
            s.export = export.beginningExport()
            s.exportTaskRunning = true
        case .exportProgressed(let fraction):
            s.export = export.exportProgressed(fraction)
        case .exportCancelled:
            s.export = export.exportCancelled()
        case .exportSucceeded(let url):
            guard case .exporting = export else { return self }
            s.export = export.exportSucceeded(url)
        case .exportFailed(let message):
            guard case .exporting = export else { return self }
            s.export = export.failed(message)
        case .exportTaskEnded:
            s.exportTaskRunning = false
        case .shareDismissed:
            s.export = export.shareDismissed()
        case .exportFailureAcknowledged:
            s.export = export.failureAcknowledged()
        case .studioClosed:
            s.export = .idle

        case .bakeBegan:
            guard canExport else { return self }
            s.bake = .baking
        case .bakeSaved(let replaced):
            guard isBaking else { return self }
            s.bake = .saved(replaced: replaced)
        case .bakeFailed(let message):
            guard isBaking else { return self }
            s.bake = .failed(message)
        case .bakeSavedProjectNotUpdated(let replaced):
            guard isBaking else { return self }
            s.bake = .savedProjectNotUpdated(replaced: replaced)
            // The bake's own alert says the project was not saved; the save banner would say it
            // a second time (prompt 303).
            s.saveFailure = nil
        case .bakeAcknowledged:
            guard !isBaking else { return self }
            s.bake = .idle

        case .mediaChecked(let sources, let statuses):
            s.media = media.checked(sources: sources, statuses: statuses)
        case .mediaSourcesChanged(let sources):
            s.media = media.settingSources(sources)
        case .previewWithoutMissing:
            s.media = media.previewingWithoutMissing()
        case .showMissingOptions:
            s.media = media.showingOptions()
        case .downloadBegan(let localIdentifier, let request):
            s.media = media.downloadBegan(localIdentifier, request: request)
        case .downloadProgressed(let fraction, let request):
            s.media = media.downloadProgressed(fraction, request: request)
        case .downloadFinished(let localIdentifier):
            s.media = media.downloadFinished(localIdentifier)
        case .downloadFailed(let message):
            s.media = media.downloadFailed(message)
        case .downloadCancelled:
            s.media = media.downloadCancelled()

        case .saveSucceeded:
            s.saveFailure = nil
        case .saveFailed:
            s.saveFailure = .edit
        case .saveFailureDismissed:
            s.saveFailure = nil
        }
        return s
    }
}
