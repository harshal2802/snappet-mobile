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
        /// A render runs: editing is locked.
        case rendering(RenderLane)
        /// A render ended and its result is on screen.
        case finished(Finish)
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
        case bakeAcknowledged
    }

    var selection: StudioSelection = .none
    var export: ExportShareState = .idle
    var bake: StudioBakeState = .idle
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

    // MARK: Derived

    var phase: Phase {
        if bake == .baking { return .rendering(.bake) }
        if case .exporting(let progress) = export { return .rendering(.export(progress: progress)) }
        if !previewLoaded { return .loading }
        if let url = export.exportedURL { return .finished(.exported(url)) }
        if case .saved(let replaced) = bake { return .finished(.savedToOriginal(replaced: replaced)) }
        return .ready
    }

    /// A bake is in flight (prompt 294).
    var isBaking: Bool { bake == .baking }

    /// A render is in flight in either lane, or a cancelled export has not stopped yet.
    var isRendering: Bool {
        if case .exporting = export { return true }
        return isBaking || exportTaskRunning
    }

    /// The project may be changed. Locked while either lane renders.
    var canEdit: Bool {
        if case .rendering = phase { return false }
        return true
    }

    /// The preview can be played: there is a player and no render is running.
    var canPlay: Bool { hasPlayer && canEdit }

    /// A render may start: the first load is done and no render is in flight.
    var canExport: Bool { previewLoaded && !isRendering }

    /// The Studio may be closed. A bake cannot be cancelled, so it blocks closing; closing during
    /// an export is allowed and cancels it (prompt 298).
    var canClose: Bool { !isBaking }

    /// The one line shown while editing is locked.
    var lockReason: String? {
        switch phase {
        case .rendering(.export): return "Editing is locked while exporting"
        case .rendering(.bake): return "Editing is locked while saving to the original"
        case .loading, .ready, .finished: return nil
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
        case .bakeAcknowledged:
            guard !isBaking else { return self }
            s.bake = .idle
        }
        return s
    }
}
