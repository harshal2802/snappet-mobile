import XCTest

/// UI coverage for the racket player's **Edit mode and Share** (prompt 254, issue #448 part 1). Seeded as the Watch-mode
/// suite (`-uiTestSeedRacketVideos -uiTestRacketPlayer portrait`): game 1 (5:00) with 21 rallies over a synthetic bundled
/// clip, game 2 (1:00) with none. The `shot` lines feed the board check (see `RacketPlayerUITests`).
@MainActor
final class RacketEditUITests: XCTestCase {
    var app: XCUIApplication!

    private func launch(_ variant: String = "portrait", extra: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestRacketPlayer", variant] + extra
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var surface: XCUIElement { any("racket.player.surface") }
    private var controls: XCUIElement { app.buttons["racket.player.playPause"] }

    private func tapWhenHittable(_ el: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var tries = 0
        while !el.waitForExistence(timeout: tries == 0 ? 4 : 1) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        XCTAssertTrue(el.exists, "\(el) should exist", file: file, line: line)
        tries = 0
        while !el.isHittable && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        el.tap()
    }

    /// History → the seeded session → Your videos → Play on row `k`.
    private func openPlayer(row k: Int = 0) {
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
        tapWhenHittable(app.buttons["racket.videos.play.\(k)"])
        XCTAssertTrue(surface.waitForExistence(timeout: 8) || any("racket.player.missing.title").exists, "the Watch-mode player")
    }

    /// Tap the video where nothing else is (upper middle).
    private func tapVideo(dx: CGFloat = 0.5) {
        surface.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.33)).tap()
    }

    private func showControls() { freshControls() }

    /// The controls with a fresh 3 s before they hide by themselves: if they show (and may be about to fade), hide
    /// them first, then tap again (apart enough not to be a double tap).
    private func freshControls() {
        if controls.exists {
            tapVideo()
            _ = controls.waitForNonExistence(timeout: 2)
            Thread.sleep(forTimeInterval: 0.8)
        }
        tapVideo()
        XCTAssertTrue(controls.waitForExistence(timeout: 3), "the controls show")
    }

    /// Pause with the controls showing (paused, they stay).
    private func pause(file: StaticString = #filePath, line: UInt = #line) {
        freshControls()
        if controls.label == "Pause" { controls.tap() }
        XCTAssertEqual(controls.label, "Play", file: file, line: line)
    }

    /// With the controls showing and paused: back to the first rally, then forward to rally `n`.
    private func goToRally(_ n: Int) {
        let prev = app.buttons["racket.player.prevRally"], next = app.buttons["racket.player.nextRally"]
        for _ in 0..<30 where prev.isEnabled { prev.tap() }
        // Portrait has the label line; landscape only the one-line title ("… · Rally 12 of 21").
        func at(_ k: Int) -> Bool {
            let label = any("racket.player.label")
            return label.exists ? label.label.hasPrefix("Rally \(k) ") : any("racket.player.title").label.contains("Rally \(k) of")
        }
        for _ in 0..<(n - (at(1) ? 1 : 0)) { next.tap() }
        XCTAssertTrue(at(n), "at rally \(n)")
    }

    /// "00:12 / 05:00" → seconds into the part.
    private func seconds(_ el: XCUIElement) -> Int {
        let s = (el.value as? String ?? "").components(separatedBy: " / ").first ?? ""
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : -1
    }

    private func shot(_ name: String, delay: Double = 0.6, hold: Double = 2.5) {
        print("RACKETSHOT:\(name):\(delay)")
        Thread.sleep(forTimeInterval: hold)
    }

    private func button(_ id: String) -> XCUIElement { app.buttons[id].firstMatch }

    /// The Watch player at rally `n` (2 s in), paused, then Edit.
    private func openEdit(row: Int = 0, rally n: Int? = 12) {
        openPlayer(row: row)
        pause()
        if let n {
            goToRally(n)
            controls.tap()
            Thread.sleep(forTimeInterval: 1.5)
            controls.tap()
        }
        button("racket.player.edit").tap()
        XCTAssertTrue(button("racket.edit.done").waitForExistence(timeout: 5), "Edit mode")
    }

    /// Tap the strip `dx` of its width from the left (0.5 = the playhead).
    private func tapStrip(_ dx: CGFloat = 0.5) {
        any("racket.edit.strip").coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
    }

    /// Drag the strip by `dx` of its width (negative = forward in time).
    private func dragStrip(_ dx: CGFloat) {
        let strip = any("racket.edit.strip")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + dx, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    // MARK: Rallies tab

    func testSelectTrimShotsMarkUndoListAndDiscard() {
        launch()
        openEdit()
        XCTAssertEqual(any("racket.edit.count").label, "21 rallies · 20 tagged")
        XCTAssertTrue(any("racket.edit.time").label.hasPrefix("02:4"), any("racket.edit.time").label)
        shot("EditRallies")

        // Tap the rally under the playhead: the inspector.
        tapStrip()
        XCTAssertTrue(any("racket.edit.title").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.edit.title").label.hasPrefix("Rally 12 · 02:42 – 02:48 · 6.2 s"), any("racket.edit.title").label)
        XCTAssertTrue(button("racket.edit.winner.us").isSelected)
        shot("EditSelected")

        // Touch the start handle, nudge −0.2 s twice and −1 s: the readout follows; Undo steps back.
        any("racket.edit.handle.start").tap()
        XCTAssertTrue(any("racket.edit.trimValue").waitForExistence(timeout: 3))
        XCTAssertEqual(any("racket.edit.trimValue").label, "02:42.0")
        button("racket.edit.nudge.-0.2").tap()
        button("racket.edit.nudge.-0.2").tap()
        XCTAssertEqual(any("racket.edit.trimValue").label, "02:41.6")
        XCTAssertEqual(any("racket.edit.length").label, "Length 6.6 s")
        shot("EditTrim")
        button("racket.edit.nudge.-1.0").tap()
        XCTAssertEqual(any("racket.edit.trimValue").label, "02:40.6")
        button("racket.edit.undo").tap()
        XCTAssertEqual(any("racket.edit.trimValue").label, "02:41.6")
        button("racket.edit.trimDone").tap()

        // Shots: + Shot at playhead three times.
        button("racket.edit.shots").tap()
        XCTAssertTrue(any("racket.edit.shotsNotYet").waitForExistence(timeout: 3))
        for _ in 0..<3 { button("racket.edit.addShot").tap() }
        XCTAssertTrue(button("racket.edit.shot.side.2").exists)
        shot("EditShots")
        button("racket.edit.backToRally").tap()

        // + Rally in the gap after rally 12: the video plays while marking; End rally here selects the new rally.
        // Shots left the playhead at the rally's start: tap the gap after it to let go, then drag into the gap.
        tapStrip(0.95)
        XCTAssertFalse(any("racket.edit.title").waitForExistence(timeout: 1), "nothing selected in a gap")
        dragStrip(-0.32)
        button("racket.edit.addRally").tap()
        XCTAssertTrue(any("racket.edit.marking").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 2.5)
        shot("EditMarking", delay: 0.1, hold: 0.8)
        button("racket.edit.endRally").tap()
        XCTAssertTrue(any("racket.edit.title").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.edit.title").label.hasPrefix("Rally 13 · "), any("racket.edit.title").label)
        button("racket.edit.undo").tap()
        XCTAssertFalse(any("racket.edit.title").exists, "Undo took the new rally away")

        // The list: filters with counts, rows jump the strip.
        button("racket.edit.list").tap()
        XCTAssertTrue(button("racket.edit.filter.all").waitForExistence(timeout: 3))
        XCTAssertEqual(button("racket.edit.filter.untagged").label, "Untagged 1")
        shot("EditList")
        button("racket.edit.filter.untagged").tap()
        XCTAssertTrue(button("racket.edit.row.13").exists)
        XCTAssertFalse(button("racket.edit.row.12").exists)
        button("racket.edit.row.13").tap()
        XCTAssertTrue(any("racket.edit.title").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.edit.title").label.hasPrefix("Rally 13 · "))

        // Cancel with changes asks; Keep editing stays; Discard changes leaves nothing changed.
        button("racket.edit.cancel").tap()
        XCTAssertTrue(any("racket.edit.discardLine").waitForExistence(timeout: 3))
        XCTAssertEqual(any("racket.edit.discardLine").label, "You changed 1 rally")
        shot("EditDiscard")
        button("racket.edit.keepEditing").tap()
        XCTAssertTrue(button("racket.edit.done").exists)
        button("racket.edit.cancel").tap()
        button("racket.edit.discard").tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5), "back to the player")
    }

    func testMarkedRallyAndLookAndScorePersistOnDone() {
        launch()
        openEdit()
        dragStrip(-0.32)
        button("racket.edit.addRally").tap()
        XCTAssertTrue(any("racket.edit.marking").waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 2)
        button("racket.edit.endRally").tap()
        XCTAssertTrue(any("racket.edit.title").waitForExistence(timeout: 3))
        button("racket.edit.winner.them").tap()

        // Looks: Warm, for this video.
        button("racket.edit.tab.looks").tap()
        XCTAssertTrue(button("racket.edit.look.warm").waitForExistence(timeout: 3))
        button("racket.edit.look.warm").tap()
        XCTAssertTrue(button("racket.edit.look.warm").isSelected)
        XCTAssertTrue(button("racket.edit.scope.thisVideo").isSelected)
        XCTAssertTrue(any("racket.edit.holdHint").exists)
        shot("EditLooks")

        // Score: game 1 from 11–9 to 11–10 (unfinished: warned, still saved).
        button("racket.edit.tab.score").tap()
        XCTAssertTrue(any("racket.edit.score.theirs").waitForExistence(timeout: 3))
        XCTAssertEqual(any("racket.edit.score.mine").label, "11")
        button("racket.edit.score.theirs.plus").tap()
        XCTAssertEqual(any("racket.edit.score.theirs").label, "10")
        XCTAssertTrue(any("racket.edit.score.warning").exists)
        XCTAssertTrue(any("racket.edit.score.fromTags").label.hasPrefix("From your tags: You 11, Alex 10."),
                      any("racket.edit.score.fromTags").label)
        shot("EditScore")

        button("racket.edit.done").tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        showControls()
        XCTAssertTrue(any("racket.player.subtitle").label.hasSuffix("of 22"), any("racket.player.subtitle").label)

        // Reopen: the look and the score are kept.
        if controls.label == "Pause" { controls.tap() }
        button("racket.player.edit").tap()
        XCTAssertTrue(button("racket.edit.done").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.edit.count").label, "22 rallies · 21 tagged")
        button("racket.edit.tab.looks").tap()
        XCTAssertTrue(button("racket.edit.look.warm").isSelected)
        button("racket.edit.tab.score").tap()
        XCTAssertEqual(any("racket.edit.score.theirs").label, "10")
        XCTAssertEqual(button("racket.edit.game.0").label, "Game 1 · confirmed")
        button("racket.edit.cancel").tap()
    }

    func testEmptyGameFindsRalliesWithoutLeavingEdit() {
        launch(extra: ["-uiTestStubRallySignal"])
        openEdit(row: 1, rally: nil)
        XCTAssertTrue(any("racket.edit.emptyHint").waitForExistence(timeout: 3))
        shot("EditEmpty")
        button("racket.edit.find").tap()
        XCTAssertTrue(any("racket.edit.finding").waitForExistence(timeout: 3))
        shot("EditFinding", delay: 0.05, hold: 0.6)
        let found = NSPredicate(format: "label BEGINSWITH 'Found '")
        expectation(for: found, evaluatedWith: any("racket.edit.finding"))
        waitForExpectations(timeout: 60)
        XCTAssertTrue(button("racket.edit.done").exists, "still in Edit")
    }

    func testTennisDoublesInspector() {
        launch(extra: ["-uiTestRacketSport", "tennis", "-uiTestRacketDoubles", "YES"])
        openEdit()
        tapStrip()
        XCTAssertTrue(any("racket.edit.title").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.edit.title").label.hasPrefix("Point 12 · Games "), any("racket.edit.title").label)
        XCTAssertTrue(button("racket.edit.winner.us").exists)
        XCTAssertEqual(button("racket.edit.winner.us").label, "Us")
        XCTAssertTrue(button("racket.edit.last.skip").exists)
        XCTAssertTrue(button("racket.edit.detail.serve").exists)
        XCTAssertTrue(button("racket.edit.rules").exists)
        shot("EditSport")
    }

    // MARK: Share

    func testShareSummaryAndACompletedCopy() {
        launch(extra: ["-uiTestShareSlow"])
        openPlayer()
        pause()
        button("racket.player.share").tap()
        XCTAssertTrue(any("racket.share.summary").waitForExistence(timeout: 4))
        XCTAssertTrue(button("racket.share.which.ralliesOnly").isSelected)
        XCTAssertTrue(any("racket.share.summary").label.hasPrefix("21 rallies · "), any("racket.share.summary").label)
        XCTAssertTrue(any("racket.share.size").label.hasPrefix("about "))
        shot("ShareSheet")
        button("racket.share.which.whole").tap()
        XCTAssertEqual(any("racket.share.summary").label, "Whole game · 5:00")
        button("racket.share.go").tap()
        XCTAssertTrue(any("racket.share.progress").waitForExistence(timeout: 3))
        XCTAssertTrue(any("racket.share.progress").label.hasPrefix("Preparing the whole game · "), any("racket.share.progress").label)
        shot("ShareExport", delay: 0.05, hold: 0.5)
        // The system share sheet with the new copy.
        let sheet = app.otherElements["ActivityListView"].firstMatch
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 60) || close.waitForExistence(timeout: 1), "the share sheet shows the copy")
        XCTAssertFalse(any("racket.share.error").exists)
    }
}
