import XCTest

/// Prompt 263: the live session never loses work silently. On the racket video seed kept running
/// (`-uiTestRacketLive`; `-uiTestRacketEditMatch` adds the stray game before the recording, `-uiTestRacketLiveCrash`
/// leaves the match's recording open as an app kill does, with nothing logged): Remove match asks (F5); Finish with
/// recordings but no games asks and saves (F2), and so does the finish link; "Record everything" on a recorded match is
/// off with its reason (F1); the history drawer removes the stray game the way Edit match does and keeps Your videos
/// right (F3); a crashed recording shows its saved time (F14). Fresh store + fake camera: the finish link while
/// recording everything finishes nothing (F4). Screenshots with `RACKET_SHOTS=<dir>` (via `TEST_RUNNER_RACKET_SHOTS`).
@MainActor
final class LiveSessionSafetyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchLive(_ extra: [String]) {
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestRacketLive", "-uiTestFakeCamera"] + extra
        app.launchOnTestStore()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// The one on the current page (the pager keeps neighbouring pages in the hierarchy).
    private func onPage(_ id: String, timeout: TimeInterval = 6) -> XCUIElement {
        let all = app.descendants(matching: .any).matching(identifier: id)
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let el = all.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return el }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < end
        return all.firstMatch
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        guard let dir = ProcessInfo.processInfo.environment["RACKET_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        let bottom = app.windows.firstMatch.frame.maxY - 90
        while (!el.isHittable || el.frame.maxY > bottom) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    /// Gym Tracker → Quick Start resumes the running seeded session.
    private func openLivePlayer() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        XCTAssertTrue(app.buttons["minimizeWorkout"].waitForExistence(timeout: 8), "the live player")
    }

    /// Rail: 0 overview, then the exercises in order (the match vs Alex is 1).
    private func openPage(_ rail: Int) {
        let chip = app.buttons.matching(identifier: "freeform.rail.\(rail)").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        chip.tap()
    }

    /// A confirmation dialog's Cancel: a tap outside it on iOS 26 (no Cancel row is drawn).
    private func cancelDialog() {
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap() }
    }

    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    // MARK: F5

    func testRemoveMatchAsksSaysTheVideoStaysAndCancelKeepsIt() {
        launchLive(["-uiTestRacketEditMatch"])
        openLivePlayer()
        openPage(1)
        onPage("freeform.entityMenu").tap()
        let remove = app.buttons.matching(NSPredicate(format: "label == %@", "Remove match")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 4))
        remove.tap()
        let confirm = app.buttons.matching(identifier: "freeform.confirmRemoveExercise").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "Remove match asks first")
        XCTAssertEqual(confirm.label, "Remove this match")
        XCTAssertTrue(text(containing: "Remove this match?").exists)
        XCTAssertTrue(text(containing: "with its recording’s split, rallies and tags. The video stays in your Photos library").exists,
                      "the message says what goes and that the video stays")
        shot("01-remove-match-confirm")
        cancelDialog()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons.matching(identifier: "freeform.rail.4").firstMatch.exists, "Cancel keeps the match (3 exercises + Add)")
        XCTAssertTrue(app.buttons["freeform.rail.1"].label.contains("Alex"), app.buttons["freeform.rail.1"].label)

        onPage("freeform.entityMenu").tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 4))
        remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.tap()
        XCTAssertTrue(app.buttons["freeform.rail.4"].waitForNonExistence(timeout: 5), "the match is removed once confirmed")
        XCTAssertFalse(app.buttons["freeform.rail.1"].label.contains("Alex"), app.buttons["freeform.rail.1"].label)
        shot("02-match-removed")
    }

    // MARK: F2 + F14

    func testACrashedRecordingShowsItsSavedTimeAndFinishAsksThenSaves() {
        launchLive(["-uiTestRacketLiveCrash"])
        openLivePlayer()
        openPage(1)
        // F14: the open run is closed at its last saved part (20:00), not counting to now (about three hours).
        let line = onPage("racket.recording.line")
        XCTAssertTrue(line.waitForExistence(timeout: 6))
        XCTAssertEqual(line.label, "1 recording · 20:00 · 4 marks")
        // F1: the recorded match can't record everything again.
        XCTAssertFalse(onPage("racket.recordEverything").isEnabled)
        shot("03-crash-recovered")

        // F2: recordings, no games: Finish asks instead of deleting.
        app.buttons["freeform.finish"].tap()
        let save = app.buttons.matching(identifier: "freeform.finishAsk.save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 4), "Finish asks")
        XCTAssertTrue(app.buttons.matching(identifier: "freeform.finishAsk.discard").firstMatch.exists)
        XCTAssertTrue(text(containing: "Discard deletes 2 recordings with their splits, rallies and tags from this session. Videos stay in your Photos library.").exists,
                      "the line says what Discard deletes")
        shot("04-finish-asks")
        cancelDialog()
        XCTAssertTrue(save.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["minimizeWorkout"].exists, "Cancel keeps the session running")

        app.buttons["freeform.finish"].tap()
        XCTAssertTrue(save.waitForExistence(timeout: 4))
        save.tap()
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 8), "saved and closed")
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Racket videos'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the session is in History, not deleted")
        shot("05-saved-in-history")
    }

    func testTheFinishLinkSavesASessionWithRecordingsButNoGames() throws {
        try TestStoreGuard.skipLinkTestsOnDevice()
        launchLive(["-uiTestRacketLiveCrash"])
        openLivePlayer()
        XCUIDevice.shared.system.open(URL(string: "snappet://finish")!)
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 10), "the session finished")
        XCTAssertFalse(app.buttons["minimizeWorkout"].exists)
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Racket videos'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the link saved it instead of deleting it")
    }

    // MARK: F1

    func testRecordEverythingOnARecordedMatchIsOffWithItsReason() {
        launchLive(["-uiTestRacketEditMatch"])
        openLivePlayer()
        openPage(1)
        let button = onPage("racket.recordEverything")
        XCTAssertTrue(button.waitForExistence(timeout: 6))
        XCTAssertEqual(button.label, "Record everything")
        XCTAssertFalse(button.isEnabled, "a second recording isn't supported yet")
        let reason = onPage("racket.recordEverything.reason")
        XCTAssertTrue(reason.exists)
        XCTAssertEqual(reason.label, "This match already has a recording. A second one isn’t supported yet.")
        XCTAssertTrue(onPage("racket.yourVideos").exists, "its recording is still there")
        shot("06-record-again-blocked")
    }

    // MARK: F3

    func testDrawerDeleteOnARacketMatchKeepsYourVideosRight() {
        launchLive(["-uiTestRacketEditMatch"])
        openLivePlayer()
        openPage(1)
        tapWhenHittable(onPage("freeform.history"))
        let rows = app.cells.containing(.any, identifier: "freeform.historyRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the drawer")
        XCTAssertEqual(rows.count, 4)
        // The recording's games have video: no swipe, and the row says why.
        for i in 1...3 {
            XCTAssertEqual(any("freeform.historyRow.keep.\(i)").label, "Has video. Remove it from Edit match after the session.")
        }
        XCTAssertFalse(any("freeform.historyRow.keep.0").exists, "the stray game has no video")
        shot("07-drawer-reasons")
        rows.element(boundBy: 1).swipeLeft()
        XCTAssertFalse(app.buttons["Delete"].waitForExistence(timeout: 2), "a game with video can't be swiped away")
        rows.element(boundBy: 0).swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        let deleted = NSPredicate(format: "count == 3")
        expectation(for: deleted, evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        shot("08-drawer-after-delete")
        app.buttons["freeform.historyDone"].tap()

        tapWhenHittable(onPage("racket.yourVideos"))
        XCTAssertTrue(any("racket.videos.line.0").waitForExistence(timeout: 6))
        XCTAssertEqual(any("racket.videos.line.0").label, "9–11 · 4:30")
        XCTAssertEqual(any("racket.videos.line.1").label, "9–11 · 4:30")
        XCTAssertEqual(any("racket.videos.line.2").label, "9–11 · 3:31")
        XCTAssertFalse(any("racket.videos.line.3").exists, "three games, no duplicate")
        XCTAssertEqual(any("racket.videos.tags.2").label, "3 marked by you", "tags intact")
        shot("09-your-videos-after-drawer-delete")
    }

    // MARK: F4

    func testTheFinishLinkWhileRecordingEverythingFinishesNothing() throws {
        try TestStoreGuard.skipLinkTestsOnDevice()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestFakeCamera"]
        app.launchEnvironment["SNAPPET_FAKE_CAMERA"] = "1"
        app.launchOnTestStore()
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        XCTAssertTrue(app.buttons["workout.quickStart"].waitForExistence(timeout: 6))
        app.buttons["workout.quickStart"].tap()
        tapWhenHittable(app.buttons["freeform.cardRacket"])
        XCTAssertTrue(app.buttons["racket.sport.tableTennis"].waitForExistence(timeout: 5))
        app.buttons["racket.sport.tableTennis"].tap()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
        let opponent = app.textFields["racket.opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 5))
        opponent.tap()
        opponent.typeText("Alex\n")
        tapWhenHittable(app.buttons["racket.recording.everything"])
        tapWhenHittable(app.buttons["racket.match.setUpCamera"])
        let shutter = app.buttons["racket.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 8))
        shutter.tap()
        XCTAssertTrue(app.buttons["racket.storage.continue"].waitForExistence(timeout: 6))
        app.buttons["racket.storage.continue"].tap()
        let stop = app.buttons["racket.rec.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "recording everything")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("Recording"))

        XCUIDevice.shared.system.open(URL(string: "snappet://finish")!)
        let alert = app.alerts["Session not finished"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the recording screen says the session wasn't finished")
        let ok = alert.buttons.matching(NSPredicate(format: "label == %@", "OK")).firstMatch
        XCTAssertTrue(text(containing: "This screen is still recording. Stop it here first, then finish the session.").exists)
        shot("10-finish-link-refused")
        ok.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 4), "still on the recording screen")
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("Recording"), "still recording")

        // Its own Stop still ends it properly (the split prompt).
        stop.tap()
        XCTAssertTrue(any("racket.split.recorded").waitForExistence(timeout: 6), "the split prompt")
        shot("11-stop-still-ends-it")
    }
}
