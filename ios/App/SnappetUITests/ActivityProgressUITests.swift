import XCTest

/// Activity progress (prompt 178+): every past clip of an activity, from the live pager and the session
/// detail. Seeded by `-uiTestSeedActivityClips` — the routine-history fixture plus bench clips on four
/// past Push Days (and one untagged photo).
@MainActor
final class ActivityProgressUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedActivityClips"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Let a swipe's deceleration finish — a tap on a still-scrolling view only stops the scroll.
    private func settle() { Thread.sleep(forTimeInterval: 1) }

    private func openGymTracker() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
    }

    private func assertSheetShowsFourBenchClips() {
        XCTAssertTrue(any("activity.clips.tile").waitForExistence(timeout: 6), "the past-clips sheet's tiles")
        // The grid is lazy, so assert the sheet's summary line rather than counting rendered tiles.
        let summary = any("activity.clips.summary")
        XCTAssertTrue(summary.exists)
        XCTAssertTrue(summary.label.contains("4 clips") && summary.label.contains("4 sessions"), summary.label)
        XCTAssertTrue(summary.label.contains("1 untagged"), summary.label)
    }

    func testSessionDetailOpensPastClipsAndViewer() {
        openGymTracker()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Push Day'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()

        let chip = any("activity.pastClips")
        for _ in 0..<6 where !chip.isHittable { app.swipeUp() }
        settle()
        XCTAssertTrue(chip.waitForExistence(timeout: 4), "a past-clips chip on the bench header")
        XCTAssertTrue(chip.label.contains("4 past clips"), chip.label)
        snap("01-detail-chip")
        chip.tap()

        assertSheetShowsFourBenchClips()
        snap("02-sheet")
        any("activity.clips.tile").tap()
        XCTAssertTrue(any("activity.clips.viewer").waitForExistence(timeout: 6), "the fullscreen viewer")
        snap("03-viewer")
        any("activity.clips.close").tap()
        any("activity.clips.done").tap()
    }

    func testLivePagerShowsPastClipsChip() {
        openGymTracker()
        app.segmentedControls.buttons["Routines"].tap()
        let routine = app.staticTexts["Push Day"].firstMatch
        // The seeded routine sits under the starter routines — scroll until it's on screen.
        for _ in 0..<6 where !(routine.exists && routine.isHittable) { app.swipeUp() }
        settle()
        XCTAssertTrue(routine.waitForExistence(timeout: 6))
        routine.tap()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 6))
        start.tap()

        let chip = any("activity.pastClips")
        XCTAssertTrue(chip.waitForExistence(timeout: 8), "the chip on the bench page")
        XCTAssertTrue(chip.label.contains("4 past clips"), chip.label)
        snap("04-pager-chip")
        chip.tap()
        assertSheetShowsFourBenchClips()
        snap("05-pager-sheet")
    }

    func testDashboardFromSessionDetail() {
        openGymTracker()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Push Day'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()

        let open = any("activity.openDashboard")
        for _ in 0..<6 where !(open.exists && open.isHittable) { app.swipeUp() }
        settle()
        XCTAssertTrue(open.waitForExistence(timeout: 4), "a progress button on the bench header")
        open.tap()

        XCTAssertTrue(any("activity.dashboard.kpis").waitForExistence(timeout: 6), "KPI tiles")
        XCTAssertTrue(any("activity.dashboard.chart").exists, "the hero chart")
        XCTAssertTrue(app.staticTexts["Est. 1RM"].exists)
        XCTAssertTrue(any("activity.dashboard.clips").exists, "the clips filmstrip")
        // Tapping near the first (filmed) point selects it and offers its clip.
        any("activity.dashboard.chart").coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        XCTAssertTrue(any("activity.dashboard.playSelected").waitForExistence(timeout: 3), "Play clip for a filmed point")
        snap("06-dashboard-top")
        any("activity.dashboard.playSelected").tap()
        XCTAssertTrue(any("activity.clips.viewer").waitForExistence(timeout: 6))
        any("activity.clips.close").tap()
        app.swipeUp()
        XCTAssertTrue(any("activity.dashboard.frequency").waitForExistence(timeout: 3))
        snap("07-dashboard-bottom")
        // The first-session record was filmed (the seed's oldest Push Day) → it plays.
        let first = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'activity.dashboard.record' AND label CONTAINS 'First session'")).firstMatch
        XCTAssertTrue(first.exists)
        // Let the swipe's deceleration finish — a tap on a still-scrolling view only stops the scroll.
        _ = app.wait(for: .runningForeground, timeout: 1.5)
        Thread.sleep(forTimeInterval: 1)
        first.tap()
        XCTAssertTrue(any("activity.clips.viewer").waitForExistence(timeout: 6), "the record's clip plays")
        any("activity.clips.close").tap()
    }

    func testPRFilterCompareAndProgressReel() {
        openGymTracker()
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Push Day'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        let chip = any("activity.pastClips")
        for _ in 0..<6 where !(chip.exists && chip.isHittable) { app.swipeUp() }
        settle()
        chip.tap()
        XCTAssertTrue(any("activity.clips.tile").waitForExistence(timeout: 6))

        // PR filter: the seed's bench rises every other session, so the filmed sessions are FIRST/PR moments.
        XCTAssertTrue(any("activity.clips.filter").exists, "the Timeline / PRs filter")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'activity.clips.tile' AND label BEGINSWITH 'PR'")).firstMatch.exists,
                      "a PR badge on the newest filmed session")
        app.segmentedControls.buttons["PRs ★"].tap()
        snap("08-prs")
        app.segmentedControls.buttons["Timeline"].tap()

        // Then vs Now.
        // Compare first asks which two clips — first + latest are pre-picked; picking a third swaps one out.
        any("activity.clips.compare").tap()
        let go = any("activity.comparePicker.go")
        XCTAssertTrue(go.waitForExistence(timeout: 6), "the clip picker")
        let picks = app.descendants(matching: .any).matching(identifier: "activity.comparePicker.clip")
        XCTAssertEqual(picks.matching(NSPredicate(format: "selected == true")).count, 2, "first + latest pre-picked")
        let unpicked = picks.matching(NSPredicate(format: "selected == false")).firstMatch
        XCTAssertTrue(unpicked.exists)
        let newLabel = unpicked.label               // `unpicked` is a live query — pin the clip by its label
        unpicked.tap()
        XCTAssertEqual(picks.matching(NSPredicate(format: "selected == true")).count, 2, "still a pair")
        XCTAssertTrue(picks.matching(NSPredicate(format: "label CONTAINS %@", newLabel)).firstMatch.isSelected,
                      "the new pick is in the pair")
        snap("08b-picker")
        go.tap()
        XCTAssertTrue(any("activity.compare.delta").waitForExistence(timeout: 6), "the compare footer")
        XCTAssertTrue(any("activity.compare.change").exists, "a visible Change button")
        snap("09-compare")
        any("activity.compare.speed").tap()
        any("activity.compare.close").tap()
        any("activity.comparePicker.cancel").tap()

        // Progress reel → the shared reel builder.
        any("activity.clips.reel").tap()
        let all = app.buttons["All"]
        XCTAssertTrue(all.waitForExistence(timeout: 3))
        all.tap()
        let reelTitle = app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS 'Progress' OR identifier == 'Highlights'")).firstMatch
        XCTAssertTrue(reelTitle.waitForExistence(timeout: 10) || any("weeklyReel.empty").exists, "the reel builder opened")
        snap("10-reel")
    }

    func testEffortCardAndGhostCompare() {
        openGymTracker()
        // Strength: the bench dashboard reads HR at the repeated load.
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Push Day'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6))
        row.tap()
        let open = any("activity.openDashboard")
        for _ in 0..<6 where !(open.exists && open.isHittable) { app.swipeUp() }
        settle()
        open.tap()
        XCTAssertTrue(any("activity.dashboard.effort").waitForExistence(timeout: 6), "the effort card")
        snap("11-effort")

        // Ghost mode in Then vs Now.
        let compare = any("activity.dashboard.compare")
        for _ in 0..<3 where !(compare.exists && compare.isHittable) { app.swipeUp() }
        settle()
        compare.tap()
        let go = any("activity.comparePicker.go")
        XCTAssertTrue(go.waitForExistence(timeout: 6), "Compare asks which two clips first")
        go.tap()
        XCTAssertTrue(any("activity.compare.ghost").waitForExistence(timeout: 6))
        any("activity.compare.ghost").tap()
        XCTAssertTrue(app.staticTexts["Ghost on"].waitForExistence(timeout: 3))
        snap("12-ghost")
        any("activity.compare.close").tap()
        any("activity.comparePicker.cancel").tap()
    }

    func testClimbDashboardAndClimbingOverview() {
        openGymTracker()
        // A named climb's dashboard from its session (the seed's newest Bouldering has a filmed V5) …
        app.segmentedControls.buttons["History"].tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'historyRow' AND label CONTAINS 'Bouldering'")).firstMatch
        _ = row.waitForExistence(timeout: 4)
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        settle()
        XCTAssertTrue(row.exists)
        row.tap()
        let open = app.buttons.matching(identifier: "activity.openDashboard").firstMatch
        for _ in 0..<6 where !(open.exists && open.isHittable) { app.swipeUp() }
        settle()
        XCTAssertTrue(open.exists, "a progress button on a climb header")
        open.tap()
        XCTAssertTrue(any("activity.dashboard.kpis").waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Hardest send"].exists)
        snap("14-climb")

        // … up to all climbing, whose climbs list drills back into one climb.
        let allClimbing = any("activity.dashboard.allClimbing")
        for _ in 0..<6 where !(allClimbing.exists && allClimbing.isHittable) { app.swipeUp() }
        Thread.sleep(forTimeInterval: 1)
        allClimbing.tap()
        XCTAssertTrue(app.navigationBars["Climbing"].waitForExistence(timeout: 6))
        let climbRow = any("activity.dashboard.climb")
        for _ in 0..<6 where !(climbRow.exists && climbRow.isHittable) { app.swipeUp() }
        settle()
        XCTAssertTrue(climbRow.exists, "the named climbs list")
        snap("13-climbing")
        Thread.sleep(forTimeInterval: 1)
        climbRow.tap()
        XCTAssertTrue(any("activity.dashboard.allClimbing").waitForExistence(timeout: 6) || app.staticTexts["Hardest send"].exists,
                      "a climb row opens that climb's dashboard")
    }
}
