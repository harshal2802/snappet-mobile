import XCTest

/// UI coverage for **game-by-game match recording and setup parity** (prompt 249, issue #438): the Match board's
/// form (header, format chips, Set up camera / Play without video, What works), Camera check → Warmup → the game screen
/// (Dim · Camera · Stats, tracking row off) → Next game → Score (SaveGame) → Break (GameBreak) → Countdown → Game 2 →
/// Stop → Save, match over → Your videos; scoring without video (ScoreOnly) with Later; padel's deuce step; and the
/// hub's Your videos. `-uiTestFakeCamera` runs the recorder as a stand-in. Set `RACKET_SHOTS=<dir>` to write screenshots.
final class RacketMatchUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestFakeCamera", "-uiTestWatchReady"]
        app.launchEnvironment["SNAPPET_FAKE_CAMERA"] = "1"
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

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 5 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private func openMatchForm(_ sport: String = "tableTennis") {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        tapWhenHittable(app.buttons["freeform.cardRacket"])
        let s = app.buttons["racket.sport.\(sport)"]
        XCTAssertTrue(s.waitForExistence(timeout: 5))
        s.tap()
        app.segmentedControls["racket.mode"].buttons["Match"].tap()
        app.buttons["racket.next"].tap()
    }

    func testGameByGameRecordsAGameThenBreakCountdownAndMatchOver() {
        openMatchForm()
        // Match board: the live header, format chips, players, film, Watch ready, two starts, What works.
        XCTAssertTrue(any("racket.match.header").waitForExistence(timeout: 5))
        XCTAssertTrue(any("racket.match.format").label.contains("Best of 5"), any("racket.match.format").label)
        XCTAssertTrue(any("racket.match.format").label.contains("Games to 11"))
        XCTAssertTrue(app.buttons["racket.format.bestOf3"].exists)
        app.buttons["racket.format.bestOf3"].tap()
        XCTAssertTrue(any("racket.match.format").label.contains("Best of 3"), "the header follows the chips")
        let opponent = app.textFields["racket.opponent"]
        opponent.tap()
        opponent.typeText("Alex\n")
        XCTAssertTrue(any("racket.match.watchReady").exists, "Apple Watch ready · Score from your wrist")
        XCTAssertTrue(app.buttons["racket.match.playWithoutVideo"].exists)
        XCTAssertTrue(any("racket.match.whatWorks").exists, "What works for table tennis")
        shot("match-form")
        tapWhenHittable(app.buttons["racket.match.setUpCamera"])

        // Camera check (NoModelCamera) → Warmup.
        XCTAssertTrue(any("racket.camera.title").waitForExistence(timeout: 8))
        XCTAssertEqual(any("racket.camera.title").label, "Line up the view yourself")
        shot("camera-check")
        app.buttons["racket.camera.continue"].tap()
        XCTAssertTrue(any("racket.warmup.title").waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.warmup.mode.byUnit"].isSelected, "Game by game by default")
        XCTAssertFalse(app.switches["racket.warmup.tracking"].isEnabled, "live tracking isn't built: off, disabled")
        XCTAssertTrue(app.buttons["racket.warmup.serve.them"].label == "Alex")
        app.buttons["racket.warmup.serve.us"].tap()
        XCTAssertTrue(app.buttons["racket.warmup.show.dim"].isSelected, "During play, show: Dim")
        shot("warmup")
        app.buttons["racket.warmup.start"].tap()

        // DimOff.
        let status = any("racket.game.status")
        XCTAssertTrue(status.waitForExistence(timeout: 6))
        XCTAssertTrue(status.label.hasPrefix("Recording"), status.label)
        XCTAssertEqual(any("racket.game.unit").label, "Game 1")
        XCTAssertEqual(any("racket.game.phone").label, "Phone OK")
        XCTAssertEqual(any("racket.game.score").label, "0 – 0")
        XCTAssertEqual(any("racket.game.line").label, "Recording. Rallies will be found after the game.")
        XCTAssertTrue(app.buttons["racket.game.mark"].exists)
        XCTAssertFalse(app.buttons["racket.rec.trackingTurnOn"].isEnabled, "Turn on stays disabled until step 6")
        shot("dim-off")
        app.buttons["racket.game.mark"].tap()
        // CameraViewOff, StatsOff.
        app.buttons["racket.rec.show.camera"].tap()
        XCTAssertTrue(any("racket.game.preview").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.game.cameraScore").exists)
        shot("camera-view-off")
        app.buttons["racket.rec.show.stats"].tap()
        XCTAssertTrue(any("racket.rec.stats.gameTime").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.rec.stats.hr").exists, "StatsOff: Heart rate")
        XCTAssertTrue(any("racket.rec.stats.points").label.contains("Points played"))
        XCTAssertEqual(any("racket.rec.stats.after").label, "Rally and shot stats appear after the game.")
        shot("stats-off")
        app.buttons["racket.rec.show.dim"].tap()

        // Next game → SaveGame.
        app.buttons["racket.game.next"].tap()
        let subtitle = any("racket.save.subtitle")
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5), "the score sheet opens")
        XCTAssertEqual(subtitle.label, "Fix it now or later.")
        XCTAssertTrue(app.buttons["racket.save.later"].exists)
        XCTAssertTrue(app.buttons["racket.save.break.30"].exists, "table tennis offers a 0:30 break")
        XCTAssertTrue(app.buttons["racket.save.break.60"].isSelected, "1:00 by default")
        XCTAssertTrue(app.switches["racket.save.pauseRecording"].exists)
        for _ in 0..<7 { app.buttons["racket.save.theirs.plus"].tap() }
        shot("save-game")
        app.buttons["racket.save.startBreak"].tap()

        // GameBreak → countdown → game 2.
        let breakLine = any("racket.break.line")
        XCTAssertTrue(breakLine.waitForExistence(timeout: 5))
        XCTAssertEqual(breakLine.label, "Game 2 starts by itself after this")
        XCTAssertEqual(any("racket.game.unit").label, "Game 1 saved")
        XCTAssertEqual(any("racket.game.status").label, "Ⅱ Recording paused")
        XCTAssertEqual(any("racket.rec.phase").label, "Break")
        shot("game-break")
        app.buttons["racket.break.pause"].tap()
        XCTAssertEqual(any("racket.rec.phase").label, "Break, paused")
        app.buttons["racket.break.resume"].tap()
        app.buttons["racket.break.skip"].tap()
        XCTAssertTrue(any("racket.countdown.number").waitForExistence(timeout: 3))
        XCTAssertEqual(any("racket.game.status").label, "Starting soon")
        shot("game-countdown")
        app.buttons["racket.countdown.wait"].tap()
        XCTAssertEqual(any("racket.rec.phase").label, "Break, paused", "Wait returns to a paused break timer")
        app.buttons["racket.break.skip"].tap()
        let unit = any("racket.game.unit")
        var waited = 0
        // The countdown header already reads "Game 2"; the game itself starts recording at zero.
        while !any("racket.game.status").label.hasPrefix("Recording") && waited < 20 { Thread.sleep(forTimeInterval: 0.5); waited += 1 }
        XCTAssertEqual(unit.label, "Game 2", "the countdown starts game 2")
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"), "recording starts at zero")

        // Stop → SaveGame → Save, match over → Your videos (Score → Analyzing).
        app.buttons["racket.game.stop"].tap()
        XCTAssertTrue(app.buttons["racket.save.matchOver"].waitForExistence(timeout: 5))
        app.buttons["racket.save.matchOver"].tap()
        let close = app.buttons["racket.videos.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8), "match over with video opens Your videos")
        shot("videos-after-match")
        close.tap()

        // The page: 11–7 and 11–0 decide a best of 3; What works shows in every mode.
        XCTAssertTrue(any("racket.whatWorks").waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons.matching(identifier: "racket.unitChip").count, 2, "two games logged")
        XCTAssertTrue(app.buttons["racket.yourVideos"].exists, "the filmed games are in Your videos")
    }

    func testPlayWithoutVideoScoresPointByPointAndLaterLogsUnconfirmed() {
        openMatchForm()
        tapWhenHittable(app.buttons["racket.match.playWithoutVideo"])
        let line = any("racket.scoreOnly.line")
        XCTAssertTrue(line.waitForExistence(timeout: 6))
        XCTAssertEqual(line.label, "Tap who won each point. A Watch works too.")
        XCTAssertEqual(any("racket.game.status").label, "Not recording")
        XCTAssertEqual(any("racket.game.unit").label, "Game 1")
        app.buttons["racket.scoreOnly.us"].tap()
        app.buttons["racket.scoreOnly.us"].tap()
        app.buttons["racket.scoreOnly.them"].tap()
        XCTAssertEqual(any("racket.game.score").label, "2 – 1")
        app.buttons["racket.scoreOnly.undo"].tap()
        XCTAssertEqual(any("racket.game.score").label, "2 – 0")
        XCTAssertTrue(app.buttons["racket.scoreOnly.record"].exists, "Start recording instead")
        shot("score-only")
        app.buttons["racket.scoreOnly.end"].tap()
        XCTAssertTrue(any("racket.save.mine").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.save.mine").label, "2", "filled in from the tally")
        XCTAssertFalse(app.switches["racket.save.pauseRecording"].exists, "nothing to pause without video")
        app.buttons["racket.save.later"].tap()
        XCTAssertTrue(any("racket.break.line").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.game.status").label, "Not recording")
        app.buttons["racket.break.endMatch"].tap()
        // Back on the page: the game reads "Score unconfirmed".
        let chip = app.buttons.matching(identifier: "racket.unitChip").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        XCTAssertTrue(chip.label.contains("Score unconfirmed"), chip.label)
        XCTAssertTrue(app.buttons["racket.page.scoreOnly"].exists, "Score without video again from the page")
        // The hub (pager overview): Your videos and the footnote.
        app.buttons.matching(identifier: "freeform.rail.0").firstMatch.tap()
        tapWhenHittable(app.buttons["racket.hub.videos"])
        XCTAssertTrue(app.buttons["racket.videos.close"].waitForExistence(timeout: 6), "Your videos from the session")
        app.buttons["racket.videos.close"].tap()
    }

    func testScoreOnlyStartRecordingInsteadKeepsTheTally() {
        openMatchForm()
        tapWhenHittable(app.buttons["racket.match.playWithoutVideo"])
        XCTAssertTrue(app.buttons["racket.scoreOnly.us"].waitForExistence(timeout: 6))
        app.buttons["racket.scoreOnly.us"].tap()
        app.buttons["racket.scoreOnly.record"].tap()
        XCTAssertTrue(app.buttons["racket.camera.continue"].waitForExistence(timeout: 6), "ScoreOnly → Camera")
        app.buttons["racket.camera.continue"].tap()
        app.buttons["racket.warmup.start"].tap()
        XCTAssertTrue(any("racket.game.score").waitForExistence(timeout: 6))
        XCTAssertEqual(any("racket.game.score").label, "1 – 0", "the game in progress keeps its points")
        XCTAssertTrue(any("racket.game.status").label.hasPrefix("Recording"))
    }

    func testPadelSetsItsDeuceRuleBeforeTheMatchForm() {
        openMatchForm("padel")
        let golden = app.buttons["racket.deuce.golden"]
        XCTAssertTrue(golden.waitForExistence(timeout: 5), "PdDeuce: At 40–40 first")
        XCTAssertTrue(app.buttons["racket.deuce.advantage"].isSelected)
        golden.tap()
        XCTAssertTrue(golden.isSelected)
        app.buttons["racket.deuce.superTiebreak"].tap()
        XCTAssertTrue(app.buttons["racket.doubles.doubles"].isSelected, "padel defaults to doubles")
        shot("padel-deuce")
        tapWhenHittable(app.buttons["racket.deuce.continue"])
        XCTAssertTrue(any("racket.match.header").waitForExistence(timeout: 4))
        XCTAssertFalse(any("racket.format").exists, "PdMatch has no format box (it's on Match setup)")
        XCTAssertTrue(any("racket.match.format").label.contains("Sets to 6"))
        shot("padel-match")
    }

    func testBadmintonFormHasGamesToFifteenAndOneGame() {
        openMatchForm("badminton")
        XCTAssertTrue(app.buttons["racket.format.bestOf1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["racket.format.bestOf1"].label, "One game")
        app.buttons["racket.format.pointsTo15"].tap()
        XCTAssertTrue(any("racket.match.format").label.contains("Games to 15"))
        shot("badminton-match")
    }

    // MARK: Per sport

    /// Walk one sport's boards: form → camera check → warmup → DimOff / CameraViewOff / StatsOff → SaveGame → GameBreak
    /// → GameCountdown, checking the sport's copy.
    private func walk(_ sport: String, unit: String, line: String, subtitle: String) {
        openMatchForm(sport)
        if sport == "padel" { tapWhenHittable(app.buttons["racket.deuce.continue"]) }
        XCTAssertTrue(any("racket.match.header").waitForExistence(timeout: 5))
        shot("\(sport)-01-match")
        tapWhenHittable(app.buttons["racket.match.setUpCamera"])
        XCTAssertTrue(app.buttons["racket.camera.continue"].waitForExistence(timeout: 8))
        shot("\(sport)-02-camera")
        app.buttons["racket.camera.continue"].tap()
        XCTAssertTrue(any("racket.warmup.title").waitForExistence(timeout: 4))
        shot("\(sport)-03-warmup")
        app.buttons["racket.warmup.serve.us"].tap()
        app.buttons["racket.warmup.start"].tap()
        XCTAssertTrue(any("racket.game.unit").waitForExistence(timeout: 6))
        XCTAssertEqual(any("racket.game.unit").label, "\(unit) 1")
        XCTAssertEqual(any("racket.game.line").label, line)
        shot("\(sport)-04-dim")
        app.buttons["racket.rec.show.camera"].tap()
        XCTAssertTrue(any("racket.game.preview").waitForExistence(timeout: 3))
        shot("\(sport)-05-camera-view")
        app.buttons["racket.rec.show.stats"].tap()
        XCTAssertTrue(any("racket.rec.stats.hr").waitForExistence(timeout: 3))
        shot("\(sport)-06-stats")
        app.buttons["racket.rec.show.dim"].tap()
        app.buttons["racket.game.next"].tap()
        XCTAssertTrue(any("racket.save.subtitle").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.save.subtitle").label, subtitle)
        shot("\(sport)-07-score")
        app.buttons["racket.save.startBreak"].tap()
        XCTAssertTrue(any("racket.break.line").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.break.line").label, "\(unit) 2 starts by itself after this")
        shot("\(sport)-08-break")
        app.buttons["racket.break.skip"].tap()
        XCTAssertTrue(any("racket.countdown.number").waitForExistence(timeout: 3))
        shot("\(sport)-09-countdown")
    }

    func testBadmintonWalk() {
        walk("badminton", unit: "Game", line: "Recording. Rallies will be found after the match.", subtitle: "Win by 2, capped at 30.")
    }

    func testTennisWalk() {
        walk("tennis", unit: "Set", line: "Recording. Rallies will be found after the match.", subtitle: "Games in this set.")
    }

    func testPickleballWalk() {
        walk("pickleball", unit: "Game", line: "Recording. Rallies will be found after the match.", subtitle: "Win by 2.")
    }

    func testPadelWalk() {
        walk("padel", unit: "Set", line: "Recording. Rallies will be found after the match.", subtitle: "Games in this set.")
    }

    func testSquashWalk() {
        walk("squash", unit: "Game", line: "Recording. Rallies will be found after the match.", subtitle: "Win by 2.")
    }

    func testTableTennisWalk() {
        walk("tableTennis", unit: "Game", line: "Recording. Rallies will be found after the game.", subtitle: "Fix it now or later.")
    }

    /// BdInterval: the leading score reaching 11 starts the interval (scored on the phone here; the Watch does the same).
    func testBadmintonIntervalAtEleven() {
        openMatchForm("badminton")
        tapWhenHittable(app.buttons["racket.match.playWithoutVideo"])
        let us = app.buttons["racket.scoreOnly.us"]
        XCTAssertTrue(us.waitForExistence(timeout: 6))
        for _ in 0..<11 { us.tap() }
        let line = any("racket.interval.line")
        XCTAssertTrue(line.waitForExistence(timeout: 4), "the interval at 11")
        XCTAssertEqual(line.label, "Interval. Someone reached 11 first.")
        XCTAssertEqual(any("racket.rec.phase").label, "Interval")
        XCTAssertTrue(app.switches["racket.interval.pauseRecording"].exists)
        shot("badminton-interval")
        app.buttons["racket.interval.pause"].tap()
        XCTAssertEqual(any("racket.rec.phase").label, "Interval, paused")
        app.buttons["racket.interval.resume"].tap()
        app.buttons["racket.interval.skip"].tap()
        XCTAssertTrue(us.waitForExistence(timeout: 3), "the game continues")
        XCTAssertEqual(any("racket.game.score").label, "11 – 0")
    }

    /// TnTiebreak: 6–6 switches to plain points with the banner.
    func testTennisTiebreakBanner() {
        openMatchForm("tennis")
        tapWhenHittable(app.buttons["racket.match.playWithoutVideo"])
        let us = app.buttons["racket.scoreOnly.us"], them = app.buttons["racket.scoreOnly.them"]
        XCTAssertTrue(us.waitForExistence(timeout: 6))
        for g in 0..<12 { for _ in 0..<4 { (g % 2 == 0 ? us : them).tap() } }
        XCTAssertTrue(any("racket.game.tiebreak").waitForExistence(timeout: 4), "6–6 → the tiebreak")
        XCTAssertEqual(any("racket.game.tiebreakLine").label, "Set 1 · games 6–6 · first to 7, win by 2")
        for _ in 0..<5 { us.tap() }
        for _ in 0..<4 { them.tap() }
        XCTAssertEqual(any("racket.game.score").label, "5 – 4")
        shot("tennis-tiebreak")
    }
}
