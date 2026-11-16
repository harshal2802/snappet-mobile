import XCTest

/// Prompt 262 (review findings F9, F16).
///
/// F9: a finished session whose dominant discipline isn't racket still shows the racket card, and Your videos, Edit
/// match and a game's heart rate open from it. Seeded by `-uiTestSeedRacketVideos -uiTestRacketMixedSession <variant>`:
/// the seed's recorded match (two Watch games, no drill) plus two lifts × 3 sets (`strength`: strength dominant, the
/// detail's strength branch) or two planks × 3 holds (`timed`: timed dominant, through `SessionRecapCards`), and a
/// synthetic heart-rate series.
///
/// F16: removing a finished session's only exercise offers deleting the whole session (Cancel keeps it). Seeded by
/// `-uiTestSeedRacketHR` (one match, nothing else).
///
/// Screenshots with `RACKET_SHOTS=<dir>` (set through `TEST_RUNNER_RACKET_SHOTS`).
@MainActor
final class RacketMixedSessionUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ args: [String]) {
        app = XCUIApplication()
        app.launchArguments += args
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

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
        reveal(el, file: file, line: line)
        el.tap()
    }

    /// Scroll until `el` is on screen above the tab bar.
    private func reveal(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 10 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        let bottom = app.windows.firstMatch.frame.maxY - 60
        while (!el.isHittable || el.frame.maxY > bottom) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
    }

    private func openHistory() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
    }

    private func historyRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS %@", name)).firstMatch
    }

    /// History → the seeded mixed session; the racket card is on its detail.
    private func openMixedSession() {
        openHistory()
        let row = historyRow("Racket videos")
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded session")
        row.tap()
        XCTAssertTrue(any("racket.recap.match").waitForExistence(timeout: 6), "the racket card on a non-racket session")
    }

    /// Your videos opens and closes; Edit match opens on the match and cancels; a game's heart rate opens.
    private func checkRacketScreensOpen(_ prefix: String) {
        reveal(app.buttons["racket.recap.videos"])
        XCTAssertTrue(app.buttons["racket.recap.editMatch"].exists, "Edit match on the match row")
        shot("\(prefix)-01b-racket-card")
        tapWhenHittable(app.buttons["racket.recap.videos"])
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6), "Your videos opens")
        XCTAssertTrue(any("racket.videos.line.0").exists, "the match's recording is listed")
        shot("\(prefix)-02-your-videos")
        app.buttons["racket.videos.close"].tap()
        XCTAssertTrue(any("racket.videos.header").waitForNonExistence(timeout: 5))

        tapWhenHittable(app.buttons["racket.recap.editMatch"])
        XCTAssertTrue(any("racket.editMatch.result").waitForExistence(timeout: 5), "Edit match opens")
        XCTAssertTrue(any("racket.editMatch.result").label.contains("game"), any("racket.editMatch.result").label)
        shot("\(prefix)-03-edit-match")
        app.buttons["racket.editMatch.cancel"].tap()
        XCTAssertTrue(any("racket.editMatch.result").waitForNonExistence(timeout: 5))

        let hr = app.buttons["racket.recap.unitHR"].firstMatch
        tapWhenHittable(hr)
        XCTAssertTrue(any("racket.gameHR.chart").waitForExistence(timeout: 5), "the game's heart rate opens")
        shot("\(prefix)-04-game-hr")
        app.buttons["racket.gameHR.done"].tap()
        XCTAssertTrue(any("racket.gameHR.chart").waitForNonExistence(timeout: 4))
    }

    /// The review's case: a match and two lifts — workout type strength, strength dominant.
    func testStrengthDominantSessionReachesYourVideosEditMatchAndGameHR() {
        launch(["-uiTestSeedRacketVideos", "-uiTestRacketMixedSession", "strength", "-uiTestFakeCamera"])
        openMixedSession()
        XCTAssertTrue(any("insights.exercise").exists, "the strength branch's own cards stay")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "racket.recap.match").count, 1, "one racket card")
        XCTAssertFalse(any("racket.recap.drill").exists, "the mixed seed has no drill")
        shot("strength-01-detail")
        checkRacketScreensOpen("strength")
    }

    /// A match and two planks — workout type timed, timed dominant: the card comes through `SessionRecapCards`.
    func testTimedDominantSessionReachesYourVideosEditMatchAndGameHR() {
        // `-uiTestRacketPlayer portrait`: the match's recording has Photos-style parts and Snappet's rallies, so Keep
        // rallies only… is offered too.
        launch(["-uiTestSeedRacketVideos", "-uiTestRacketMixedSession", "timed", "-uiTestRacketPlayer", "portrait",
                "-uiTestFakeCamera"])
        openMixedSession()
        XCTAssertTrue(any("freeform.summaryTimedRow").exists, "the timed cards stay")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "racket.recap.match").count, 1, "one racket card")
        shot("timed-01-detail")
        checkRacketScreensOpen("timed")

        tapWhenHittable(app.buttons["racket.recap.keepRallies"])
        XCTAssertTrue(any("racket.keep.save").waitForExistence(timeout: 6), "Keep rallies only… opens")
        shot("timed-05-keep-rallies")
    }

    /// F16: the only exercise → "Delete this session?"; Cancel keeps it, Delete session leaves and removes it.
    func testRemovingTheLastExerciseOffersDeletingTheSession() {
        launch(["-uiTestSeedRacketHR"])
        openHistory()
        let row = historyRow("City Open")
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded one-match session")
        row.tap()
        let menu = app.buttons["session.exerciseMenu"].firstMatch
        tapWhenHittable(menu)
        tapWhenHittable(app.buttons["session.removeExercise"])
        let delete = app.buttons["session.confirmDeleteSession"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 4), "the only exercise offers deleting the session")
        XCTAssertFalse(app.buttons["session.confirmRemoveExercise"].exists, "not an empty session")
        XCTAssertTrue(app.staticTexts["Delete this session?"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Your photos and videos stay in your Photos library'")).firstMatch.exists)
        shot("last-01-confirm")

        // iOS 26 shows the dialog as a popover whose Cancel is a tap outside it; older layouts list a Cancel button.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)).tap() }
        XCTAssertTrue(delete.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.buttons["session.exerciseMenu"].firstMatch.exists, "Cancel keeps the match")

        tapWhenHittable(app.buttons["session.exerciseMenu"].firstMatch)
        tapWhenHittable(app.buttons["session.removeExercise"])
        XCTAssertTrue(delete.waitForExistence(timeout: 4))
        delete.tap()
        XCTAssertTrue(app.buttons["session.exerciseMenu"].firstMatch.waitForNonExistence(timeout: 6), "the detail closes")
        XCTAssertTrue(app.segmentedControls.buttons["History"].waitForExistence(timeout: 4), "back on History")
        XCTAssertTrue(historyRow("City Open").waitForNonExistence(timeout: 5), "the session is gone from History")
        shot("last-02-history")
    }
}
