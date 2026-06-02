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
        XCTAssertEqual(s, .exporting)
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
        XCTAssertNil(ExportShareState.exporting.exportedURL)
        XCTAssertNil(ExportShareState.failed("boom").exportedURL)
    }

    // MARK: - Save guarded on having a rendered file

    func testBeginningSaveNoopsWithoutAnExport() {
        XCTAssertEqual(ExportShareState.idle.beginningSave(), .idle,
                       "can't save before an export produced a file")
        XCTAssertEqual(ExportShareState.exporting.beginningSave(), .exporting)
        XCTAssertEqual(ExportShareState.failed("x").beginningSave(), .failed("x"))
    }

    func testSaveSucceededNoopsWithoutAnExport() {
        XCTAssertEqual(ExportShareState.idle.saveSucceeded(), .idle)
    }

    // MARK: - isBusy gates the UI actions

    func testIsBusyOnlyDuringWork() {
        XCTAssertTrue(ExportShareState.exporting.isBusy)
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
        XCTAssertEqual(s, .exporting)
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
}
