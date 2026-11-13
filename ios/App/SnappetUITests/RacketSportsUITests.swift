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
        // Play without video (prompt 249) opens ScoreOnly; Close keeps the match on its page.
        tapWhenHittable(app.buttons["racket.match.playWithoutVideo"])
        let close = app.buttons["racket.scoreOnly.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 6), "Play without video opens the point-by-point screen")
        close.tap()

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
        // First time with this drill (prompt 250): choose what you're practising and your focus, then start without
        // video; Wait before block 1 goes back, and the page keeps its log-a-block hero for corrections.
        tapWhenHittable(app.buttons["racket.plan.row.practising"])
        tapWhenHittable(app.buttons["racket.custom.practising.With a partner"])
        tapWhenHittable(app.buttons["racket.custom.hand.Forehand"])
        app.buttons["racket.custom.save"].tap()
        tapWhenHittable(app.buttons["racket.recording.off"])
        tapWhenHittable(app.buttons["racket.plan.start"])
        XCTAssertTrue(app.buttons["racket.rec.wait"].waitForExistence(timeout: 6), "the countdown to block 1")
        app.buttons["racket.rec.wait"].tap()
        tapWhenHittable(app.buttons["racket.rec.back"])
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

    // MARK: - Sport-specific boards (prompt 252)

    private func relaunch(_ args: [String]) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += args
        app.launchEnvironment["SNAPPET_FAKE_CAMERA"] = "1"
        app.launch()
    }

    private func openMatchForm(_ sport: String) {
        openFreeformPlayer()
        tapWhenHittable(app.buttons["freeform.cardRacket"])
        let s = app.buttons["racket.sport.\(sport)"]
        XCTAssertTrue(s.waitForExistence(timeout: 5))
        s.tap()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
    }

    /// PbScoring → PbMatch → ScoreOnly's call → the game screen's caption → PbSideOut (server 1, then server 2 lost).
    func testPickleballSideOutScoringFromSetupToTheServeChange() {
        relaunch(["-uiTestFreshStore", "-uiTestFakeCamera", "-uiTestWatchReady", "-uiTestWatchTaps"])
        openMatchForm("pickleball")
        let sideOut = app.buttons["racket.pbScoring.sideOut"]
        XCTAssertTrue(sideOut.waitForExistence(timeout: 5), "PbScoring comes before the pickleball match form")
        XCTAssertTrue(sideOut.isSelected, "Traditional, side-out is the board's default")
        XCTAssertTrue(app.buttons["racket.pbScoring.to11"].isSelected)
        XCTAssertTrue(any("racket.pbScoring.call").label.contains("Doubles score call: 4 – 2 – 1"))
        app.buttons["racket.doubles.doubles"].tap()
        let partner = app.textFields["racket.partner"]
        tapWhenHittable(partner)
        partner.typeText("Mia\n")
        shot("pb-01-scoring")
        tapWhenHittable(app.buttons["racket.pbScoring.continue"])
        XCTAssertTrue(any("racket.match.header").waitForExistence(timeout: 4))
        XCTAssertFalse(any("racket.format").exists, "PbMatch has no format box (it's on PbScoring)")
        XCTAssertTrue(any("racket.match.format").label.contains("Games to 11"))
        shot("pb-02-match")

        // ScoreOnly: the call, serving score first.
        tapWhenHittable(app.buttons["racket.match.playWithoutVideo"])
        XCTAssertTrue(any("racket.game.score").waitForExistence(timeout: 6))
        XCTAssertEqual(any("racket.game.score").label, "0–0–2", "the game's first side has one server")
        app.buttons["racket.scoreOnly.us"].tap()
        XCTAssertEqual(any("racket.game.score").label, "1–0–2")
        app.buttons["racket.scoreOnly.them"].tap()
        XCTAssertEqual(any("racket.game.score").label, "0–1–1", "side-out: no point for winning while receiving")
        shot("pb-03-score-only")
        app.buttons["racket.scoreOnly.undo"].tap()
        XCTAssertEqual(any("racket.game.score").label, "1–0–2")

        // Start recording instead → Warmup's doubles row → the game screen.
        app.buttons["racket.scoreOnly.record"].tap()
        XCTAssertTrue(app.buttons["racket.camera.continue"].waitForExistence(timeout: 6))
        app.buttons["racket.camera.continue"].tap()
        let mia = app.buttons["racket.warmup.ourServe.partner"]
        XCTAssertTrue(mia.waitForExistence(timeout: 4), "Who serves first for us? in doubles")
        XCTAssertEqual(mia.label, "Mia")
        mia.tap()
        shot("pb-04-warmup")
        app.buttons["racket.warmup.start"].tap()
        XCTAssertTrue(app.buttons["racket.rec.show.dim"].waitForExistence(timeout: 6))
        app.buttons["racket.rec.show.dim"].tap()
        XCTAssertEqual(any("racket.game.score").label, "1–0–2", "the game in progress keeps its call")
        XCTAssertEqual(any("racket.game.caption").label, "Serving · server 2")
        shot("pb-05-dim")

        // Their side out and back: us serving server 1 at 1–0–1.
        let us = app.buttons["racket.test.watchUs"], them = app.buttons["racket.test.watchThem"]
        them.tap()                       // our one server lost → side-out
        XCTAssertTrue(any("racket.sideOut.panel.0").waitForExistence(timeout: 3), "PbSideOut after a serving-side loss")
        XCTAssertEqual(any("racket.sideOut.call.0").label, "0 – 1 – 1")
        us.tap()                         // their server 1 lost
        us.tap()                         // their server 2 lost → side-out to us
        XCTAssertTrue(any("racket.sideOut.panel.1").waitForExistence(timeout: 3))
        // PbSideOut as the board: our server 1 loses, then server 2.
        them.tap()
        XCTAssertTrue(any("racket.sideOut.panel.0").waitForExistence(timeout: 3))
        XCTAssertFalse(any("racket.sideOut.panel.1").exists)
        XCTAssertTrue(app.staticTexts["Server 1 lost the rally"].exists)
        XCTAssertTrue(app.staticTexts["No point. Your partner serves next."].exists)
        XCTAssertEqual(any("racket.sideOut.call.0").label, "1 – 0 – 2")
        them.tap()
        XCTAssertTrue(any("racket.sideOut.panel.1").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Server 2 lost the rally"].exists)
        XCTAssertTrue(app.staticTexts["Side-out. They serve next."].exists)
        XCTAssertEqual(any("racket.sideOut.call.1").label, "0 – 1 – 1")
        XCTAssertEqual(any("racket.sideOut.footnote").label, "At the start of a game, only one server serves before the first side-out.")
        XCTAssertTrue(app.buttons["racket.game.next"].exists && app.buttons["racket.game.stop"].exists)
        shot("pb-06-side-out")
        app.buttons["racket.sideOut.undo"].tap()
        XCTAssertFalse(any("racket.sideOut.panel.0").waitForExistence(timeout: 1), "Undo returns to the game screen")
        XCTAssertEqual(any("racket.game.score").label, "1–0–2")
        // Next rally: the panel goes once the next tap comes (or after a few seconds).
        them.tap()
        XCTAssertTrue(any("racket.sideOut.panel.0").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.game.score").waitForExistence(timeout: 9), "back on the game screen by itself")
        XCTAssertEqual(any("racket.game.caption").label, "Them serving · server 1")
    }

    /// TnMatch "No-ad": at 40–40 the next point wins the game.
    func testTennisNoAdDecidesDeuceWithOnePoint() {
        relaunch(["-uiTestFreshStore", "-uiTestFakeCamera"])
        openMatchForm("tennis")
        let noAd = app.buttons["racket.format.noAd"]
        tapWhenHittable(noAd)
        XCTAssertTrue(noAd.isSelected)
        XCTAssertTrue(any("racket.format.noAdLine").exists)
        shot("tn-01-match-no-ad")
        tapWhenHittable(app.buttons["racket.match.playWithoutVideo"])
        let us = app.buttons["racket.scoreOnly.us"], them = app.buttons["racket.scoreOnly.them"]
        XCTAssertTrue(us.waitForExistence(timeout: 6))
        for _ in 0..<3 { us.tap(); them.tap() }
        XCTAssertEqual(any("racket.game.score").label, "40 – 40")
        them.tap()
        XCTAssertEqual(any("racket.game.score").label, "0 – 0", "no-ad: the deciding point won the game (not Ad)")
        shot("tn-02-no-ad-scored")
    }

    // MARK: Tag sheets per sport (seeded game-by-game match, Snappet's rallies in game 1)

    private func openTagSheet(_ sport: String, doubles: Bool) {
        var args = ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestRacketTaggedGames", "-uiTestRacketSport", sport]
        if doubles { args += ["-uiTestRacketDoubles", "YES"] }
        relaunch(args)
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Racket videos'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded session")
        row.tap()
        tapWhenHittable(app.buttons["racket.recap.videos"])
        tapWhenHittable(app.buttons["racket.videos.mark.0"])
        tapWhenHittable(app.buttons["racket.tl.rally.8"])
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 5))
    }

    func testTennisTagShowsGamesPointAndServeDetails() {
        openTagSheet("tennis", doubles: false)
        XCTAssertEqual(any("racket.tag.soFar").label, "Games 1–0")
        XCTAssertEqual(any("racket.tag.point").label, "Point 30–30")
        shot("tn-03-tag")
        tapWhenHittable(app.buttons["racket.tag.detail.serve"])
        XCTAssertTrue(app.buttons["racket.serve.next"].waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.serve.title").label, "Point 9")
        XCTAssertEqual(any("racket.serve.game").label, "Game 1–0")
        XCTAssertEqual(any("racket.serve.serving").label, "You’re serving")
        app.buttons["racket.serve.doubleFault"].tap()
        XCTAssertTrue(app.buttons["racket.serve.winner.them"].isSelected, "a double fault gives the point away")
        app.buttons["racket.serve.secondIn"].tap()
        app.buttons["racket.serve.winner.us"].tap()
        shot("tn-04-serve")
        app.buttons["racket.serve.next"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForNonExistence(timeout: 5), "Next point saved the last rally")
    }

    func testPadelWallSetsTheEndingAndReturnsToTag() {
        openTagSheet("padel", doubles: true)
        XCTAssertEqual(any("racket.tag.soFar").label, "Games 1–0")
        XCTAssertEqual(any("racket.tag.serving").label, "Mia serving")
        shot("pd-01-doubles-tag")
        tapWhenHittable(app.buttons["racket.tag.detail.wall"])
        XCTAssertTrue(app.buttons["racket.wall.next"].waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.wall.title").label, "Rally 9")
        XCTAssertEqual(any("racket.wall.question").label, "Did the ball bounce first?")
        app.buttons["racket.wall.wallFirst"].tap()
        shot("pd-02-wall")
        app.buttons["racket.wall.next"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 4), "back on the tag sheet")
        XCTAssertTrue(app.buttons["racket.tag.end.hitWallFirst"].isSelected)
        tapWhenHittable(app.buttons["racket.tag.detail.wall"])
        XCTAssertTrue(app.buttons["racket.wall.wallFirst"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.wall.wallFirst"].isSelected, "reopens on your answer")
        app.buttons["racket.wall.back"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 4))
    }

    func testSquashLetCallIsTheEnding() {
        openTagSheet("squash", doubles: false)
        XCTAssertEqual(any("racket.tag.soFar").label, "So far 6–2")
        XCTAssertEqual(any("racket.tag.final").label, "Final 11–9")
        tapWhenHittable(app.buttons["racket.tag.detail.letCall"])
        XCTAssertTrue(app.buttons["racket.let.next"].waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.let.question").label, "Was there interference?")
        XCTAssertEqual(any("racket.let.footnote").label, "Your tag decides how this rally scores. Snappet won’t judge this from video.")
        app.buttons["racket.let.stroke"].tap()
        shot("sq-01-let")
        app.buttons["racket.let.next"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.tag.end.stroke"].isSelected)
    }

    func testPickleballDoublesTagShowsTheCallAndServer() {
        openTagSheet("pickleball", doubles: true)
        XCTAssertEqual(any("racket.tag.soFar").label, "4–1–1")
        XCTAssertEqual(any("racket.tag.serving").label, "Mia, server 1")
        shot("pb-07-doubles-tag")
        app.buttons["racket.tag.winner.them"].tap()
        XCTAssertEqual(any("racket.tag.soFar").label, "4–1–2", "after this rally: server 1 lost, no point")
        XCTAssertEqual(any("racket.tag.serving").label, "You, server 2")
    }

    func testPickleballSinglesTagSaysWhoServesNext() {
        openTagSheet("pickleball", doubles: false)
        XCTAssertEqual(any("racket.tag.soFar").label, "5–1")
        XCTAssertEqual(any("racket.tag.serving").label, "You’re serving")
        app.buttons["racket.tag.winner.us"].tap()
        XCTAssertEqual(any("racket.tag.soFar").label, "6–1")
        XCTAssertEqual(any("racket.tag.serving").label, "You serving next")
        shot("pb-08-tag")
    }

    func testDoublesTagNamesTheServerInEverySport() {
        for (sport, line) in [("badminton", "You’re serving, right court"), ("tableTennis", "Mia serving"),
                              ("tennis", "Mia serving"), ("squash", "Us serving")] {
            openTagSheet(sport, doubles: true)
            XCTAssertEqual(any("racket.tag.serving").label, line, sport)
            shot("\(sport)-doubles-tag")
        }
    }
}
