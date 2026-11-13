import XCTest

/// UI coverage for the **racket model hooks** (prompt 248, issue #438 step 5) on the `-uiTestSeedRacketVideos` seed. The
/// simulator has no recorded video, so `-uiTestStubRallySignal` feeds the real placeholder model a synthetic motion
/// signal (a burst every 20 s, every fourth one weak). Covers Capabilities → Preview a sport with no model, and Find
/// rallies → Analyzing → the game summary → Check unsure → TagDone, then Re-scan with compare → ModelCompare → Use.
/// Scan speed, heat and accuracy on real footage are device items.
@MainActor
final class RacketModelUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRacketVideos", "-uiTestFakeCamera", "-uiTestStubRallySignal"]
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
        XCTAssertTrue(any("racket.videos.header").waitForExistence(timeout: 6), "Your videos is FindRallies: a model exists")
    }

    func testCapabilitiesShowTrueStatesAndPreviewASportWithNoModel() {
        openYourVideos()
        XCTAssertFalse(any("racket.videos.notYet").exists, "rally finding is available on the placeholder")
        XCTAssertEqual(any("racket.videos.scan.0").label, "Not scanned")
        tapWhenHittable(app.buttons["racket.videos.capabilities"])

        XCTAssertTrue(any("racket.caps.title").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.caps.title").label, "What works for table tennis")
        for f in ["findRallies", "liveTracking", "courtCheck", "shotCount", "shotTypes", "endings", "ballPath",
                  "longestRallyInDrills"] {
            let row = any("racket.caps.\(f)")
            if !row.exists { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.waitForExistence(timeout: 3), f)
            // Device feedback round 2: the true state, never a blanket "✓ Available".
            let backed = f == "findRallies" || f == "longestRallyInDrills"
            XCTAssertTrue(row.label.contains(backed ? "Placeholder" : "Not available yet"), row.label)
            XCTAssertFalse(row.label.contains("✓ Available"), row.label)
            XCTAssertTrue(row.label.contains("Without it:"), row.label)
        }
        XCTAssertTrue(any("racket.caps.findRallies").label.contains("mark rallies on the timeline"))

        tapWhenHittable(app.buttons["racket.caps.preview"])
        XCTAssertTrue(any("racket.videos.previewLabel").waitForExistence(timeout: 5), "labelled as a preview (review5)")
        XCTAssertEqual(any("racket.videos.notYet").label, "Rally finding isn’t available for table tennis yet.")
        XCTAssertEqual(app.buttons["racket.videos.mark.0"].label, "Mark rallies", "the by-hand path")
        XCTAssertFalse(app.buttons["racket.videos.0.find"].exists, "no Find rallies without a model")
    }

    func testFindRalliesThenCheckTheUnsureOnesThenRescanAndCompare() {
        openYourVideos()
        tapWhenHittable(app.buttons["racket.videos.drill"])
        XCTAssertTrue(any("racket.drill.scan.0").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.drill.scan.0").label, "Not scanned")

        // Find rallies on block 1 → Analyzing.
        tapWhenHittable(app.buttons["racket.drill.0.find"])
        XCTAssertTrue(any("racket.analyzing.headline").waitForExistence(timeout: 5), "Analyzing opens")
        let review = app.buttons["racket.analyzing.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 60), "the scan finishes")
        XCTAssertTrue(any("racket.analyzing.status.0").label.hasPrefix("Ready ·"), any("racket.analyzing.status.0").label)
        XCTAssertTrue(review.label.contains("Block 1"), "a drill's part is a block, not a game (review5): \(review.label)")
        review.tap()

        // The game summary: rallies found, unsure ones to check.
        XCTAssertTrue(any("racket.analysis.found").waitForExistence(timeout: 5))
        let found = Int(any("racket.analysis.found").label) ?? 0
        XCTAssertGreaterThanOrEqual(found, 12, "a burst every 20 s over 5 minutes")
        XCTAssertEqual(any("racket.analysis.model").label.hasPrefix("Snappet placeholder v1"), true)
        let check = app.buttons["racket.analysis.checkUnsure"]
        XCTAssertTrue(check.exists, "the weak bursts are unsure")
        check.tap()

        // QuickTag over the unsure ones only, then TagDone with none left.
        let next = app.buttons["racket.tag.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(any("racket.tag.title").label.hasPrefix("Unsure 1 of "), any("racket.tag.title").label)
        // V1: the rally's video is on the tag sheet (QuickTag), with So far / Final and the rules link.
        XCTAssertTrue(any("racket.rallyVideo").exists, "the tag sheet shows the rally's video")
        XCTAssertTrue(any("racket.tag.endingNotYet").exists, "ending suggestions say Not available yet")
        app.buttons["racket.tag.rules"].tap()
        XCTAssertTrue(any("racket.rules.footer").waitForExistence(timeout: 4))
        app.buttons["racket.rules.close"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 4))
        var n = 0
        while next.exists && n < 12 {
            next.tap()
            n += 1
            if any("racket.tagDone.checked").waitForExistence(timeout: 1.5) { break }
        }
        XCTAssertTrue(any("racket.tagDone.checked").waitForExistence(timeout: 6), "checking the last unsure shows TagDone")
        XCTAssertEqual(any("racket.tagDone.checked").label, "\(n) of \(n) checked")
        XCTAssertTrue(any("racket.tagDone.unsureLeft").label.hasSuffix("0"), any("racket.tagDone.unsureLeft").label)
        XCTAssertTrue(any("racket.tagDone.guesses").label.contains("Snappet’s guesses"))

        // Back on Drill videos the block says which model scanned it; Re-scan… → ChooseModel → compare.
        app.buttons["racket.tagDone.done"].tap()
        tapWhenHittable(app.buttons["racket.videos.drill"])
        XCTAssertTrue(any("racket.drill.scan.0").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.drill.scan.0").label, "Snappet placeholder v1")
        tapWhenHittable(app.buttons["racket.drill.0.rescan"])
        XCTAssertTrue(app.buttons["racket.choose.rescan"].waitForExistence(timeout: 5))
        XCTAssertTrue(any("racket.choose.model.0").label.contains("Used for this video now"), any("racket.choose.model.0").label)
        app.buttons["racket.choose.rescan"].tap()
        let compare = app.buttons["racket.analyzing.compare.0"]
        XCTAssertTrue(compare.waitForExistence(timeout: 60), "compare before replacing: the new scan waits")
        compare.tap()
        XCTAssertTrue(any("racket.modelCompare.count").waitForExistence(timeout: 5))
        XCTAssertEqual(any("racket.modelCompare.count").label, "No differences", "same model, same video")
        app.buttons["racket.modelCompare.use"].tap()
        XCTAssertTrue(any("racket.analysis.found").waitForExistence(timeout: 5), "Use → the game summary")
        XCTAssertFalse(app.buttons["racket.analysis.checkUnsure"].isEnabled, "the rallies you checked stay checked")
    }
}
