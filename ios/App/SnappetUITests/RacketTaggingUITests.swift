import XCTest

/// UI coverage for **tagging with video** (prompt 251, issue #438): the tag sheet shows the rally's video, the rules
/// sheet, FixRally with video and "What went wrong?", "+ Add a missed rally", shot-by-shot tagging by hand,
/// EditScore's "Which game", and SplitPhotos. Seeded by `-uiTestSeedRacketVideos`; `-uiTestRacketBundledVideo` lays the
/// bundled 3 s clip over the drill's first minute so the simulator shows real frames.
@MainActor
final class RacketTaggingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestRacketBundledVideo",
                                "-uiTestPickPhotosVideo"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    private func openYourVideos() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 8))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Racket videos'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "the seeded session")
        row.tap()
        tapWhenHittable(app.buttons["racket.recap.videos"])
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6))
    }

    func testTagFixAddAndShotsShowTheRallysVideo() {
        openYourVideos()
        tapWhenHittable(app.buttons["racket.videos.drill"])
        XCTAssertTrue(app.buttons["racket.drill.mark.0"].waitForExistence(timeout: 5))
        app.buttons["racket.drill.mark.0"].tap()

        // Mark a rally inside the bundled clip's minute.
        let markStart = app.buttons["racket.tl.markStart"]
        XCTAssertTrue(markStart.waitForExistence(timeout: 5))
        app.buttons["racket.tl.fwd5"].tap()
        markStart.tap()
        app.buttons["racket.tl.fwd5"].tap()
        app.buttons["racket.tl.markEnd"].tap()
        XCTAssertEqual(any("racket.tl.count").label, "1 rally marked · 0 tagged")
        XCTAssertTrue(any("racket.tl.shotsNotYet").exists, "the shot count says Not available yet")

        // Tag sheet: the rally's video at the top (real frames, no stand-in), then the rules sheet.
        app.buttons["racket.tl.tag"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 4))
        XCTAssertTrue(any("racket.rallyVideo").exists, "the tag sheet shows the rally's video")
        XCTAssertTrue(any("racket.rallyVideo.play").waitForExistence(timeout: 6), "the video loaded")
        XCTAssertFalse(any("racket.player.standIn").exists, "real frames, not the stand-in")
        XCTAssertEqual(any("racket.tag.title").label, "Your rally 1 of 1")
        XCTAssertTrue(any("racket.tag.marked").label.hasPrefix("Marked 0:05"), any("racket.tag.marked").label)
        shot("tag-sheet-video")
        app.buttons["racket.tag.rules"].tap()
        XCTAssertTrue(any("racket.rules.row.0").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.rules.footer").label, "Snappet may miss these on video. Your tag always wins.")
        shot("rules")
        app.buttons["racket.rules.close"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 4))
        app.buttons["racket.tag.close"].tap()

        // Fix rally 1: video, strip, "What went wrong?" chips.
        tapWhenHittable(app.buttons["racket.tl.fix.0"])
        XCTAssertTrue(app.buttons["racket.fix.save"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.navigationBars["Fix rally 1"].exists)
        XCTAssertTrue(any("racket.fix.video").exists, "Fix shows the rally's video")
        XCTAssertFalse(any("racket.player.standIn").waitForExistence(timeout: 3), "real frames")
        XCTAssertTrue(any("racket.fix.reason.wrongCourt").label == "Wrong table", "table tennis says Wrong table")
        app.buttons["racket.fix.reason.startedLate"].tap()
        XCTAssertTrue(app.buttons["racket.fix.reason.startedLate"].isSelected)
        app.buttons["racket.fix.start.-1.0"].tap()
        shot("fix-rally-video")
        app.buttons["racket.fix.save"].tap()

        // + Add a missed rally at the playhead (after the rally) → FixRally in add mode → 2 rallies.
        XCTAssertTrue(app.buttons["racket.tl.fwd5"].waitForExistence(timeout: 4))
        app.buttons["racket.tl.fwd5"].tap()
        tapWhenHittable(app.buttons["racket.tl.addMissed"])
        XCTAssertTrue(app.buttons["racket.fix.save"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.navigationBars["Add a rally"].exists)
        app.buttons["racket.fix.save"].tap()
        XCTAssertTrue(any("racket.tl.count").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.tl.count").label, "2 rallies marked · 0 tagged")

        // Shots (by hand): two shots, a type, Save → the row counts them.
        tapWhenHittable(app.buttons["racket.tl.shots.0"])
        XCTAssertTrue(app.buttons["racket.shots.add"].waitForExistence(timeout: 4))
        XCTAssertTrue(any("racket.shots.notYet").exists, "shot finding says Not available yet")
        app.buttons["racket.shots.add"].tap()
        app.buttons["racket.shots.add"].tap()
        XCTAssertEqual(any("racket.shots.count").label, "2 shots")
        XCTAssertEqual(app.buttons["racket.shots.hand.1"].label, "FH")
        app.buttons["racket.shots.hand.1"].tap()
        XCTAssertEqual(app.buttons["racket.shots.hand.1"].label, "BH")
        app.buttons["racket.shots.type.1"].tap()
        app.buttons["Push"].tap()
        XCTAssertEqual(app.buttons["racket.shots.type.1"].label, "Push")
        shot("shots")
        app.buttons["racket.shots.save"].tap()
        XCTAssertTrue(app.buttons["racket.tl.rally.0"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.tl.rally.0"].label.contains("2 shots"), app.buttons["racket.tl.rally.0"].label)
    }

    func testEditScoreOpensOnTheTappedGameWithWhichGameChips() {
        openYourVideos()
        app.buttons["racket.videos.split"].firstMatch.tap()
        XCTAssertTrue(app.buttons["racket.split.apply"].waitForExistence(timeout: 5))
        tapWhenHittable(app.buttons["racket.split.apply"])
        XCTAssertTrue(app.buttons["racket.assign.enterScore"].waitForExistence(timeout: 5))
        app.buttons["racket.assign.enterScore"].tap()
        XCTAssertTrue(app.buttons["racket.editScore.saveScore"].waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons["racket.editScore.game.0"].label, "Game 1 · unconfirmed")
        XCTAssertTrue(app.buttons["racket.editScore.game.2"].isSelected, "opens on the game tapped")
        XCTAssertEqual(app.buttons["racket.editScore.game.2"].label, "Game 3 · no score")
        app.buttons["racket.editScore.game.0"].tap()
        XCTAssertEqual(any("racket.editScore.source").label, "From your Watch")
        XCTAssertEqual(any("racket.editScore.mine").label, "11")
        shot("edit-score")
        app.buttons["racket.editScore.saveScore"].tap()
        XCTAssertTrue(app.buttons["racket.editScore.saveScore"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(any("racket.assign.row.0").label.contains("11–9"), any("racket.assign.row.0").label)
    }

    func testAddFromPhotosLinesUpAndFindsTheSplit() {
        openYourVideos()
        tapWhenHittable(app.buttons["racket.videos.addFromPhotos"])
        XCTAssertTrue(app.buttons["racket.splitPhotos.find"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Add a video"].exists)
        XCTAssertEqual(any("racket.splitPhotos.target").label, "Match vs Sam")
        XCTAssertTrue(any("racket.splitPhotos.when").label.hasSuffix("0:03"), any("racket.splitPhotos.when").label)
        shot("split-photos")
        app.buttons["racket.splitPhotos.find"].tap()
        XCTAssertTrue(app.buttons["racket.split.apply"].waitForExistence(timeout: 5), "Find games and drills → the split review")
    }

    // MARK: Per-sport board walks (screenshots for the re-check)

    private func relaunch(sport: String, doubles: Bool) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestRacketSport", sport]
        if doubles { app.launchArguments += ["-uiTestRacketDoubles", "YES"] }
        app.launch()
    }

    private func walk(_ sport: String, doubles: Bool = false) {
        relaunch(sport: sport, doubles: doubles)
        let p = doubles ? "\(sport)-doubles" : sport
        openYourVideos()
        shot("\(p)-01-videos")
        app.buttons["racket.videos.mark.0"].tap()
        let markStart = app.buttons["racket.tl.markStart"]
        XCTAssertTrue(markStart.waitForExistence(timeout: 5))
        markStart.tap()
        app.buttons["racket.tl.fwd5"].tap()
        app.buttons["racket.tl.markEnd"].tap()
        shot("\(p)-02-timeline")
        app.buttons["racket.tl.tag"].tap()
        XCTAssertTrue(app.buttons["racket.tag.next"].waitForExistence(timeout: 4))
        XCTAssertTrue(any("racket.rallyVideo").exists)
        if doubles { XCTAssertTrue(any("racket.tag.serving").exists, "DoublesTag's serve line") }
        shot("\(p)-03-tag")
        app.swipeUp()
        shot("\(p)-03b-tag-lower")
        tapWhenHittable(app.buttons["racket.tag.rules"])
        XCTAssertTrue(any("racket.rules.footer").waitForExistence(timeout: 4))
        shot("\(p)-04-rules")
        app.buttons["racket.rules.close"].tap()
        XCTAssertTrue(app.buttons["racket.tag.close"].waitForExistence(timeout: 4))
        app.buttons["racket.tag.close"].tap()
        tapWhenHittable(app.buttons["racket.tl.fix.0"])
        XCTAssertTrue(app.buttons["racket.fix.save"].waitForExistence(timeout: 4))
        shot("\(p)-05-fix")
        app.buttons["racket.fix.cancel"].tap()
        tapWhenHittable(app.buttons["racket.tl.shots.0"])
        XCTAssertTrue(app.buttons["racket.shots.add"].waitForExistence(timeout: 4))
        app.buttons["racket.shots.add"].tap()
        app.buttons["racket.shots.add"].tap()
        app.buttons["racket.shots.add"].tap()
        shot("\(p)-06-shots")
        app.buttons["racket.shots.back"].tap()
        if !doubles {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["racket.videos.settings"].waitForExistence(timeout: 4))
            app.buttons["racket.videos.settings"].tap()
            XCTAssertTrue(any("racket.analysisSettings.live").waitForExistence(timeout: 4))
            shot("\(p)-07-settings")
            tapWhenHittable(app.buttons["racket.analysisSettings.caps"])
            XCTAssertTrue(any("racket.caps.title").waitForExistence(timeout: 4))
            shot("\(p)-08-capabilities")
        }
    }

    func testWalkTableTennis() { walk("tableTennis") }
    func testWalkBadminton() { walk("badminton") }
    func testWalkTennis() { walk("tennis") }
    func testWalkPickleball() { walk("pickleball") }
    func testWalkPadel() { walk("padel") }
    func testWalkSquash() { walk("squash") }
    func testWalkDoublesTableTennis() { walk("tableTennis", doubles: true) }
    func testWalkDoublesBadminton() { walk("badminton", doubles: true) }
    func testWalkDoublesTennis() { walk("tennis", doubles: true) }
    func testWalkDoublesPickleball() { walk("pickleball", doubles: true) }
    func testWalkDoublesPadel() { walk("padel", doubles: true) }
    func testWalkDoublesSquash() { walk("squash", doubles: true) }
}
