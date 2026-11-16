import XCTest

/// A read-only look at the user's own recordings on their phone (no seed arguments, so the real store). Runs only
/// with `TEST_RUNNER_RACKET_REAL_WALK=1`. It opens, plays and cancels; it never saves, splits, tags, rotates or deletes.
@MainActor
final class RacketRealMatchWalkUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RACKET_REAL_WALK"] == "1", "real-data walk is opt-in")
        app = XCUIApplication()
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        guard app.state == .runningForeground else { return }
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func dump(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name + ".txt"; a.lifetime = .keepAlways; add(a)
    }

    func testListHistory() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        shot("history")
        dump("history")
    }

    private func openToday() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        // `TEST_RUNNER_RACKET_REAL_ROW`: text from the history row to open, e.g. its date line.
        let want = ProcessInfo.processInfo.environment["RACKET_REAL_ROW"] ?? ""
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS %@", want)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
    }

    func testOpenVideosList() {
        openToday()
        Thread.sleep(forTimeInterval: 1.5)
        shot("recap-top"); dump("recap")
        let videos = app.buttons["racket.recap.videos"]
        for _ in 0..<8 where !(videos.exists && videos.isHittable && videos.frame.maxY < app.windows.firstMatch.frame.maxY - 120) {
            app.swipeUp(velocity: .slow)
        }
        shot("recap-videos-button")
        guard videos.exists else { return XCTFail("no Your videos button") }
        videos.tap()
        Thread.sleep(forTimeInterval: 2)
        shot("videos-1"); dump("videos")
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1); shot("videos-2")
        app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1); shot("videos-3"); dump("videos-end")
    }

    private func bring(_ el: XCUIElement) {
        let bottom = app.windows.firstMatch.frame.maxY - 130
        for _ in 0..<12 where !(el.exists && el.isHittable && el.frame.maxY < bottom && el.frame.minY > 100) {
            if el.exists && el.frame.minY < 100 { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    private func openVideos() {
        openToday()
        let videos = app.buttons["racket.recap.videos"]
        bring(videos)
        videos.tap()
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6))
    }

    /// Game 1 of the split match in the Watch player: does it show the picture and advance?
    func testPlayFirstGame() {
        openVideos()
        let play = app.buttons.matching(identifier: "racket.videos.play.0").element(boundBy: 0)
        bring(play); play.tap()
        let surface = any("racket.player.surface")
        XCTAssertTrue(surface.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        let a = surface.value as? String ?? ""
        shot("player-1")
        Thread.sleep(forTimeInterval: 4)
        let b = surface.value as? String ?? ""
        shot("player-2"); dump("player")
        print("REALWALK player \(a) -> \(b)")
        XCTAssertNotEqual(a, b, "the player advances")
    }

    /// The unsplit match: the whole recording in the player, then the split screen and one Fix sheet. Never applies.
    func testSplitSheetOnUnsplitMatch() {
        openVideos()
        let split = app.buttons["racket.videos.split"]
        bring(split)
        shot("unsplit-row")
        split.tap()
        Thread.sleep(forTimeInterval: 6)
        shot("split-review-1"); dump("split-review")
        let fix = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'racket.split.fix.'")).element(boundBy: 0)
        guard fix.waitForExistence(timeout: 20) else { shot("split-no-fix"); return XCTFail("no Fix buttons") }
        bring(fix); fix.tap()
        XCTAssertTrue(app.buttons["racket.split.edit.save"].waitForExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 2)
        shot("sheet-1")
        let head = { self.any("racket.split.edit.playhead").label }
        let range = any("racket.split.edit.range").label
        let h0 = head()
        app.buttons["racket.split.edit.play"].tap()
        Thread.sleep(forTimeInterval: 4)
        let h1 = head()
        shot("sheet-playing")
        app.buttons["racket.split.edit.play"].tap()
        // Move the end in the sheet only (cancelled below), then Play again: the reported bug.
        app.buttons["racket.split.edit.end.-10"].tap()
        let h2 = head()
        app.buttons["racket.split.edit.play"].tap()
        Thread.sleep(forTimeInterval: 4)
        let h3 = head()
        shot("sheet-playing-after-end-move"); dump("sheet")
        app.buttons["racket.split.edit.play"].tap()
        print("REALWALK sheet range=\(range) | \(h0) -> \(h1) | after end move \(h2) -> \(h3)")
        app.buttons["Cancel"].tap()
        Thread.sleep(forTimeInterval: 1)
        shot("split-review-after-cancel")
        XCTAssertNotEqual(h0, h1, "Play advances on a real recording")
        XCTAssertNotEqual(h2, h3, "Play advances after moving the end")
    }
}
