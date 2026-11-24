import XCTest
import SwiftData
@testable import Snappet

/// Missing media as a real state, and a failed save that is reported (prompt 302): the pure
/// `StudioMediaPlan`, `StudioPreviewGaps`, the bake / save decisions, and the view model with a
/// stand-in availability service (in-memory store, no device).
final class StudioMediaPlanTests: XCTestCase {

    private let c1 = UUID(), c2 = UUID(), c3 = UUID(), pipID = UUID()

    private func clip(_ id: UUID, _ number: Int, _ local: String) -> StudioMediaPlan.Source {
        .init(role: .clip(id: id, number: number), localIdentifier: local)
    }
    private var threeClips: [StudioMediaPlan.Source] { [clip(c1, 1, "A"), clip(c2, 2, "B"), clip(c3, 3, "C")] }

    /// Three clips, the second one in iCloud — the wireframe's case.
    private var secondInCloud: StudioMediaPlan {
        StudioMediaPlan().checked(sources: threeClips,
                                  statuses: ["A": .available, "B": .inCloud, "C": .available])
    }

    // MARK: Plan (pure)

    func testEverythingOnThePhoneIsNoProblem() {
        let plan = StudioMediaPlan().checked(sources: threeClips,
                                             statuses: ["A": .available, "B": .available, "C": .available])
        XCTAssertTrue(plan.allAvailable)
        XCTAssertNil(plan.panel)
        XCTAssertNil(plan.exportBlockedReason)
        XCTAssertNil(plan.previewingWithoutNotice)
        XCTAssertEqual(plan.readyClips, 3)
        // an asset nobody reported on is left to the composer, as before
        XCTAssertEqual(StudioMediaPlan().settingSources(threeClips).status(of: "A"), .available)
    }

    func testAClipInICloudShowsThePanelAndBlocksExport() throws {
        let plan = secondInCloud
        XCTAssertFalse(plan.allAvailable)
        XCTAssertEqual(plan.exportBlockedReason, "Export needs all clips")
        XCTAssertEqual(plan.totalClips, 3)
        XCTAssertEqual(plan.readyClips, 2)
        XCTAssertEqual(plan.unavailableIdentifiers, ["B"])
        let panel = try XCTUnwrap(plan.panel)
        XCTAssertEqual(panel.title, "Clip 2 is in iCloud")
        XCTAssertEqual(panel.message,
                       "2 of 3 clips are ready. Download clip 2 to preview and export the whole video.")
        XCTAssertTrue(panel.canDownload)
        XCTAssertTrue(panel.canPreviewWithout)
        XCTAssertEqual(panel.removeLabel, "Remove clip from video")
        XCTAssertNil(panel.downloadProgress)
        XCTAssertNil(panel.error)
    }

    /// A deleted clip is worded differently and has no Download.
    func testADeletedClipHasNoDownload() throws {
        let plan = StudioMediaPlan().checked(sources: threeClips,
                                             statuses: ["A": .available, "B": .available, "C": .missing])
        let panel = try XCTUnwrap(plan.panel)
        XCTAssertEqual(panel.title, "Clip 3 can't be found")
        XCTAssertEqual(panel.message, "2 of 3 clips are ready. It was deleted from Photos, or Snappet is "
                       + "not allowed to see it. Remove clip 3 to export the rest.")
        XCTAssertFalse(panel.canDownload)
        XCTAssertTrue(panel.canPreviewWithout)
        XCTAssertEqual(plan.downloadBegan("C"), plan)          // nothing to download
        XCTAssertEqual(StudioMediaPlan.timelineLabel(for: .missing), "Missing")
        XCTAssertEqual(StudioMediaPlan.timelineLabel(for: .inCloud), "iCloud")
        XCTAssertNil(StudioMediaPlan.timelineLabel(for: .available))
        XCTAssertEqual(StudioMediaPlan.accessibilityNote(for: .inCloud), "in iCloud, not downloaded")
        XCTAssertEqual(StudioMediaPlan.accessibilityNote(for: .missing), "missing from Photos")
    }

    func testTheOnlyClipCannotBePreviewedWithout() throws {
        let plan = StudioMediaPlan().checked(sources: [clip(c1, 1, "A")], statuses: ["A": .inCloud])
        let panel = try XCTUnwrap(plan.panel)
        XCTAssertEqual(panel.title, "This clip is in iCloud")
        XCTAssertEqual(panel.message, "Download it to preview and export the whole video.")
        XCTAssertFalse(panel.canPreviewWithout)
        XCTAssertEqual(plan.previewingWithoutMissing(), plan)  // refused: nothing to preview
    }

    func testAPictureInPictureSourceIsAProblemToo() throws {
        let sources = [clip(c1, 1, "A"),
                       StudioMediaPlan.Source(role: .pip(overlayID: pipID), localIdentifier: "P")]
        let plan = StudioMediaPlan().checked(sources: sources, statuses: ["A": .available, "P": .inCloud])
        let panel = try XCTUnwrap(plan.panel)
        XCTAssertEqual(panel.title, "A picture-in-picture clip is in iCloud")
        XCTAssertEqual(panel.removeLabel, "Remove picture-in-picture")
        XCTAssertEqual(plan.readyClips, 1)
        XCTAssertEqual(plan.totalClips, 1)
        XCTAssertEqual(plan.previewingWithoutMissing().previewingWithoutNotice,
                       "A picture-in-picture clip is not in this preview")
    }

    func testPreviewWithoutHidesThePanelButKeepsExportOff() {
        let without = secondInCloud.previewingWithoutMissing()
        XCTAssertNil(without.panel)
        XCTAssertNil(without.blocking)
        XCTAssertEqual(without.previewingWithoutNotice, "Clip 2 is not in this preview")
        XCTAssertEqual(without.exportBlockedReason, "Export needs all clips")
        XCTAssertEqual(without.unavailableIdentifiers, ["B"])
        XCTAssertNotNil(without.showingOptions().panel)        // back to the choices
    }

    func testADownloadReportsProgressAndEndsWithTheClipAvailable() throws {
        let started = secondInCloud.downloadBegan("B")
        XCTAssertEqual(try XCTUnwrap(started.panel).downloadProgress, 0)
        XCTAssertEqual(started.downloadBegan("B"), started)    // one at a time
        let half = started.downloadProgressed(0.5)
        XCTAssertEqual(try XCTUnwrap(half.panel).downloadPercentLabel, "50%")
        XCTAssertEqual(half.downloadProgressed(0.2), half)     // never back
        XCTAssertEqual(half.downloadProgressed(.nan), half)
        XCTAssertEqual(half.downloadProgressed(7).download?.progress, 1)
        XCTAssertEqual(half.downloadFinished("X"), half)       // some other asset

        let done = half.downloadFinished("B")
        XCTAssertTrue(done.allAvailable)
        XCTAssertNil(done.panel)
        XCTAssertNil(done.download)
        XCTAssertNil(done.exportBlockedReason)
        XCTAssertEqual(secondInCloud.downloadProgressed(0.4), secondInCloud)   // no download running
    }

    func testAFailedDownloadSaysSoAndACancelledOneDoesNot() throws {
        let failed = secondInCloud.downloadBegan("B").downloadProgressed(0.3)
            .downloadFailed(StudioMediaPlan.downloadFailedMessage)
        let panel = try XCTUnwrap(failed.panel)
        XCTAssertNil(panel.downloadProgress)
        XCTAssertEqual(panel.error, "The clip couldn't be downloaded. Check your connection and try again.")
        XCTAssertTrue(panel.canDownload)                       // it can be tried again
        XCTAssertNil(try XCTUnwrap(failed.downloadBegan("B").panel).error)

        let cancelled = secondInCloud.downloadBegan("B").downloadCancelled()
        XCTAssertEqual(cancelled, secondInCloud)
        XCTAssertEqual(secondInCloud.downloadFailed("late"), secondInCloud)
    }

    /// Removing the clip ends the problem; Undo brings the clip back and it is still in iCloud.
    func testRemovingTheClipAndUndoingIt() {
        let without = secondInCloud.previewingWithoutMissing()
        let removed = without.settingSources([clip(c1, 1, "A"), clip(c3, 2, "C")])
        XCTAssertTrue(removed.allAvailable)
        XCTAssertNil(removed.previewingWithoutNotice)          // nothing is left out any more
        let undone = removed.settingSources(threeClips)
        XCTAssertEqual(undone.panel?.title, "Clip 2 is in iCloud")
    }

    func testSeveralProblemsAreHandledOneAtATime() throws {
        let plan = StudioMediaPlan().checked(sources: threeClips,
                                             statuses: ["A": .inCloud, "B": .missing, "C": .available])
        XCTAssertEqual(try XCTUnwrap(plan.panel).title, "Clip 1 is in iCloud")
        XCTAssertEqual(plan.previewingWithoutMissing().previewingWithoutNotice,
                       "2 clips are not in this preview")
        let next = plan.downloadBegan("A").downloadFinished("A")
        XCTAssertEqual(try XCTUnwrap(next.panel).title, "Clip 2 can't be found")
    }

    // MARK: Preview gaps (pure)

    func testThePlayheadIsMappedAcrossALeftOutClip() {
        // timeline: A 0–5, B 5–8 (left out), C 8–12 → the preview plays 9 s
        let gaps = StudioPreviewGaps(slots: [(start: 5, end: 8)])
        XCTAssertEqual(gaps.playableDuration(total: 12), 9)
        XCTAssertEqual(gaps.timelineTime(forPlayerTime: 2), 2)
        XCTAssertEqual(gaps.timelineTime(forPlayerTime: 5), 8)     // the cut: first frame of C
        XCTAssertEqual(gaps.timelineTime(forPlayerTime: 7), 10)
        XCTAssertEqual(gaps.playerTime(forTimelineTime: 2), 2)
        XCTAssertEqual(gaps.playerTime(forTimelineTime: 6.5), 5)   // inside the gap → the cut
        XCTAssertEqual(gaps.playerTime(forTimelineTime: 10), 7)
        XCTAssertEqual(gaps.playerTime(forTimelineTime: 12), 9)
    }

    func testSeveralGapsAndNone() {
        let gaps = StudioPreviewGaps(slots: [(start: 6, end: 8), (start: 0, end: 2), (start: 3, end: 3)])
        XCTAssertEqual(gaps.gaps.count, 2)                         // sorted, the empty one dropped
        XCTAssertEqual(gaps.playableDuration(total: 10), 6)
        XCTAssertEqual(gaps.timelineTime(forPlayerTime: 0), 2)
        XCTAssertEqual(gaps.timelineTime(forPlayerTime: 4), 8)
        XCTAssertEqual(gaps.playerTime(forTimelineTime: 1), 0)
        XCTAssertEqual(gaps.playerTime(forTimelineTime: 5), 3)
        XCTAssertEqual(gaps.playerTime(forTimelineTime: 9), 5)

        let none = StudioPreviewGaps()
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(none.timelineTime(forPlayerTime: 4.2), 4.2)
        XCTAssertEqual(none.playerTime(forTimelineTime: 4.2), 4.2)
        XCTAssertEqual(none.playableDuration(total: 7), 7)
    }

    // MARK: Editor state with missing media and save failures (pure)

    private var loaded: StudioEditorState {
        StudioEditorState().reducing(.previewBuildBegan).reducing(.previewUnavailable(message: nil))
    }

    func testClipMissingIsAPhaseThatCanBeEditedButNotPlayedOrExported() {
        let s = loaded.reducing(.mediaChecked(sources: threeClips,
                                              statuses: ["A": .available, "B": .inCloud, "C": .available]))
        guard case .clipMissing(let panel) = s.phase else { return XCTFail("expected clipMissing") }
        XCTAssertEqual(panel.title, "Clip 2 is in iCloud")
        XCTAssertTrue(s.canEdit)
        XCTAssertFalse(s.canPlay)
        XCTAssertFalse(s.canExport)
        XCTAssertTrue(s.canClose)
        XCTAssertEqual(s.exportBlockedReason, "Export needs all clips")
        XCTAssertEqual(s.reducing(.exportBegan), s)            // refused
        XCTAssertEqual(s.reducing(.bakeBegan), s)

        // known before the first preview has loaded: the panel does not wait for "loading"
        let early = StudioEditorState().reducing(.mediaChecked(sources: threeClips, statuses: ["B": .missing]))
        guard case .clipMissing = early.phase else { return XCTFail("expected clipMissing") }

        let without = s.reducing(.previewWithoutMissing).reducing(.previewBuilt(warning: nil))
        XCTAssertEqual(without.phase, .ready)
        XCTAssertTrue(without.canPlay)
        XCTAssertFalse(without.canExport)                      // still needs all clips

        let downloaded = s.reducing(.downloadBegan("B")).reducing(.downloadProgressed(0.6))
            .reducing(.downloadFinished("B"))
        XCTAssertEqual(downloaded.phase, .ready)
        XCTAssertTrue(downloaded.canExport)
        XCTAssertNil(downloaded.exportBlockedReason)
    }

    func testAFailedSaveIsShownUntilItIsClosedOrASaveWorks() {
        let failed = loaded.reducing(.saveFailed)
        XCTAssertEqual(failed.saveFailure, .edit)
        XCTAssertTrue(failed.saveFailure?.message.contains("couldn't be saved") ?? false)
        XCTAssertTrue(failed.canEdit)                          // the edit is in memory; keep working
        XCTAssertNil(failed.reducing(.saveFailureDismissed).saveFailure)
        XCTAssertNil(failed.reducing(.saveSucceeded).saveFailure)
        XCTAssertEqual(failed.reducing(.saveFailureDismissed).reducing(.saveFailed).saveFailure, .edit)
    }

    /// A bake whose project save failed is not a success: its own state, its own words.
    func testABakeWhoseProjectSaveFailedIsNotReportedAsSaved() {
        XCTAssertEqual(StudioBakeState.afterPhotosWrite(replaced: true, projectSaved: true),
                       .saved(replaced: true))
        XCTAssertEqual(StudioBakeState.afterPhotosWrite(replaced: true, projectSaved: false),
                       .savedProjectNotUpdated(replaced: true))
        XCTAssertEqual(StudioBakeState.afterPhotosWrite(replaced: false, projectSaved: false),
                       .savedProjectNotUpdated(replaced: false))

        let ready = StudioEditorState().reducing(.previewBuildBegan).reducing(.previewBuilt(warning: nil))
        let s = ready.reducing(.bakeBegan).reducing(.bakeSavedProjectNotUpdated(replaced: true))
        XCTAssertEqual(s.bake, .savedProjectNotUpdated(replaced: true))
        XCTAssertEqual(s.phase, .ready)                        // not "finished"
        XCTAssertFalse(s.isBaking)
        XCTAssertEqual(s.reducing(.bakeAcknowledged).bake, .idle)
        XCTAssertEqual(ready.reducing(.bakeSavedProjectNotUpdated(replaced: true)), ready)   // no bake ran

        XCTAssertTrue(StudioBakeState.projectNotUpdatedTitle.contains("saved"))
        XCTAssertTrue(StudioBakeState.projectNotUpdatedTitle.contains("not updated"))
        XCTAssertTrue(StudioBakeState.projectNotUpdatedMessage(replaced: true)
            .hasPrefix("The edited video replaced the original in Photos."))
        XCTAssertTrue(StudioBakeState.projectNotUpdatedMessage(replaced: false)
            .hasPrefix("The edit was saved into the video in Photos."))
        XCTAssertTrue(StudioBakeState.projectNotUpdatedMessage(replaced: false)
            .contains("could not save the change to this project"))
    }

    // MARK: View model (in-memory store, stand-in availability service)

    /// Reports the statuses it was given; a download succeeds, fails, or waits to be cancelled.
    private final class FakeAvailability: StudioMediaAvailabilityChecking, @unchecked Sendable {
        enum Outcome { case succeed, fail, waitForCancel }
        let statuses: [String: StudioAssetStatus]
        let outcome: Outcome
        init(_ statuses: [String: StudioAssetStatus], outcome: Outcome = .succeed) {
            self.statuses = statuses
            self.outcome = outcome
        }
        func statuses(for localIdentifiers: [String]) async -> [String: StudioAssetStatus] {
            statuses.filter { localIdentifiers.contains($0.key) }
        }
        func download(localIdentifier: String,
                      progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
            await progress(0.5)
            switch outcome {
            case .succeed: return
            case .fail: throw URLError(.notConnectedToInternet)
            case .waitForCancel: try await Task.sleep(for: .seconds(30))
            }
        }
    }

    private struct SaveRefused: Error {}

    @MainActor
    private func makeViewModel(_ availability: FakeAvailability)
        throws -> (StudioEditorViewModel, StudioProject, [TimelineClip], ModelContainer) {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let project = StudioProject(sessionID: UUID(), title: "Media")
        let clips = ["A", "B", "C"].enumerated().map { index, local in
            TimelineClip(sessionMediaID: UUID(), localIdentifier: local, isPhoto: false,
                         order: index, trimStart: 0, trimEnd: 4)
        }
        project.clips = clips
        container.mainContext.insert(project)
        let vm = StudioEditorViewModel(project: project, context: container.mainContext,
                                       availability: availability)
        return (vm, project, clips, container)
    }

    /// The panel's title, or nil when the editor is not in the clip-missing phase.
    @MainActor
    private func panelTitle(_ vm: StudioEditorViewModel) -> String? {
        if case .clipMissing(let panel) = vm.state.phase { return panel.title }
        return nil
    }

    @MainActor
    func testAnICloudClipIsAPhaseMarkedOnTheTimelineAndBlocksExportAndBake() async throws {
        let (vm, _, clips, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .inCloud, "C": .available]))
        defer { withExtendedLifetime(container) {} }
        await vm.checkMediaAvailability()

        XCTAssertEqual(panelTitle(vm), "Clip 2 is in iCloud")
        XCTAssertEqual(vm.mediaStatus(of: clips[0]), .available)
        XCTAssertEqual(vm.mediaStatus(of: clips[1]), .inCloud)
        XCTAssertEqual(vm.state.exportBlockedReason, "Export needs all clips")
        XCTAssertFalse(vm.state.canExport)
        XCTAssertFalse(vm.canBakeToOriginal)
        XCTAssertEqual(vm.pipSources.map(\.localIdentifier), ["A", "C"])   // not offered as a PiP
        vm.startExport()
        XCTAssertFalse(vm.isRendering)
        XCTAssertNil(vm.previewPlayer)
    }

    /// "Remove clip from video" is the normal delete: one Undo brings the clip (and the panel) back.
    @MainActor
    func testRemovingTheMissingClipIsUndoable() async throws {
        let (vm, project, clips, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .missing, "C": .available]))
        defer { withExtendedLifetime(container) {} }
        await vm.checkMediaAvailability()
        XCTAssertEqual(panelTitle(vm), "Clip 2 can't be found")

        vm.removeMissingClip()
        XCTAssertEqual(vm.clips.map(\.id), [clips[0].id, clips[2].id])
        XCTAssertEqual(project.clips.count, 2)
        XCTAssertNil(panelTitle(vm))
        XCTAssertNil(vm.state.exportBlockedReason)
        XCTAssertTrue(vm.canUndo)

        vm.undoEdit()
        XCTAssertEqual(vm.clips.map(\.id), clips.map(\.id))
        XCTAssertEqual(panelTitle(vm), "Clip 2 can't be found")
    }

    @MainActor
    func testPreviewWithoutItLeavesThePhaseButKeepsExportOff() async throws {
        let (vm, _, _, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .inCloud, "C": .available]))
        defer { withExtendedLifetime(container) {} }
        await vm.checkMediaAvailability()

        vm.previewWithoutMissingClips()
        XCTAssertNil(panelTitle(vm))
        XCTAssertEqual(vm.state.media.previewingWithoutNotice, "Clip 2 is not in this preview")
        XCTAssertFalse(vm.state.canExport)
        vm.showMissingClipOptions()
        XCTAssertEqual(panelTitle(vm), "Clip 2 is in iCloud")
    }

    @MainActor
    func testDownloadingTheClipEndsThePhase() async throws {
        let (vm, _, clips, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .inCloud, "C": .available]))
        defer { withExtendedLifetime(container) {} }
        await vm.checkMediaAvailability()

        vm.downloadMissingClip()
        guard case .clipMissing(let panel) = vm.state.phase else { return XCTFail("expected clipMissing") }
        XCTAssertEqual(panel.downloadProgress, 0)
        vm.downloadMissingClip()                               // a second tap does nothing
        await vm.downloadTask?.value
        XCTAssertNil(vm.downloadTask)
        XCTAssertNil(panelTitle(vm))
        XCTAssertEqual(vm.mediaStatus(of: clips[1]), .available)
        XCTAssertNil(vm.state.exportBlockedReason)
    }

    @MainActor
    func testAFailedDownloadIsReportedAndACancelledOneIsNot() async throws {
        let (failing, _, _, c1) = try makeViewModel(
            FakeAvailability(["B": .inCloud], outcome: .fail))
        defer { withExtendedLifetime(c1) {} }
        await failing.checkMediaAvailability()
        failing.downloadMissingClip()
        await failing.downloadTask?.value
        guard case .clipMissing(let panel) = failing.state.phase else { return XCTFail("expected clipMissing") }
        XCTAssertEqual(panel.error, StudioMediaPlan.downloadFailedMessage)
        XCTAssertNil(panel.downloadProgress)

        let (waiting, _, _, c2) = try makeViewModel(
            FakeAvailability(["B": .inCloud], outcome: .waitForCancel))
        defer { withExtendedLifetime(c2) {} }
        await waiting.checkMediaAvailability()
        waiting.downloadMissingClip()
        let task = try XCTUnwrap(waiting.downloadTask)
        await Task.yield()
        waiting.cancelClipDownload()
        guard case .clipMissing(let after) = waiting.state.phase else { return XCTFail("expected clipMissing") }
        XCTAssertNil(after.downloadProgress)                   // the bar goes at once
        XCTAssertNil(after.error)
        await task.value
        XCTAssertNil(waiting.state.media.downloadError)
        XCTAssertEqual(waiting.state.media.status(of: "B"), .inCloud)
    }

    /// A save that fails is reported, the edit stays in memory and in undo, and the next save
    /// that works clears the message.
    @MainActor
    func testAFailedSaveIsReportedAndTheEditIsKept() throws {
        let (vm, _, _, container) = try makeViewModel(FakeAvailability([:]))
        defer { withExtendedLifetime(container) {} }
        vm.rename("Saved")
        XCTAssertNil(vm.state.saveFailure)

        vm.saver = { _ in throw SaveRefused() }
        vm.rename("Not saved")
        XCTAssertEqual(vm.state.saveFailure, .edit)
        XCTAssertEqual(vm.title, "Not saved")                  // still in memory
        XCTAssertTrue(vm.canUndo)
        vm.dismissSaveFailure()
        XCTAssertNil(vm.state.saveFailure)
        vm.addText("Again")
        XCTAssertEqual(vm.state.saveFailure, .edit)            // a new failure shows again

        vm.saver = { try $0.save() }
        vm.rename("Saved again")
        XCTAssertNil(vm.state.saveFailure)                     // cleared by the save that worked
        XCTAssertEqual(vm.overlays.count, 1)
    }
}
