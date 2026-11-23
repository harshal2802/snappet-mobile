import XCTest
@testable import Snappet

/// Unit tests for the **pure** B5 export → share / save-to-Photos state machine — no device, no
/// AVFoundation/PhotoKit/UIKit. The actual export/save/share are device-only (the sim can't render
/// a real video or write Photos), so these prove the **transition logic** that drives the UI in
/// both the B3 clip editor and the B4 highlight reel (decisions.md 2026-06-01, B5).
final class ExportShareStateTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/snappet-test.mp4")

    // MARK: - Happy path: idle → exporting → exported → saving → saved

    func testFullFlowReachesSaved() {
        var s = ExportShareState.idle
        XCTAssertNil(s.exportedURL)
        XCTAssertFalse(s.isBusy)

        s = s.beginningExport()
        XCTAssertEqual(s, .exporting(progress: 0))
        XCTAssertTrue(s.isBusy)
        XCTAssertNil(s.exportedURL)

        s = s.exportSucceeded(url)
        XCTAssertEqual(s, .exported(url))
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.exportedURL, url)

        s = s.beginningSave()
        XCTAssertEqual(s, .saving(url))
        XCTAssertTrue(s.isBusy)
        XCTAssertEqual(s.exportedURL, url, "the file URL is preserved while saving")

        s = s.saveSucceeded()
        XCTAssertEqual(s, .saved(url))
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.exportedURL, url, "the saved file URL is still available to share")
    }

    // MARK: - URL is carried through every post-export state

    func testExportedURLAvailableForShareAndSave() {
        XCTAssertEqual(ExportShareState.exported(url).exportedURL, url)
        XCTAssertEqual(ExportShareState.saving(url).exportedURL, url)
        XCTAssertEqual(ExportShareState.saved(url).exportedURL, url)
    }

    func testNoURLBeforeExport() {
        XCTAssertNil(ExportShareState.idle.exportedURL)
        XCTAssertNil(ExportShareState.exporting(progress: 0.5).exportedURL)
        XCTAssertNil(ExportShareState.failed("boom").exportedURL)
    }

    // MARK: - Save guarded on having a rendered file

    func testBeginningSaveNoopsWithoutAnExport() {
        XCTAssertEqual(ExportShareState.idle.beginningSave(), .idle,
                       "can't save before an export produced a file")
        XCTAssertEqual(ExportShareState.exporting(progress: 0.5).beginningSave(),
                       .exporting(progress: 0.5))
        XCTAssertEqual(ExportShareState.failed("x").beginningSave(), .failed("x"))
    }

    func testSaveSucceededNoopsWithoutAnExport() {
        XCTAssertEqual(ExportShareState.idle.saveSucceeded(), .idle)
    }

    // MARK: - isBusy gates the UI actions

    func testIsBusyOnlyDuringWork() {
        XCTAssertTrue(ExportShareState.exporting(progress: 0).isBusy)
        XCTAssertTrue(ExportShareState.exporting(progress: 1).isBusy)
        XCTAssertTrue(ExportShareState.saving(url).isBusy)
        XCTAssertFalse(ExportShareState.idle.isBusy)
        XCTAssertFalse(ExportShareState.exported(url).isBusy)
        XCTAssertFalse(ExportShareState.saved(url).isBusy)
        XCTAssertFalse(ExportShareState.failed("x").isBusy)
    }

    // MARK: - Failure + recovery (re-export from any state)

    func testFailureFromExportAndRecovery() {
        var s = ExportShareState.idle.beginningExport().failed("export blew up")
        XCTAssertEqual(s, .failed("export blew up"))
        // Re-exporting from a failure is allowed.
        s = s.beginningExport()
        XCTAssertEqual(s, .exporting(progress: 0))
        s = s.exportSucceeded(url)
        XCTAssertEqual(s, .exported(url))
    }

    func testReExportReplacesAPriorRender() {
        let old = URL(fileURLWithPath: "/tmp/old.mp4")
        let new = URL(fileURLWithPath: "/tmp/new.mp4")
        var s = ExportShareState.exported(old)
        s = s.beginningExport().exportSucceeded(new)
        XCTAssertEqual(s.exportedURL, new, "a fresh export supersedes the previous file")
    }

    // MARK: - Progress (prompt 298)

    func testProgressIsReportedOnlyWhileExporting() {
        var s = ExportShareState.idle.beginningExport()
        XCTAssertEqual(s.exportProgress, 0)
        s = s.exportProgressed(0.25)
        XCTAssertEqual(s, .exporting(progress: 0.25))
        XCTAssertEqual(s.exportProgress, 0.25)
        XCTAssertNil(ExportShareState.idle.exportProgress)
        XCTAssertNil(ExportShareState.exported(url).exportProgress)
        XCTAssertNil(ExportShareState.failed("x").exportProgress)
    }

    func testProgressNeverMovesBackAndStaysInRange() {
        var s = ExportShareState.exporting(progress: 0.6)
        s = s.exportProgressed(0.4)
        XCTAssertEqual(s, .exporting(progress: 0.6), "a late lower report does not move the bar back")
        XCTAssertEqual(s.exportProgressed(1.7), .exporting(progress: 1))
        XCTAssertEqual(ExportShareState.exporting(progress: 0).exportProgressed(-3),
                       .exporting(progress: 0))
        XCTAssertEqual(s.exportProgressed(.nan), s)
        XCTAssertEqual(s.exportProgressed(.infinity), s)
    }

    func testALateProgressReportChangesNothing() {
        XCTAssertEqual(ExportShareState.idle.exportProgressed(0.9), .idle, "after a cancel")
        XCTAssertEqual(ExportShareState.exported(url).exportProgressed(0.9), .exported(url))
        XCTAssertEqual(ExportShareState.failed("x").exportProgressed(0.9), .failed("x"))
    }

    func testANewExportStartsAtZero() {
        XCTAssertEqual(ExportShareState.exporting(progress: 0.8).beginningExport(),
                       .exporting(progress: 0))
        XCTAssertEqual(ExportShareState.exported(url).beginningExport(), .exporting(progress: 0))
    }

    func testPercentLabelRoundsDown() {
        XCTAssertEqual(ExportShareState.exporting(progress: 0).exportPercentLabel, "0%")
        XCTAssertEqual(ExportShareState.exporting(progress: 0.429).exportPercentLabel, "42%")
        XCTAssertEqual(ExportShareState.exporting(progress: 0.999).exportPercentLabel, "99%")
        XCTAssertEqual(ExportShareState.exporting(progress: 1).exportPercentLabel, "100%")
        XCTAssertNil(ExportShareState.idle.exportPercentLabel)
    }

    // MARK: - Cancel, closed share sheet, closed failure message (prompt 298)

    func testCancelReturnsToIdleWithNoMessage() {
        XCTAssertEqual(ExportShareState.exporting(progress: 0.3).exportCancelled(), .idle)
    }

    func testCancelAfterTheExportEndedKeepsItsResult() {
        XCTAssertEqual(ExportShareState.exported(url).exportCancelled(), .exported(url))
        XCTAssertEqual(ExportShareState.failed("x").exportCancelled(), .failed("x"))
        XCTAssertEqual(ExportShareState.idle.exportCancelled(), .idle)
    }

    func testClosingTheShareSheetEndsTheFlow() {
        XCTAssertEqual(ExportShareState.exported(url).shareDismissed(), .idle)
        XCTAssertEqual(ExportShareState.saved(url).shareDismissed(), .idle)
        XCTAssertEqual(ExportShareState.saving(url).shareDismissed(), .saving(url),
                       "a save in flight still needs the file")
        XCTAssertEqual(ExportShareState.exporting(progress: 0.5).shareDismissed(),
                       .exporting(progress: 0.5))
        XCTAssertEqual(ExportShareState.failed("x").shareDismissed(), .failed("x"))
    }

    func testClosingTheFailureMessageReturnsToIdle() {
        XCTAssertEqual(ExportShareState.failed("x").failureAcknowledged(), .idle)
        XCTAssertEqual(ExportShareState.exported(url).failureAcknowledged(), .exported(url))
        XCTAssertEqual(ExportShareState.exporting(progress: 0.5).failureAcknowledged(),
                       .exporting(progress: 0.5))
    }

    // MARK: - Which temp file is deleted on a transition (prompt 298)

    func testTheExportedFileIsDeletedWhenTheFlowLeavesIt() {
        let exported = ExportShareState.exported(url)
        XCTAssertEqual(exported.fileToDelete(movingTo: exported.shareDismissed()), url,
                       "share sheet closed")
        XCTAssertEqual(exported.fileToDelete(movingTo: exported.beginningExport()), url,
                       "a new export starts")
        XCTAssertEqual(exported.fileToDelete(movingTo: .idle), url, "the Studio closed")
        XCTAssertEqual(ExportShareState.saved(url).fileToDelete(movingTo: .idle), url)
        XCTAssertEqual(ExportShareState.saving(url).fileToDelete(movingTo: .failed("x")), url)
    }

    func testTheFileIsKeptWhileAStateStillHoldsIt() {
        let exported = ExportShareState.exported(url)
        XCTAssertNil(exported.fileToDelete(movingTo: exported))
        XCTAssertNil(exported.fileToDelete(movingTo: exported.beginningSave()))
        XCTAssertNil(ExportShareState.saving(url).fileToDelete(movingTo: .saved(url)))
        XCTAssertNil(exported.fileToDelete(movingTo: exported.exportCancelled()),
                     "a late cancel leaves the result, so the file stays")
    }

    func testAReplacedFileIsDeletedAndTheNewOneKept() {
        let old = URL(fileURLWithPath: "/tmp/old.mp4")
        let new = URL(fileURLWithPath: "/tmp/new.mp4")
        XCTAssertEqual(ExportShareState.exported(old).fileToDelete(movingTo: .exported(new)), old)
    }

    func testStatesWithoutAFileDeleteNothing() {
        XCTAssertNil(ExportShareState.idle.fileToDelete(movingTo: .exporting(progress: 0)))
        XCTAssertNil(ExportShareState.exporting(progress: 0.5).fileToDelete(movingTo: .idle),
                     "the composer deletes a partial file itself; the state never held it")
        XCTAssertNil(ExportShareState.exporting(progress: 1).fileToDelete(movingTo: .exported(url)))
        XCTAssertNil(ExportShareState.failed("x").fileToDelete(movingTo: .idle))
    }
}
