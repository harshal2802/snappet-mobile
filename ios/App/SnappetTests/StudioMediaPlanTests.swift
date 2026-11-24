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

    // MARK: Review fixes (prompt 303, pure)

    /// A failed download's message belongs to its clip. After that clip is removed, the next
    /// problem's panel does not open with it; nor does another clip's panel while both remain.
    func testADownloadErrorIsTiedToTheClipThatFailed() throws {
        let plan = StudioMediaPlan().checked(sources: threeClips,
                                             statuses: ["A": .inCloud, "B": .inCloud, "C": .available])
        let failed = plan.downloadBegan("A").downloadFailed(StudioMediaPlan.downloadFailedMessage)
        XCTAssertEqual(try XCTUnwrap(failed.panel).error, StudioMediaPlan.downloadFailedMessage)
        XCTAssertEqual(failed.downloadFailure?.localIdentifier, "A")

        // clip 1 removed: the panel is now about clip B, with no error
        let removed = failed.settingSources([clip(c2, 1, "B"), clip(c3, 2, "C")])
        let next = try XCTUnwrap(removed.panel)
        XCTAssertEqual(next.problem.source.localIdentifier, "B")
        XCTAssertNil(next.error)
        XCTAssertNil(removed.downloadError)
        // Undo brings clip 1 back; the old error does not come back with it
        XCTAssertNil(try XCTUnwrap(removed.settingSources(threeClips).panel).error)

        // a failure of B while the panel is about A is not shown on A's panel
        let other = plan.downloadBegan("B").downloadFailed("B failed")
        XCTAssertEqual(try XCTUnwrap(other.panel).problem.source.localIdentifier, "A")
        XCTAssertNil(try XCTUnwrap(other.panel).error)
        XCTAssertEqual(other.downloadError, "B failed")
        // trying A again does not clear B's message; downloading B does
        XCTAssertEqual(other.downloadBegan("A").downloadError, "B failed")
        XCTAssertNil(other.downloadBegan("B").downloadError)
    }

    /// Progress carries its download's number: a late report from an earlier download does not
    /// move the next download's bar.
    func testALateProgressReportDoesNotMoveTheNextDownloadsBar() {
        let first = secondInCloud.downloadBegan("B", request: 1).downloadProgressed(0.4, request: 1)
        XCTAssertEqual(first.download?.progress, 0.4)
        let second = first.downloadCancelled().downloadBegan("B", request: 2)
        XCTAssertEqual(second.download?.progress, 0)
        XCTAssertEqual(second.downloadProgressed(0.9, request: 1), second)        // the late report
        XCTAssertEqual(second.downloadProgressed(0.1, request: 2).download?.progress, 0.1)
        XCTAssertEqual(second.downloadProgressed(0.1, request: 2).download?.request, 2)

        let s = StudioEditorState()
            .reducing(.mediaChecked(sources: threeClips, statuses: ["B": .inCloud]))
            .reducing(.downloadBegan("B", request: 7))
        XCTAssertEqual(s.reducing(.downloadProgressed(0.5, request: 6)), s)
        XCTAssertEqual(s.reducing(.downloadProgressed(0.5, request: 7)).media.download?.progress, 0.5)
    }

    /// A picture-in-picture whose window starts at or after the end of the timeline is not
    /// drawn, so it is not a source and cannot block the export.
    func testAPictureInPicturePastTheEndIsNotASource() {
        let a = TimelineClip(sessionMediaID: nil, localIdentifier: "A", isPhoto: false, order: 0, trimEnd: 4)
        let photo = TimelineClip(sessionMediaID: nil, localIdentifier: "PH", isPhoto: true, order: 1)
        let inside = OverlayItem(kind: .video, content: "P1", startSec: 1, endSec: 3)
        let crossing = OverlayItem(kind: .video, content: "P2", startSec: 3, endSec: 30)
        let past = OverlayItem(kind: .video, content: "P3", startSec: 9, endSec: 12)
        let text = OverlayItem(kind: .text, content: "Hi", startSec: 0, endSec: 2)
        let overlays = [inside, crossing, past, text]

        let sources = StudioMediaPlan.sources(clips: [a, photo], overlays: overlays, total: 7)
        XCTAssertEqual(sources.map(\.localIdentifier), ["A", "P1", "P2"])
        XCTAssertEqual(sources.first?.role, .clip(id: a.id, number: 1))
        // length not known: nothing is left out on a guess
        XCTAssertEqual(StudioMediaPlan.sources(clips: [a], overlays: overlays, total: nil).count, 4)
        XCTAssertEqual(StudioMediaPlan.sources(clips: [a], overlays: overlays, total: 0).count, 4)

        // P3 in iCloud blocks nothing while it is past the end, and does once the timeline reaches it
        let statuses: [String: StudioAssetStatus] = ["A": .available, "P1": .available,
                                                     "P2": .available, "P3": .inCloud]
        XCTAssertTrue(StudioMediaPlan().checked(sources: sources, statuses: statuses).allAvailable)
        let longer = StudioMediaPlan.sources(clips: [a, photo], overlays: overlays, total: 10)
        XCTAssertNotNil(StudioMediaPlan().checked(sources: longer, statuses: statuses).exportBlockedReason)
    }

    /// Nothing is known until the service has reported once; then a preview may be built.
    func testNoPreviewIsBuiltBeforeTheFirstAvailabilityResult() {
        XCTAssertFalse(StudioMediaPlan().isChecked)
        XCTAssertFalse(StudioMediaPlan().settingSources(threeClips).isChecked)   // an edit is not a result
        XCTAssertTrue(secondInCloud.isChecked)

        let opening = StudioEditorState().reducing(.mediaSourcesChanged(threeClips))
        XCTAssertFalse(opening.canBuildPreview)
        XCTAssertEqual(opening.phase, .loading)
        XCTAssertTrue(opening.showsBuildingPreview)             // not "couldn't be made"
        XCTAssertFalse(opening.isBuildingPreview)
        let known = opening.reducing(.mediaChecked(sources: threeClips, statuses: [:]))
        XCTAssertTrue(known.canBuildPreview)

        // after the first load the text follows the build flag again
        let failed = known.reducing(.previewBuildBegan).reducing(.previewUnavailable(message: nil))
        XCTAssertFalse(failed.showsBuildingPreview)
        XCTAssertTrue(failed.reducing(.previewBuildBegan).showsBuildingPreview)
    }

    /// The bake's alert already says the project was not saved; the save banner is not shown too.
    func testABakeWhoseSaveFailedShowsOneMessage() {
        let ready = StudioEditorState().reducing(.previewBuildBegan).reducing(.previewBuilt(warning: nil))
        let s = ready.reducing(.bakeBegan).reducing(.saveFailed)
            .reducing(.bakeSavedProjectNotUpdated(replaced: false))
        XCTAssertEqual(s.bake, .savedProjectNotUpdated(replaced: false))
        XCTAssertNil(s.saveFailure)
        XCTAssertTrue(StudioBakeState.recordsUnreadableMessage.contains("nothing was changed"))
    }

    /// "Preview without it": what the composer is handed is on the PREVIEW's clock. A
    /// picture-in-picture after the left-out clip moves earlier by that clip's length — the same
    /// mapping as the playhead — with its keyframes; so does where added music starts.
    @MainActor
    func testPreviewWithoutItMovesTimedItemsAcrossTheGap() throws {
        let a = TimelineClip(sessionMediaID: nil, localIdentifier: "A", isPhoto: false, order: 0, trimEnd: 5)
        let b = TimelineClip(sessionMediaID: nil, localIdentifier: "B", isPhoto: false, order: 1, trimEnd: 3)
        let c = TimelineClip(sessionMediaID: nil, localIdentifier: "C", isPhoto: false, order: 2, trimEnd: 4)
        let keys = [StudioKeyframe(timeSec: 9, value: 0, easing: .linear),
                    StudioKeyframe(timeSec: 11, value: 1, easing: .linear)]
        let after = OverlayItem(kind: .video, content: "A", startSec: 9, endSec: 11, opacityKeyframes: keys)
        let across = OverlayItem(kind: .video, content: "C", startSec: 4, endSec: 10)
        let inside = OverlayItem(kind: .video, content: "A", startSec: 5.5, endSec: 7.5)
        let before = OverlayItem(kind: .video, content: "C", startSec: 1, endSec: 2)
        let fromMissing = OverlayItem(kind: .video, content: "B", startSec: 0, endSec: 2)
        let text = OverlayItem(kind: .text, content: "Hi", startSec: 8, endSec: 12)
        var snapshot = StudioProjectSnapshot(StudioProject(sessionID: UUID(), title: "T"))
        snapshot.clips = [a, b, c]
        snapshot.overlays = [after, across, inside, before, fromMissing, text]
        snapshot.audioTracks = [AudioTrack(kind: .music, sourceRef: "m", startSec: 10)]

        // timeline: A 0–5, B 5–8 (left out), C 8–12
        let gaps = StudioPreviewGaps(slots: [(start: 5, end: 8)])
        let playable = gaps.playable(snapshot, unavailable: ["B"])
        XCTAssertEqual(playable.clips.map(\.id), [a.id, c.id])
        XCTAssertEqual(playable.overlays.map(\.id), [after.id, across.id, before.id, text.id])
        let moved = try XCTUnwrap(playable.overlays.first { $0.id == after.id })
        XCTAssertEqual(moved.startSec, gaps.playerTime(forTimelineTime: 9))      // the playhead's mapping
        XCTAssertEqual(moved.startSec, 6)
        XCTAssertEqual(moved.endSec, 8)
        XCTAssertEqual(moved.opacityKeyframes.map(\.timeSec), [6, 8])
        let spanning = try XCTUnwrap(playable.overlays.first { $0.id == across.id })
        XCTAssertEqual(spanning.startSec, 4)
        XCTAssertEqual(spanning.endSec, 7)                                        // shorter by the gap
        let early = try XCTUnwrap(playable.overlays.first { $0.id == before.id })
        XCTAssertEqual(early.startSec, 1)
        XCTAssertEqual(early.endSec, 2)
        XCTAssertEqual(playable.overlays.first { $0.id == text.id }?.startSec, 5)
        XCTAssertEqual(playable.audioTracks.first?.startSec, 7)
        XCTAssertNil(gaps.playerWindow(start: 5.5, end: 7.5))
        XCTAssertEqual(gaps.playerWindow(start: 9, end: 11)?.start, 6)

        // nothing left out: the snapshot is handed over as it is
        XCTAssertEqual(StudioPreviewGaps().playable(snapshot, unavailable: []), snapshot)
        // only a picture-in-picture source is missing: it goes, no time moves
        let pipOnly = StudioPreviewGaps().playable(snapshot, unavailable: ["C"])
        XCTAssertEqual(pipOnly.overlays.map(\.id), [after.id, inside.id, fromMissing.id, text.id])
        XCTAssertEqual(pipOnly.overlays.first?.startSec, 9)
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

        let downloaded = s.reducing(.downloadBegan("B", request: 1))
            .reducing(.downloadProgressed(0.6, request: 1)).reducing(.downloadFinished("B"))
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

    /// Held closed until `open()`: lets a test keep the availability check from returning.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        func open() {
            let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            resumed.forEach { $0.resume() }
        }
    }

    /// Reports the statuses it was given; a download succeeds, fails, or waits to be cancelled.
    private final class FakeAvailability: StudioMediaAvailabilityChecking, @unchecked Sendable {
        enum Outcome { case succeed, fail, waitForCancel }
        let statuses: [String: StudioAssetStatus]
        let outcome: Outcome
        /// When set, `statuses(for:)` does not return until the gate is opened.
        let gate: Gate?
        init(_ statuses: [String: StudioAssetStatus], outcome: Outcome = .succeed, gate: Gate? = nil) {
            self.statuses = statuses
            self.outcome = outcome
            self.gate = gate
        }
        func statuses(for localIdentifiers: [String]) async -> [String: StudioAssetStatus] {
            await gate?.wait()
            return statuses.filter { localIdentifiers.contains($0.key) }
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

    /// Three clips A, B, C. `trimEnd` nil = never trimmed. `recorded` adds each clip's
    /// `SessionMedia` row with that length (the length Snappet stored when the video was added).
    @MainActor
    private func makeViewModel(_ availability: FakeAvailability, trimEnd: Double? = 4,
                               recorded: Double? = nil)
        throws -> (StudioEditorViewModel, StudioProject, [TimelineClip], ModelContainer) {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let project = StudioProject(sessionID: UUID(), title: "Media")
        let clips = ["A", "B", "C"].enumerated().map { index, local in
            TimelineClip(sessionMediaID: UUID(), localIdentifier: local, isPhoto: false,
                         order: index, trimStart: 0, trimEnd: trimEnd)
        }
        project.clips = clips
        container.mainContext.insert(project)
        if let recorded {
            for clip in clips {
                container.mainContext.insert(SessionMedia(
                    id: try XCTUnwrap(clip.sessionMediaID), sessionID: project.sessionID,
                    localIdentifier: clip.localIdentifier, kind: .video, offsetSec: 0,
                    durationSec: recorded))
            }
        }
        let vm = StudioEditorViewModel(project: project, context: container.mainContext,
                                       availability: availability)
        return (vm, project, clips, container)
    }

    /// The stand-in for the two Photos writes of a bake.
    @MainActor
    private final class FakeBaker: ClipBaking {
        var saved: [String] = []
        var replaced: [String] = []
        func saveToOriginal(renderedURL: URL, localIdentifier: String, projectID: UUID) async throws {
            saved.append(localIdentifier)
        }
        func replaceOriginal(renderedURL: URL, oldLocalIdentifier: String) async throws -> String {
            replaced.append(oldLocalIdentifier)
            return "NEW"
        }
    }

    /// What the stand-in duration reader returns, changeable while a test runs.
    @MainActor
    private final class Lengths {
        var byAsset: [String: Double]
        init(_ byAsset: [String: Double]) { self.byAsset = byAsset }
    }

    /// A project that can be baked: one video clip of asset "A" (trimmed to 4 s of 9), its
    /// `SessionMedia` row unless `withRow` is false, a stand-in render (an empty temp file) and
    /// a stand-in duration reader. `renders` counts the renders.
    @MainActor
    private struct BakeFixture {
        let vm: StudioEditorViewModel
        let project: StudioProject
        let clip: TimelineClip
        let media: SessionMedia
        let lengths: Lengths
        let renders: Lengths
        let container: ModelContainer
    }

    @MainActor
    private func makeBakeFixture(status: StudioAssetStatus = .available, withRow: Bool = true) throws -> BakeFixture {
        let container = try ModelContainer(
            for: Schema(SnappetSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let project = StudioProject(sessionID: UUID(), title: "Bake")
        let media = SessionMedia(sessionID: project.sessionID, localIdentifier: "A", kind: .video,
                                 offsetSec: 10, durationSec: 9)
        let clip = TimelineClip(sessionMediaID: media.id, localIdentifier: "A", isPhoto: false,
                                order: 0, trimStart: 0, trimEnd: 4)
        project.clips = [clip]
        container.mainContext.insert(project)
        if withRow { container.mainContext.insert(media) }
        let vm = StudioEditorViewModel(project: project, context: container.mainContext,
                                       availability: FakeAvailability(["A": status]))
        let lengths = Lengths(["A": 9])
        let renders = Lengths([:])
        vm.sourceDurationLoader = { lengths.byAsset[$0] }
        vm.renderOverride = {
            renders.byAsset["count", default: 0] += 1
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("studio303-bake-\(UUID().uuidString).mp4")
            try Data().write(to: url)
            return url
        }
        return BakeFixture(vm: vm, project: project, clip: clip, media: media, lengths: lengths,
                           renders: renders, container: container)
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
        // The whole opening, so the first load HAS ended: export is then off because of the
        // clip, not because nothing has loaded yet (which is what this test used to see).
        await vm.onAppear()
        XCTAssertTrue(vm.state.previewLoaded)

        XCTAssertEqual(panelTitle(vm), "Clip 2 is in iCloud")
        XCTAssertEqual(vm.mediaStatus(of: clips[0]), .available)
        XCTAssertEqual(vm.mediaStatus(of: clips[1]), .inCloud)
        XCTAssertEqual(vm.state.exportBlockedReason, "Export needs all clips")
        XCTAssertFalse(vm.state.canExport)
        XCTAssertEqual(vm.pipSources.map(\.localIdentifier), ["A", "C"])   // not offered as a PiP
        vm.startExport()
        XCTAssertFalse(vm.isRendering)
        XCTAssertEqual(vm.exportState, .idle)
        XCTAssertNil(vm.previewPlayer)

        // The same project with every clip on the phone CAN export: the block above is the clip's.
        let (ready, _, _, readyContainer) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .available, "C": .available]))
        defer { withExtendedLifetime(readyContainer) {} }
        await ready.onAppear()
        XCTAssertTrue(ready.state.canExport)
        XCTAssertNil(ready.state.exportBlockedReason)
        ready.startExport()
        XCTAssertTrue(ready.isRendering)
        ready.cancelExport()
        for _ in 0 ..< 500 where ready.isRendering { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(ready.isRendering)
    }

    /// "Save to original" is not offered, and refuses, while the clip is not on this phone. The
    /// same project with the clip here offers it.
    @MainActor
    func testBakeIsNotOfferedWhileTheClipIsInICloud() async throws {
        let cloud = try makeBakeFixture(status: .inCloud)
        defer { withExtendedLifetime(cloud.container) {} }
        await cloud.vm.onAppear()
        XCTAssertTrue(cloud.vm.state.previewLoaded)
        XCTAssertFalse(cloud.vm.canBakeToOriginal)
        let baker = FakeBaker()
        await cloud.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(cloud.vm.bakeState, .idle)
        XCTAssertTrue(baker.saved.isEmpty)
        XCTAssertNil(cloud.renders.byAsset["count"])

        let here = try makeBakeFixture()
        defer { withExtendedLifetime(here.container) {} }
        await here.vm.onAppear()
        XCTAssertTrue(here.vm.canBakeToOriginal)
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
        await vm.onAppear()

        vm.previewWithoutMissingClips()
        await vm.previewBuildsFinished()
        // Loaded, no panel, nothing rendering: the ONLY thing keeping export off is the clip.
        XCTAssertTrue(vm.state.previewLoaded)
        XCTAssertEqual(vm.state.phase, .ready)
        XCTAssertNil(panelTitle(vm))
        XCTAssertEqual(vm.state.media.previewingWithoutNotice, "Clip 2 is not in this preview")
        XCTAssertFalse(vm.state.canExport)
        XCTAssertEqual(vm.state.exportBlockedReason, "Export needs all clips")
        vm.startExport()
        XCTAssertFalse(vm.isRendering)
        XCTAssertEqual(vm.exportState, .idle)
        vm.showMissingClipOptions()
        await vm.previewBuildsFinished()
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

    // MARK: View model — review fixes (prompt 303)

    /// A never-trimmed clip that is not on this phone has its recorded length on the timeline,
    /// not 0 s; after the download its real length replaces it.
    @MainActor
    func testAClipInICloudHasItsRecordedLengthUntilItIsDownloaded() async throws {
        let (vm, _, clips, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .inCloud, "C": .available]), trimEnd: nil, recorded: 6)
        defer { withExtendedLifetime(container) {} }
        vm.sourceDurationLoader = { ["A": 5.0, "B": 7.0, "C": 3.0][$0] }
        await vm.onAppear()

        XCTAssertEqual(vm.sourceDurations[clips[0].id], 5)             // on the phone: the real length
        XCTAssertNil(vm.sourceDurations[clips[1].id])                  // not read: it is in iCloud
        XCTAssertEqual(vm.outputDuration(of: clips[1]), 6)             // recorded, not 0
        XCTAssertEqual(vm.placedClips.map(\.durationSec), [5, 6, 3])
        XCTAssertEqual(vm.totalDuration, 14)
        XCTAssertTrue(vm.canTrim(clips[1]))

        vm.downloadMissingClip()
        await vm.downloadTask?.value
        XCTAssertEqual(vm.sourceDurations[clips[1].id], 7)             // refreshed after the download
        XCTAssertEqual(vm.totalDuration, 15)
    }

    /// With no length known at all, a trim is refused: it used to store `trimEnd = 0`, which
    /// stayed after the video was downloaded.
    @MainActor
    func testATrimIsRefusedWhileTheSourceLengthIsUnknown() async throws {
        let (vm, project, clips, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .inCloud, "C": .available]), trimEnd: nil)
        defer { withExtendedLifetime(container) {} }
        vm.sourceDurationLoader = { ["A": 5.0, "B": 7.0, "C": 3.0][$0] }
        await vm.onAppear()

        vm.select(clips[1].id)
        XCTAssertFalse(vm.canTrim(clips[1]))
        vm.trimSelected(startSeconds: nil, endSeconds: 2)
        vm.trimSelected(startSeconds: 1, endSeconds: nil)
        XCTAssertNil(vm.clips[1].trimEnd)
        XCTAssertEqual(vm.clips[1].trimStart, 0)
        XCTAssertNil(project.clips.first { $0.id == clips[1].id }?.trimEnd)
        XCTAssertFalse(vm.canUndo)

        // a clip whose length is known trims as before
        vm.select(clips[0].id)
        XCTAssertTrue(vm.canTrim(clips[0]))
        vm.trimSelected(startSeconds: nil, endSeconds: 2)
        XCTAssertEqual(vm.clips[0].trimEnd, 2)

        // after the download the length is known and the trim works, against the real length
        vm.downloadMissingClip()
        await vm.downloadTask?.value
        vm.select(clips[1].id)
        XCTAssertTrue(vm.canTrim(vm.clips[1]))
        vm.trimSelected(startSeconds: nil, endSeconds: 100)
        XCTAssertEqual(vm.clips[1].trimEnd, 7)
    }

    /// An edit made before the first availability result does not start a preview build (the
    /// composer would download an iCloud clip without a word). The opening builds it afterwards.
    @MainActor
    func testAnEditBeforeTheAvailabilityResultDoesNotBuildAPreview() async throws {
        let gate = Gate()
        let (vm, _, clips, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .inCloud, "C": .available], gate: gate))
        defer { withExtendedLifetime(container) {} }
        let opening = Task { await vm.onAppear() }

        vm.select(clips[0].id)
        vm.setSelectedSpeed(2)                                 // an edit that rebuilds the preview
        await vm.previewBuildsFinished()
        XCTAssertEqual(vm.clips[0].speed, 2)                   // the edit itself is made
        XCTAssertEqual(vm.previewBuildCount, 0)
        XCTAssertFalse(vm.state.canBuildPreview)
        XCTAssertEqual(vm.state.phase, .loading)
        XCTAssertTrue(vm.state.showsBuildingPreview)

        gate.open()
        await opening.value
        XCTAssertEqual(vm.previewBuildCount, 1)                // the opening's own build
        XCTAssertEqual(panelTitle(vm), "Clip 2 is in iCloud")
        vm.setSelectedSpeed(1)
        await vm.previewBuildsFinished()
        XCTAssertEqual(vm.previewBuildCount, 2)                // edits build again once it is known
    }

    /// A picture-in-picture past the end of the timeline whose source is in iCloud does not put
    /// the editor in the clip-missing phase or block the export.
    @MainActor
    func testAPictureInPicturePastTheEndDoesNotBlockExport() async throws {
        let (vm, project, _, container) = try makeViewModel(
            FakeAvailability(["A": .available, "B": .available, "C": .available, "P": .inCloud]))
        defer { withExtendedLifetime(container) {} }
        let past = OverlayItem(kind: .video, content: "P", startSec: 20, endSec: 25)   // timeline is 12 s
        project.overlays = [past]
        let fresh = StudioEditorViewModel(project: project, context: container.mainContext,
                                          availability: FakeAvailability(["A": .available, "B": .available,
                                                                          "C": .available, "P": .inCloud]))
        _ = vm
        await fresh.onAppear()
        XCTAssertNil(panelTitle(fresh))
        XCTAssertTrue(fresh.state.canExport)

        // moved inside the timeline it is a source, and it is known to be in iCloud
        fresh.setOverlayTimeRange(past.id, start: 2, end: 6)
        XCTAssertEqual(panelTitle(fresh), "A picture-in-picture clip is in iCloud")
        XCTAssertFalse(fresh.state.canExport)
    }

    /// A bake whose Photos write worked and whose project save failed ends as
    /// `savedProjectNotUpdated`, with ONE message: the bake's alert, not the save banner too.
    @MainActor
    func testABakeWhoseSaveFailsIsReportedAsNotUpdated() async throws {
        for replace in [false, true] {
            let f = try makeBakeFixture()
            defer { withExtendedLifetime(f.container) {} }
            await f.vm.onAppear()
            let baker = FakeBaker()
            f.vm.saver = { _ in throw SaveRefused() }
            await f.vm.bake(replaceOriginal: replace, service: baker)

            XCTAssertEqual(f.vm.bakeState, .savedProjectNotUpdated(replaced: replace))
            XCTAssertEqual(replace ? baker.replaced : baker.saved, ["A"])       // Photos has the video
            XCTAssertEqual(f.renders.byAsset["count"], 1)
            XCTAssertNil(f.vm.state.saveFailure, "one message, not two")
            XCTAssertFalse(f.vm.isBaking)
            await f.vm.previewBuildsFinished()
        }
    }

    /// The same bake with a save that works is `saved`; the baked clip's length is read again
    /// (the asset's video changed under the same identifier), not kept from before the bake.
    @MainActor
    func testAfterABakeTheClipsLengthIsReadAgain() async throws {
        let f = try makeBakeFixture()
        defer { withExtendedLifetime(f.container) {} }
        await f.vm.onAppear()
        XCTAssertEqual(f.vm.sourceDurations[f.clip.id], 9)
        XCTAssertEqual(f.vm.totalDuration, 4)                  // trimmed to 4 of 9

        f.lengths.byAsset["A"] = 4                             // the baked video is the 4 s that were kept
        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: false, service: baker)
        XCTAssertEqual(f.vm.bakeState, .saved(replaced: false))
        XCTAssertTrue(f.media.isBaked)
        await f.vm.previewBuildsFinished()

        XCTAssertNil(f.vm.clips.first?.trimEnd)                // the trim is in the pixels now
        XCTAssertEqual(f.vm.sourceDurations[f.clip.id], 4)     // not the 9 s from before the bake
        XCTAssertEqual(f.vm.totalDuration, 4)

        // "Replace original": the clip points at the new asset and its length is that asset's
        let r = try makeBakeFixture()
        defer { withExtendedLifetime(r.container) {} }
        await r.vm.onAppear()
        r.lengths.byAsset["NEW"] = 4
        await r.vm.bake(replaceOriginal: true, service: baker)
        XCTAssertEqual(r.vm.bakeState, .saved(replaced: true))
        await r.vm.previewBuildsFinished()
        XCTAssertEqual(r.vm.clips.first?.localIdentifier, "NEW")
        XCTAssertEqual(r.media.localIdentifier, "NEW")
        XCTAssertEqual(r.vm.sourceDurations[r.clip.id], 4)
        XCTAssertEqual(r.vm.totalDuration, 4)
    }

    /// The video's records are read before anything is rendered or written. If there are none
    /// the bake is refused with a message and nothing changes.
    @MainActor
    func testABakeIsRefusedWhenTheVideosRecordsCannotBeRead() async throws {
        let f = try makeBakeFixture(withRow: false)
        defer { withExtendedLifetime(f.container) {} }
        await f.vm.onAppear()
        let baker = FakeBaker()
        await f.vm.bake(replaceOriginal: true, service: baker)

        XCTAssertEqual(f.vm.bakeState, .failed(StudioBakeState.recordsUnreadableMessage))
        XCTAssertTrue(baker.replaced.isEmpty)                  // Photos was not touched
        XCTAssertTrue(baker.saved.isEmpty)
        XCTAssertNil(f.renders.byAsset["count"])               // nothing was rendered
        XCTAssertEqual(f.vm.clips.first?.trimEnd, 4)           // the project is as it was
        XCTAssertEqual(f.vm.clips.first?.localIdentifier, "A")
        XCTAssertFalse(f.vm.isBaking)
        XCTAssertTrue(f.vm.canEdit)
    }
}
