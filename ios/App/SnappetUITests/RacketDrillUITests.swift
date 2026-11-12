import XCTest

/// UI coverage for **drill parity** (prompt 250, issue #438): the drill library (category chips, Video helps / Timer,
/// New), SetupFirst's gate and Customize, Setup's summary rows, Camera check → BlockStart → Block (BlockOff) ⇄ Paused →
/// Rest (RestOff: log, feel, auto-start, More options) ⇄ RestPaused → Finish → Review → See progress (DrillTrend) and
/// back, the page's Review drill; squash's solo drill; and each sport's drill boards for the screenshots.
/// `-uiTestFakeCamera` runs the recorder as a stand-in. Set `RACKET_SHOTS=<dir>` to write screenshots.
final class RacketDrillUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestFakeCamera"]
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

    private func openDrills(_ sport: String) {
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
        app.segmentedControls["racket.mode"].buttons["Drill"].tap()
        app.buttons["racket.next"].tap()
        XCTAssertTrue(any("racket.drillCats").waitForExistence(timeout: 5), "the drill library")
    }

    /// SetupFirst → Customize: practising, focus (hand + stroke), pattern, a court zone; Save.
    private func customize(practising: String, stroke: String, pattern: String, shotName: String? = nil) {
        tapWhenHittable(app.buttons["racket.plan.row.practising"])
        XCTAssertTrue(app.buttons["racket.custom.save"].waitForExistence(timeout: 4), "Drill details")
        tapWhenHittable(app.buttons["racket.custom.practising.\(practising)"])
        tapWhenHittable(app.buttons["racket.custom.hand.Forehand"])
        tapWhenHittable(app.buttons["racket.custom.stroke.\(stroke)"])
        tapWhenHittable(app.buttons["racket.custom.pattern.\(pattern)"])
        tapWhenHittable(app.buttons["racket.custom.zone.8"])
        if let shotName { shot(shotName) }
        app.buttons["racket.custom.save"].tap()
    }

    func testBlockByBlockDrillPauseRestReviewAndProgress() {
        openDrills("tableTennis")
        XCTAssertTrue(app.buttons["racket.drillCat.Serve"].exists, "TT categories")
        XCTAssertTrue(app.buttons["racket.drillCat.Game-like"].exists)
        let first = app.buttons.matching(identifier: "racket.drill").firstMatch
        XCTAssertTrue(first.label.contains("Forehand loop vs block"), first.label)
        XCTAssertTrue(first.label.contains("Video helps"), first.label)
        XCTAssertTrue(first.label.contains("New"), "never done: New")
        shot("tt-01-drills")
        app.buttons["racket.drillCat.Footwork"].tap()
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "identifier == 'racket.drill' AND label CONTAINS 'Timer'")).count, 0,
                             "timed drills say Timer")
        app.buttons["racket.drillCat.All"].tap()
        app.buttons.matching(identifier: "racket.drill").firstMatch.tap()

        // SetupFirst: the gate until practising and focus are chosen.
        XCTAssertTrue(any("racket.plan.heading").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.plan.heading").label, "First time with this drill")
        XCTAssertFalse(app.buttons["racket.plan.start"].isEnabled)
        XCTAssertEqual(any("racket.plan.gate").label, "Choose what you’re practising and your focus first.")
        XCTAssertTrue(app.buttons["racket.plan.row.practising"].label.contains("Choose"))
        XCTAssertTrue(app.buttons["racket.plan.row.goal"].label.contains("None yet"))
        shot("tt-02-setup-first")
        customize(practising: "With a partner", stroke: "Topspin", pattern: "Cross-court", shotName: "tt-03-customize")
        XCTAssertTrue(app.buttons["racket.plan.start"].isEnabled)
        XCTAssertTrue(app.buttons["racket.plan.row.focus"].label.contains("Forehand topspin"), app.buttons["racket.plan.row.focus"].label)
        XCTAssertEqual(app.buttons["racket.plan.start"].label, "Set up camera")
        XCTAssertFalse(app.switches["racket.plan.tracking"].isEnabled, "live tracking: not available yet")
        shot("tt-04-setup")
        app.buttons["racket.plan.start"].tap()

        // Camera check (guide placeholder) → BlockStart.
        let cont = app.buttons["racket.camera.continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 8))
        XCTAssertTrue(any("racket.camera.guide").exists)
        XCTAssertEqual(any("racket.camera.next").label, "Next: warmup for a match, or a countdown to block 1 for a drill.")
        shot("tt-05-camera")
        cont.tap()
        XCTAssertTrue(any("racket.rec.countdown").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.rec.countdownLine").label, "Recording and the block timer start at zero")
        shot("tt-06-countdown")

        // BlockOff: ● Recording · Block 1 of 3 · Phone OK; the ring; the line; tracking row; switcher; Pause / End block.
        let pause = app.buttons["racket.rec.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 12))
        XCTAssertTrue(any("racket.rec.status").label.hasPrefix("● Recording"), any("racket.rec.status").label)
        XCTAssertEqual(any("racket.drill.header").label, "Block 1 of 3")
        XCTAssertEqual(any("racket.rec.phone").label, "Phone OK")
        XCTAssertTrue(any("racket.rec.preview").exists, "the block opens on the camera")
        app.buttons["racket.rec.show.dim"].tap()
        XCTAssertEqual(any("racket.drill.line").label,
                       "Recording. Log your longest rally at the end of the block, or find rallies afterwards.")
        XCTAssertEqual(app.buttons["racket.rec.trackingTurnOn"].label, "Not available yet")
        XCTAssertFalse(app.buttons["racket.rec.trackingTurnOn"].isEnabled)
        shot("tt-07-block-off")
        app.buttons["racket.rec.show.stats"].tap()
        XCTAssertTrue(any("racket.drill.liveCounts").waitForExistence(timeout: 3), "live counts: not available yet")
        shot("tt-08-block-stats")
        app.buttons["racket.rec.show.dim"].tap()

        // Paused → Resume.
        pause.tap()
        XCTAssertTrue(app.buttons["racket.paused.resume"].waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.rec.status").label, "Ⅱ Recording paused")
        XCTAssertEqual(any("racket.rec.phase").label, "Paused")
        XCTAssertTrue(any("racket.paused.line").label.hasPrefix("Picking up balls"))
        XCTAssertTrue(app.buttons["racket.paused.stop"].exists)
        shot("tt-09-paused")
        app.buttons["racket.paused.resume"].tap()
        XCTAssertTrue(app.buttons["racket.rec.endBlock"].waitForExistence(timeout: 4))
        app.buttons["racket.rec.endBlock"].tap()

        // RestOff: Ⅱ Recording paused · Block 1 done; ring; log; feel; auto-start; More options; Finish drill.
        XCTAssertTrue(app.buttons["racket.rec.pauseRest"].waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.rec.status").label, "Ⅱ Recording paused")
        XCTAssertEqual(any("racket.drill.header").label, "Block 1 done")
        XCTAssertEqual(any("racket.rest.source").label, "You enter this")
        app.buttons["racket.rest.rally.plus"].tap()
        app.buttons["racket.rest.rally.plus"].tap()
        XCTAssertEqual(any("racket.rest.rally").label, "2")
        tapWhenHittable(app.buttons["racket.rest.feel.hard"])
        XCTAssertTrue(app.buttons["racket.rest.feel.hard"].isSelected)
        XCTAssertTrue(app.buttons["racket.rest.more"].exists)
        shot("tt-10-rest")
        app.buttons["racket.rec.pauseRest"].tap()
        XCTAssertTrue(app.buttons["racket.rec.resumeRest"].waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.rec.phase").label, "Rest, paused")
        XCTAssertEqual(any("racket.rest.pausedLine").label, "Block 2 won’t start until you resume. Take your time.")
        shot("tt-11-rest-paused")
        app.buttons["racket.rec.stop"].tap()
        let confirm = app.buttons.matching(identifier: "racket.rec.confirmStop").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4))
        confirm.tap()

        // Review → See progress → back → Done (the hub).
        XCTAssertTrue(any("racket.review.headline").waitForExistence(timeout: 6))
        XCTAssertEqual(any("racket.review.headline").label, "2 shots")
        XCTAssertTrue(any("racket.review.blocksLine").label.hasPrefix("1 block · "), any("racket.review.blocksLine").label)
        XCTAssertTrue(any("racket.review.tags").label.contains("With a partner"))
        XCTAssertTrue(any("racket.review.tagShots").label.contains("Not available yet"))
        shot("tt-12-review")
        app.buttons["racket.review.progress"].tap()
        XCTAssertTrue(any("racket.trend.stats").waitForExistence(timeout: 4))
        XCTAssertTrue(any("racket.trend.chart").exists)
        XCTAssertEqual(any("racket.trend.feel").label, "Hard over the last 1 session")
        XCTAssertFalse(app.buttons["racket.trend.metric.shotMix"].isEnabled)
        shot("tt-13-trend")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["racket.review.done"].waitForExistence(timeout: 4))
        app.buttons["racket.review.back"].tap()

        // The page: Review drill reopens the review; Continue drill.
        XCTAssertTrue(app.buttons["racket.page.drillReview"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons["racket.page.drillStart"].label, "Continue drill")
        app.buttons["racket.page.drillReview"].tap()
        XCTAssertTrue(any("racket.review.headline").waitForExistence(timeout: 6))
        app.buttons["racket.review.done"].tap()
        XCTAssertTrue(any("freeform.disciplineRibbon").waitForExistence(timeout: 6), "Done goes to the session hub")
    }

    func testSquashSoloDrillAndTheDrillBoardsPerSport() {
        openDrills("squash")
        XCTAssertTrue(app.buttons["racket.drillCat.Ghosting"].exists)
        app.buttons["racket.drillCat.Solo"].tap()
        let solo = app.buttons.matching(identifier: "racket.drill").firstMatch
        XCTAssertTrue(solo.label.contains("Solo rally"), solo.label)
        shot("squash-01-drills")
        solo.tap()
        XCTAssertTrue(any("racket.plan.heading").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.plan.heading").label, "Solo drill")
        XCTAssertTrue(app.buttons["racket.plan.start"].isEnabled, "solo: no practising gate")
        app.buttons["racket.solo.plus"].tap()
        XCTAssertEqual(any("racket.solo.value").label, "1")
        XCTAssertTrue(app.buttons["racket.plan.row.recordingRow"].exists)
        shot("squash-02-solo")
    }

    /// Each sport's library, customize chips and block → rest → review, for the board re-check.
    func testEverySportsDrillScreens() {
        let sports: [(id: String, practising: String, stroke: String, pattern: String, cat: String)] = [
            ("badminton", "Feeder", "Drive", "Straight", "Net play"),
            ("tennis", "Ball machine", "Slice", "Inside-out", "Volley"),
            ("pickleball", "Drilling group", "Dink", "Middle", "Dink"),
            ("padel", "Coach feeding", "Bandeja", "Off the wall", "Wall"),
            ("squash", "Coach feeding", "Boast", "Length", "Length"),
        ]
        for (k, s) in sports.enumerated() {
            if k > 0 { app.terminate(); app.launch() }
            openDrills(s.id)
            XCTAssertTrue(app.buttons["racket.drillCat.\(s.cat)"].exists, "\(s.id) categories")
            shot("\(s.id)-01-drills")
            app.buttons.matching(identifier: "racket.drill").firstMatch.tap()
            XCTAssertTrue(any("racket.plan.heading").waitForExistence(timeout: 5))
            customize(practising: s.practising, stroke: s.stroke, pattern: s.pattern, shotName: "\(s.id)-02-customize")
            tapWhenHittable(app.buttons["racket.recording.byUnit"])
            shot("\(s.id)-03-setup")
            tapWhenHittable(app.buttons["racket.plan.start"])
            XCTAssertTrue(app.buttons["racket.camera.continue"].waitForExistence(timeout: 8))
            app.buttons["racket.camera.continue"].tap()
            XCTAssertTrue(app.buttons["racket.rec.pause"].waitForExistence(timeout: 12))
            app.buttons["racket.rec.show.dim"].tap()
            shot("\(s.id)-04-block")
            app.buttons["racket.rec.pause"].tap()
            XCTAssertTrue(app.buttons["racket.paused.resume"].waitForExistence(timeout: 4))
            XCTAssertEqual(any("racket.paused.line").label, "Nothing is recorded or counted while paused.")
            shot("\(s.id)-05-paused")
            app.buttons["racket.paused.endBlock"].tap()
            XCTAssertTrue(app.buttons["racket.rec.pauseRest"].waitForExistence(timeout: 4))
            shot("\(s.id)-06-rest")
            app.buttons["racket.rec.stop"].tap()
            app.buttons.matching(identifier: "racket.rec.confirmStop").firstMatch.tap()
            XCTAssertTrue(any("racket.review.headline").waitForExistence(timeout: 6))
            shot("\(s.id)-07-review")
        }
    }
}
