import XCTest
import SwiftData
@testable import Snappet

/// The Studio editor's one state (prompt 301): the pure `StudioEditorState` reducer, its derived
/// phase and permissions, the pure transport decisions, and the view model's lock while an export
/// renders (in-memory store, no device).
final class StudioEditorStateTests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/snappet-studio-test.mp4")

    /// A state whose first preview has loaded, with a player.
    private var loaded: StudioEditorState {
        StudioEditorState().reducing(.previewBuildBegan).reducing(.previewBuilt(warning: nil))
    }

    // MARK: Phase and permissions (pure)

    func testANewEditorIsLoadingAndCanAlreadyBeEdited() {
        let s = StudioEditorState()
        XCTAssertEqual(s.phase, .loading)
        XCTAssertTrue(s.canEdit)
        XCTAssertFalse(s.canPlay)
        XCTAssertFalse(s.canExport)
        XCTAssertTrue(s.canClose)
        XCTAssertNil(s.lockReason)
    }

    func testLoadingEndsWithOrWithoutAPlayer() {
        let building = StudioEditorState().reducing(.previewBuildBegan)
        XCTAssertEqual(building.phase, .loading)
        XCTAssertTrue(building.isBuildingPreview)

        let withPlayer = building.reducing(.previewBuilt(warning: nil))
        XCTAssertEqual(withPlayer.phase, .ready)
        XCTAssertFalse(withPlayer.isBuildingPreview)
        XCTAssertTrue(withPlayer.canPlay)
        XCTAssertTrue(withPlayer.canExport)

        let without = building.reducing(.previewUnavailable(message: nil))
        XCTAssertEqual(without.phase, .ready)
        XCTAssertFalse(without.canPlay)
        XCTAssertTrue(without.canExport)      // export does not need the preview player
    }

    /// A later rebuild (one per edit) is not "loading" again: the editor stays ready.
    func testARebuildAfterTheFirstLoadStaysReady() {
        let s = loaded.reducing(.previewBuildBegan)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertTrue(s.isBuildingPreview)
        XCTAssertTrue(s.canEdit)
        XCTAssertTrue(s.canPlay)
    }

    func testAnExportLocksEditingAndPlayingButNotClosing() {
        let s = loaded.reducing(.exportBegan)
        XCTAssertEqual(s.phase, .rendering(.export(progress: 0)))
        XCTAssertFalse(s.canEdit)
        XCTAssertFalse(s.canPlay)
        XCTAssertFalse(s.canExport)
        XCTAssertTrue(s.canClose)
        XCTAssertTrue(s.isRendering)
        XCTAssertFalse(s.isBaking)
        XCTAssertEqual(s.lockReason, "Editing is locked while exporting")

        let half = s.reducing(.exportProgressed(0.5))
        XCTAssertEqual(half.phase, .rendering(.export(progress: 0.5)))
    }

    func testABakeLocksEditingAndClosing() {
        let s = loaded.reducing(.bakeBegan)
        XCTAssertEqual(s.phase, .rendering(.bake))
        XCTAssertFalse(s.canEdit)
        XCTAssertFalse(s.canPlay)
        XCTAssertFalse(s.canExport)
        XCTAssertFalse(s.canClose)
        XCTAssertTrue(s.isBaking)
        XCTAssertTrue(s.isRendering)
        XCTAssertEqual(s.lockReason, "Editing is locked while saving to the original")
    }

    func testFinishedHoldsTheExportedFileUntilTheShareSheetCloses() {
        let done = loaded.reducing(.exportBegan).reducing(.exportSucceeded(file))
        XCTAssertEqual(done.phase, .finished(.exported(file)))
        XCTAssertTrue(done.canEdit)
        XCTAssertTrue(done.isRendering)                // the task has not reported its end yet
        let ended = done.reducing(.exportTaskEnded)
        XCTAssertFalse(ended.isRendering)
        XCTAssertEqual(ended.reducing(.shareDismissed).phase, .ready)
    }

    func testFinishedHoldsTheBakeResultUntilItIsAcknowledged() {
        let saved = loaded.reducing(.bakeBegan).reducing(.bakeSaved(replaced: true))
        XCTAssertEqual(saved.phase, .finished(.savedToOriginal(replaced: true)))
        XCTAssertTrue(saved.canEdit)
        XCTAssertTrue(saved.canClose)
        XCTAssertEqual(saved.reducing(.bakeAcknowledged).phase, .ready)
    }

    /// A failure is not a phase: the editor is ready again and the lane's state carries the message.
    func testAFailedRenderReturnsToReadyWithTheMessageInItsLane() {
        let exportFailed = loaded.reducing(.exportBegan).reducing(.exportFailed("No space"))
        XCTAssertEqual(exportFailed.phase, .ready)
        XCTAssertEqual(exportFailed.export, .failed("No space"))
        XCTAssertEqual(exportFailed.reducing(.exportFailureAcknowledged).export, .idle)

        let bakeFailed = loaded.reducing(.bakeBegan).reducing(.bakeFailed("Photos said no"))
        XCTAssertEqual(bakeFailed.phase, .ready)
        XCTAssertEqual(bakeFailed.bake, .failed("Photos said no"))
        XCTAssertEqual(bakeFailed.reducing(.bakeAcknowledged).bake, .idle)
    }

    // MARK: Reducer guards (pure)

    func testOnlyOneRenderAtATime() {
        let exporting = loaded.reducing(.exportBegan)
        XCTAssertEqual(exporting.reducing(.bakeBegan), exporting)
        XCTAssertEqual(exporting.reducing(.exportBegan), exporting)

        let baking = loaded.reducing(.bakeBegan)
        XCTAssertEqual(baking.reducing(.exportBegan), baking)
        XCTAssertEqual(baking.reducing(.bakeAcknowledged), baking)   // a running bake cannot be dismissed

        XCTAssertEqual(StudioEditorState().reducing(.exportBegan), StudioEditorState())   // still loading
    }

    /// A cancelled export is ready at once, but no render may start until its task has stopped.
    func testACancelledExportBlocksANewRenderUntilItsTaskEnds() {
        let cancelled = loaded.reducing(.exportBegan).reducing(.exportProgressed(0.3))
            .reducing(.exportCancelled)
        XCTAssertEqual(cancelled.phase, .ready)
        XCTAssertTrue(cancelled.canEdit)
        XCTAssertTrue(cancelled.isRendering)
        XCTAssertFalse(cancelled.canExport)
        XCTAssertEqual(cancelled.reducing(.bakeBegan), cancelled)
        let stopped = cancelled.reducing(.exportTaskEnded)
        XCTAssertFalse(stopped.isRendering)
        XCTAssertTrue(stopped.canExport)
    }

    func testLateEventsChangeNothing() {
        let cancelled = loaded.reducing(.exportBegan).reducing(.exportCancelled)
        XCTAssertEqual(cancelled.reducing(.exportSucceeded(file)), cancelled)
        XCTAssertEqual(cancelled.reducing(.exportFailed("late")), cancelled)
        XCTAssertEqual(cancelled.reducing(.exportProgressed(0.9)), cancelled)
        XCTAssertEqual(loaded.reducing(.bakeSaved(replaced: false)), loaded)
        XCTAssertEqual(loaded.reducing(.bakeFailed("late")), loaded)
    }

    func testClosingTheStudioDropsTheExport() {
        let exported = loaded.reducing(.exportBegan).reducing(.exportSucceeded(file))
        let closed = exported.reducing(.studioClosed)
        XCTAssertEqual(closed.export, .idle)
        XCTAssertEqual(exported.export.fileToDelete(movingTo: closed.export), file)
    }

    // MARK: Transport (pure)

    func testThePlayButtonShowsWhatThePlayerIsDoing() {
        XCTAssertFalse(StudioTransport.showsPause(.paused))
        XCTAssertTrue(StudioTransport.showsPause(.waiting))     // stalled, still trying: tap = pause
        XCTAssertTrue(StudioTransport.showsPause(.playing))
        XCTAssertFalse(StudioTransport.followsPlayerClock(.paused))
        XCTAssertFalse(StudioTransport.followsPlayerClock(.waiting))
        XCTAssertTrue(StudioTransport.followsPlayerClock(.playing))
    }

    func testPlayerStatusIsMirroredOnlyWhileThereIsAPlayer() {
        let playing = loaded.reducing(.playerStatusChanged(.playing))
        XCTAssertTrue(playing.showsPause)
        // an interruption / the end of the item: the player reports paused
        XCTAssertFalse(playing.reducing(.playerStatusChanged(.paused)).showsPause)
        // the item failed, or the rebuild found nothing to play: nothing is left playing
        let gone = playing.reducing(.previewUnavailable(message: "Preview unavailable: decode"))
        XCTAssertFalse(gone.showsPause)
        XCTAssertFalse(gone.hasPlayer)
        XCTAssertEqual(gone.previewMessage, "Preview unavailable: decode")
        XCTAssertFalse(gone.reducing(.playerStatusChanged(.playing)).showsPause)   // a late report
        // the next build clears the message
        XCTAssertNil(gone.reducing(.previewBuildBegan).previewMessage)
    }

    /// The position at the moment of the swap wins, so a scrub made during the rebuild is kept.
    func testARebuildResumesAtThePositionAtTheSwap() {
        XCTAssertEqual(StudioTransport.resumePosition(positionNow: 7, total: 20), 7)
        XCTAssertEqual(StudioTransport.resumePosition(positionNow: 25, total: 20), 20)   // shorter now
        XCTAssertEqual(StudioTransport.resumePosition(positionNow: -1, total: 20), 0)
        XCTAssertEqual(StudioTransport.resumePosition(positionNow: .nan, total: 20), 0)
        XCTAssertEqual(StudioTransport.resumePosition(positionNow: 3, total: 0), 0)
        XCTAssertTrue(StudioTransport.resumesPlaying(.playing))
        XCTAssertTrue(StudioTransport.resumesPlaying(.waiting))
        XCTAssertFalse(StudioTransport.resumesPlaying(.paused))   // paused during the rebuild
    }

    func testPlayAtTheEndRestarts() {
        XCTAssertTrue(StudioTransport.restartsFromTop(position: 20, duration: 20))
        XCTAssertTrue(StudioTransport.restartsFromTop(position: 19.96, duration: 20))
        XCTAssertFalse(StudioTransport.restartsFromTop(position: 12, duration: 20))
    }

    /// A tick from the player's clock counts only when the latest seek has finished (prompt
    /// 303). After "play to the end" seeks back to 0, a late tick still carrying the end time is
    /// ignored; so is a tick from a rebuilt preview's new item before it has sought back.
    func testAClockTickThatPredatesTheLatestSeekIsIgnored() {
        var gate = StudioSeekGate()
        XCTAssertTrue(gate.acceptsTick)                         // nothing sought yet: follow the clock

        let toStart = gate.begin()                              // played to the end → seek(to: 0)
        XCTAssertFalse(gate.acceptsTick)                        // the late tick with the end time
        gate.finish(toStart)
        XCTAssertTrue(gate.acceptsTick)

        // two seeks in a row (a scrub): the first one ending does not open the gate
        let first = gate.begin(), second = gate.begin()
        gate.finish(first)
        XCTAssertFalse(gate.acceptsTick)
        gate.finish(second)
        XCTAssertTrue(gate.acceptsTick)
        gate.finish(first)                                      // an old report changes nothing
        XCTAssertTrue(gate.acceptsTick)

        // a number that was never handed out cannot open a later seek's gate
        gate.finish(999)
        _ = gate.begin()
        XCTAssertFalse(gate.acceptsTick)
        // the player went away with a seek in flight: nothing is waiting any more
        gate.reset()
        XCTAssertTrue(gate.acceptsTick)
    }

    // MARK: Selection and presentation (pure)

    func testSelectionIsOneValue() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(StudioSelection.none.settingClip(a), .clip(a))
        XCTAssertEqual(StudioSelection.clip(a).settingOverlay(b), .overlay(b))
        XCTAssertEqual(StudioSelection.overlay(b).settingClip(a), .clip(a))
        XCTAssertEqual(StudioSelection.clip(a).settingClip(nil), .none)
        XCTAssertEqual(StudioSelection.overlay(b).settingOverlay(nil), .none)
        // clearing the other kind leaves the selection alone
        XCTAssertEqual(StudioSelection.clip(a).settingOverlay(nil), .clip(a))
        XCTAssertEqual(StudioSelection.overlay(b).settingClip(nil), .overlay(b))
        XCTAssertEqual(StudioSelection.clip(a).clipID, a)
        XCTAssertNil(StudioSelection.clip(a).overlayID)
        XCTAssertEqual(StudioSelection.overlay(b).overlayID, b)
        XCTAssertNil(StudioSelection.overlay(b).clipID)
    }

    func testPresentationCarriesItsTool() {
        XCTAssertEqual(StudioEditorSheet.tool(.speed).tool, .speed)
        XCTAssertNil(StudioEditorSheet.rename.tool)
        XCTAssertNotEqual(StudioEditorSheet.tool(.speed), .tool(.filter))
    }

    // MARK: View model (in-memory store)

    /// A project of one PHOTO clip: the composer refuses it before it asks Photos for anything, so
    /// the first load ends (with no player) without touching the photo library.
    @MainActor
    private func makeViewModel() throws -> (StudioEditorViewModel, StudioProject, TimelineClip, ModelContainer) {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let project = StudioProject(sessionID: UUID(), title: "Before")
        let clip = TimelineClip(sessionMediaID: UUID(), localIdentifier: "A", isPhoto: true,
                                order: 0, trimStart: 0, trimEnd: nil)
        project.clips = [clip]
        container.mainContext.insert(project)
        return (StudioEditorViewModel(project: project, context: container.mainContext), project, clip, container)
    }

    @MainActor
    func testTheEditorCanBeEditedButNotExportedBeforeItHasLoaded() throws {
        let (vm, project, _, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        XCTAssertEqual(vm.state.phase, .loading)
        vm.startExport()
        XCTAssertFalse(vm.isRendering)
        vm.rename("Early")
        XCTAssertEqual(project.title, "Early")
    }

    /// Every edit path refuses while an export renders, exactly as during a bake (prompt 294). The
    /// lock ends when the export is cancelled; a new render waits for the old task to stop.
    @MainActor
    func testEditsAreRefusedWhileAnExportRenders() async throws {
        let (vm, project, clip, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        await vm.onAppear()
        XCTAssertEqual(vm.state.phase, .ready)
        XCTAssertNil(vm.previewPlayer)
        vm.rename("One")                               // an undo step from before the export

        vm.startExport()
        XCTAssertEqual(vm.state.phase, .rendering(.export(progress: 0)))
        XCTAssertTrue(vm.isRendering)
        XCTAssertFalse(vm.isBaking)
        XCTAssertFalse(vm.canEdit)
        XCTAssertTrue(vm.state.canClose)
        vm.rename("During")
        vm.addText("Nope")
        vm.select(clip.id)
        vm.deleteSelected()
        vm.undoEdit()
        vm.beginGesture()
        XCTAssertEqual(vm.title, "One")
        XCTAssertEqual(project.title, "One")
        XCTAssertEqual(vm.clips.map(\.id), [clip.id])
        XCTAssertTrue(vm.overlays.isEmpty)

        vm.cancelExport()
        XCTAssertEqual(vm.state.phase, .ready)
        XCTAssertTrue(vm.canEdit)
        XCTAssertTrue(vm.isRendering)                  // the cancelled task has not stopped yet
        vm.rename("After")
        XCTAssertEqual(project.title, "After")
        for _ in 0..<200 where vm.isRendering { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.isRendering)
        XCTAssertEqual(vm.exportState, .idle)          // a cancel leaves no message
    }

    /// A bake still locks, and is the only thing that blocks closing.
    @MainActor
    func testABakeLocksAndBlocksClosing() throws {
        let (vm, _, _, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        vm.bakeState = .baking
        XCTAssertEqual(vm.state.phase, .rendering(.bake))
        XCTAssertTrue(vm.isBaking)
        XCTAssertTrue(vm.isRendering)
        XCTAssertFalse(vm.canEdit)
        XCTAssertFalse(vm.state.canClose)
        vm.acknowledgeBake()                           // the alert cannot dismiss a running bake
        XCTAssertTrue(vm.isBaking)
        vm.bakeState = .saved(replaced: false)
        XCTAssertTrue(vm.state.canClose)
        vm.acknowledgeBake()
        XCTAssertEqual(vm.bakeState, .idle)
    }

    /// Selecting an overlay deselects the clip and the other way round; the id accessors follow.
    @MainActor
    func testTheViewModelSelectionIsOneValue() throws {
        let (vm, _, clip, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        vm.select(clip.id)
        XCTAssertEqual(vm.state.selection, .clip(clip.id))
        XCTAssertEqual(vm.selectedClip?.id, clip.id)

        vm.addText("Hello")                            // a new overlay is selected, ready to drag
        let overlayID = try XCTUnwrap(vm.overlays.first?.id)
        XCTAssertEqual(vm.state.selection, .overlay(overlayID))
        XCTAssertNil(vm.selectedClipID)
        XCTAssertEqual(vm.selectedOverlay?.id, overlayID)

        vm.select(clip.id)
        XCTAssertNil(vm.selectedOverlayID)
        vm.selectOverlay(nil)                          // a tap on the empty canvas keeps the clip
        XCTAssertEqual(vm.state.selection, .clip(clip.id))
        vm.selectOverlay(overlayID)
        vm.deleteOverlay(overlayID)
        XCTAssertEqual(vm.state.selection, .none)
    }

    /// With no player nothing can be left "playing", and the playhead stays inside the timeline.
    @MainActor
    func testTransportWithNoPlayer() async throws {
        let (vm, _, _, container) = try makeViewModel()
        defer { withExtendedLifetime(container) {} }
        await vm.onAppear()
        XCTAssertFalse(vm.state.canPlay)
        vm.play()
        XCTAssertFalse(vm.isPlaying)
        vm.togglePlay()
        XCTAssertFalse(vm.isPlaying)
        vm.seek(to: 10_000)
        XCTAssertEqual(vm.currentTime, vm.totalDuration)
        vm.seek(to: -5)
        XCTAssertEqual(vm.currentTime, 0)
    }
}
