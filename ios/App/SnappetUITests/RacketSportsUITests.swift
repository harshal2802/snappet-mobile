import XCTest

/// UI coverage for **racket sports** (prompt 203): Quick Start → Racket → table tennis match vs an opponent →
/// three scored games decide a best of 5 → the result + Next match; then a drill block from the add menu and
/// the session's racket ribbon. Fresh-store launch. Set `TEST_RUNNER_RACKET_SHOTS=<dir>` to also write
/// screenshots of each state there (design review).
final class RacketSportsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["RACKET_SHOTS"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openFreeformPlayer() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 8)
            || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 2))
    }

    private func tapWhenHittable(_ el: XCUIElement, swipeIn container: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(el.waitForExistence(timeout: 6), "\(el) should exist", file: file, line: line)
        var tries = 0
        while !el.isHittable && tries < 5 { (container ?? app).swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    /// Score one game from the match page: open the sheet, set their points, save.
    private func logGame(theirPoints: Int) {
        tapWhenHittable(app.buttons["racket.endUnit"])
        let plus = app.buttons["racket.score.theirs.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "the score sheet should open")
        for _ in 0..<theirPoints { plus.tap() }
        app.buttons["racket.score.save"].tap()
        XCTAssertTrue(app.buttons["racket.score.save"].waitForNonExistence(timeout: 5))
    }

    func testTableTennisMatchIsScoredGameByGameAndDecides() {
        openFreeformPlayer()

        // The add page (an empty session's landing) offers Racket.
        tapWhenHittable(app.buttons["freeform.cardRacket"])

        // Sport + mode.
        let tt = app.buttons["racket.sport.tableTennis"]
        XCTAssertTrue(tt.waitForExistence(timeout: 5), "the sport picker should open")
        tt.tap()
        // The last-used mode is remembered across launches (UserDefaults), so choose Match explicitly.
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        shot("01-sport")
        app.buttons["racket.next"].tap()

        // Match details: just the opponent.
        let opponent = app.textFields["racket.opponent"]
        XCTAssertTrue(opponent.waitForExistence(timeout: 5))
        opponent.tap()
        opponent.typeText("Alex Chen\n")
        let event = app.textFields["racket.event"]
        tapWhenHittable(event)
        event.typeText("City Open\n")
        let round = app.textFields["racket.round"]
        tapWhenHittable(round)
        round.typeText("R16\n")
        shot("02-match-details")
        tapWhenHittable(app.buttons["racket.startMatch"])

        // The match page: scoreboard + "vs Alex Chen".
        XCTAssertTrue(app.buttons["racket.endUnit"].waitForExistence(timeout: 6), "the match page should show")
        XCTAssertTrue(app.staticTexts["vs Alex Chen"].waitForExistence(timeout: 3))

        // Game 1: 11–7 — check the rules line before saving.
        tapWhenHittable(app.buttons["racket.endUnit"])
        let plus = app.buttons["racket.score.theirs.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        for _ in 0..<7 { plus.tap() }
        XCTAssertEqual(any("racket.score.theirs").label, "7")
        shot("03-score-sheet")
        app.buttons["racket.score.save"].tap()
        XCTAssertTrue(app.buttons["racket.score.save"].waitForNonExistence(timeout: 5))
        shot("04-after-game-1")

        // Game 2 lost 9–11 (swap), game 3 & 4 won → 3–1, decided.
        tapWhenHittable(app.buttons["racket.endUnit"])
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        for _ in 0..<9 { plus.tap() }
        app.buttons["racket.score.swap"].tap()
        app.buttons["racket.score.save"].tap()
        XCTAssertTrue(app.buttons["racket.score.save"].waitForNonExistence(timeout: 5))
        logGame(theirPoints: 5)
        shot("05-match-point")
        logGame(theirPoints: 8)

        XCTAssertTrue(any("racket.result").waitForExistence(timeout: 6), "a decided best of 5 shows the result")
        XCTAssertTrue(app.buttons["racket.nextMatch"].exists, "Next match should be offered")
        XCTAssertTrue(app.buttons["racket.nextMatch"].label.contains("QF"), "the round advances R16 → QF")
        shot("06-match-won")

        // Next match keeps the event and asks only for the new opponent.
        app.buttons["racket.nextMatch"].tap()
        let next = app.textFields["racket.opponent"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["racket.event"].value as? String, "City Open")
        XCTAssertEqual(app.textFields["racket.round"].value as? String, "QF")
        app.buttons["Cancel"].firstMatch.tap()

        // A drill from the dock's add menu: the last sport is pre-selected; pick Drill → a suggestion.
        app.buttons["freeform.addExercise"].tap()
        let racketItem = app.buttons["Racket sport"]
        XCTAssertTrue(racketItem.waitForExistence(timeout: 4))
        racketItem.tap()
        XCTAssertTrue(app.buttons["racket.next"].waitForExistence(timeout: 5))
        app.segmentedControls["racket.mode"].buttons["Drill"].tap()
        app.buttons["racket.next"].tap()
        let drill = app.buttons["racket.drill"].firstMatch
        XCTAssertTrue(drill.waitForExistence(timeout: 5), "suggested drills should list")
        shot("07-drill-picker")
        drill.tap()
        let logBlock = app.buttons["racket.logBlock"]
        XCTAssertTrue(logBlock.waitForExistence(timeout: 5), "the drill page should show")
        shot("08-drill")
        tapWhenHittable(logBlock)
        XCTAssertTrue(app.buttons["Log block 2"].waitForExistence(timeout: 4), "the block should log")

        // The overview's ribbon rolls the day up.
        app.buttons.matching(identifier: "freeform.rail.0").firstMatch.tap()
        XCTAssertTrue(any("freeform.disciplineRibbon").waitForExistence(timeout: 5), "the overview rolls the day up")
        shot("09-overview")

        // Finish → the session's detail → remove the match from the finished session (its drill stays).
        app.buttons["freeform.finishSession"].tap()
        let viewDetail = app.buttons["freeform.viewDetail"]
        tapWhenHittable(viewDetail)
        let menu = app.buttons["session.exerciseMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "each exercise header should have a ⋯ menu")
        XCTAssertTrue(app.staticTexts["R16 vs Alex Chen · Won 3–1"].exists, "the match header carries its result")
        shot("10-session-detail")
        menu.tap()
        XCTAssertTrue(app.buttons["session.editMatch"].waitForExistence(timeout: 3), "a match offers Match details")
        app.buttons["session.removeExercise"].tap()
        let confirm = app.buttons["session.confirmRemoveExercise"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "removal is confirmed first")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["R16 vs Alex Chen · Won 3–1"].waitForNonExistence(timeout: 5),
                      "the match is gone from the session")
        XCTAssertTrue(app.buttons["session.exerciseMenu"].firstMatch.exists, "the drill is still there")
        shot("11-after-remove")
    }
}
