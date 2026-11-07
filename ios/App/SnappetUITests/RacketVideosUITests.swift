import XCTest

/// UI coverage for **racket videos, split and manual tagging** (prompt 246, issue #438 step 3). Seeded by
/// `-uiTestSeedRacketVideos`: a finished session with a 1:14:10 match recorded everything (the boards' marks and two
/// Watch games) and a drill recorded everything. No Photos video in the simulator, so the player runs its stand-in clock.
@MainActor
final class RacketVideosUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
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
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6), "Your videos (FindRallies: every sport has the placeholder model, prompt 248)")
    }

    func testSplitTheMatchThenMarkAndTagARally() {
        openYourVideos()
        XCTAssertTrue(any("racket.videos.line.0").label.hasSuffix("not split yet"))

        // Split recording → Review: the boards' parts.
        app.buttons["racket.videos.split"].tap()
        XCTAssertTrue(app.buttons["racket.split.apply"].waitForExistence(timeout: 5), "the review should open")
        XCTAssertTrue(app.buttons["racket.split.part.1"].label.contains("11–9 from Watch"), app.buttons["racket.split.part.1"].label)
        let unsure = app.buttons["racket.split.part.6"]
        XCTAssertTrue(unsure.label.contains("an extra game or practice?"), unsure.label)

        // TtSplitEdit: the unsure stretch is an extra game of this match; nudge its start.
        unsure.tap()
        let save = app.buttons["racket.split.edit.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.split.edit.range").label, "1:06:30–1:12:00")
        app.buttons["racket.split.edit.start.10"].tap()
        XCTAssertEqual(any("racket.split.edit.range").label, "1:06:40–1:12:00")
        app.buttons["racket.split.edit.belongs.thisMatch"].tap()
        save.tap()
        XCTAssertTrue(app.buttons["racket.split.part.6"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["racket.split.part.6"].label.contains("Extra game"), app.buttons["racket.split.part.6"].label)

        // Apply → Assign: game 3 has no score; it was logged "Score unconfirmed" and can be entered.
        tapWhenHittable(app.buttons["racket.split.apply"])
        XCTAssertTrue(any("racket.assign.missing").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.assign.missing").label, "Game 3 has video but no score")
        XCTAssertTrue(any("racket.assign.row.0").label.contains("Game 1 · 11–9"), any("racket.assign.row.0").label)
        XCTAssertTrue(any("racket.assign.row.3").label.contains("Extra game"), any("racket.assign.row.3").label)
        app.buttons["racket.assign.save"].tap()

        // SplitDone: 4 parts, no extra space; Done → Your videos.
        XCTAssertTrue(any("racket.splitDone.count").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.splitDone.count").label, "4 parts saved")
        XCTAssertTrue(app.buttons["racket.splitDone.delete"].exists, "a match offers to delete its original")
        app.buttons["racket.splitDone.done"].tap()
        XCTAssertTrue(any("racket.videos.line.0").waitForExistence(timeout: 5))
        XCTAssertTrue(any("racket.videos.line.0").label.hasPrefix("11–9"), any("racket.videos.line.0").label)
        XCTAssertEqual(any("racket.videos.chip.0").label, "From Watch")
        XCTAssertEqual(any("racket.videos.chip.2").label, "Unconfirmed")

        // Mark rallies on game 1 (TtNoModelTimeline): start, +5 s, end.
        app.buttons["racket.videos.mark.0"].tap()
        let markStart = app.buttons["racket.tl.markStart"]
        XCTAssertTrue(markStart.waitForExistence(timeout: 5))
        markStart.tap()
        app.buttons["racket.tl.fwd5"].tap()
        app.buttons["racket.tl.markEnd"].tap()
        XCTAssertEqual(any("racket.tl.count").label, "1 rally marked · 0 tagged")

        // Tag it (TtNoModelTag): nothing preselected; You won, Out, Next → TagDone.
        app.buttons["racket.tl.tag"].tap()
        let next = app.buttons["racket.tag.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["racket.tag.winner.us"].isSelected, "nothing is picked for you")
        app.buttons["racket.tag.winner.us"].tap()
        app.buttons["racket.tag.end.out"].tap()
        next.tap()
        XCTAssertTrue(any("racket.tagDone.checked").waitForExistence(timeout: 6), "tagging the last rally shows TagDone")
        XCTAssertEqual(any("racket.tagDone.checked").label, "1 of 1 checked")

        // From your tags (TtManualSummary).
        app.buttons["racket.tagDone.summary"].tap()
        XCTAssertTrue(any("racket.summary.marked").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.summary.marked").label, "1")
        XCTAssertEqual(any("racket.summary.tagged").label, "1")
        XCTAssertEqual(any("racket.summary.source").label, "From your tags, 1 of 1")
        app.buttons["racket.summary.done"].tap()
        XCTAssertTrue(any("racket.videos.tags.0").waitForExistence(timeout: 4))
        XCTAssertEqual(any("racket.videos.tags.0").label, "1 marked by you")

        // The player plays the part; Analyzed shows your tag at the rally.
        app.buttons["racket.videos.play.0"].tap()
        XCTAssertTrue(any("racket.player.clock").waitForExistence(timeout: 5))
        XCTAssertTrue(any("racket.player.standIn").exists, "no Photos video in the simulator")
        app.segmentedControls["racket.player.mode"].buttons["Analyzed"].tap()
        XCTAssertTrue(any("racket.player.overlay").waitForExistence(timeout: 3), "the tag shows over the rally")
        XCTAssertTrue(any("racket.player.overlay").label.hasPrefix("Rally 1 · You won · Out"), any("racket.player.overlay").label)
    }

    func testDrillVideosListBlocksAndNeverOfferDelete() {
        openYourVideos()
        tapWhenHittable(app.buttons["racket.videos.drill"])
        XCTAssertTrue(any("racket.drill.line.0").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.drill.line.0").label, "5:00 · not marked")
        XCTAssertTrue(any("racket.drill.line.2").exists, "three block parts")
        XCTAssertFalse(app.buttons["racket.splitDone.delete"].exists)
        app.buttons["racket.drill.mark.1"].tap()
        XCTAssertTrue(app.buttons["racket.tl.markStart"].waitForExistence(timeout: 5))
        app.buttons["racket.tl.markStart"].tap()
        app.buttons["racket.tl.fwd5"].tap()
        app.buttons["racket.tl.markEnd"].tap()
        XCTAssertEqual(any("racket.tl.count").label, "1 rally marked · 0 tagged")
    }
}
