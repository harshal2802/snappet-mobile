import XCTest

/// Guide-photo pack surfaces (prompt 108), in two layers so the suite stays hermetic:
///
/// 1. **Always** (no network): the Workout Settings "Guide photos" section and the
///    exercise-detail CTA render in the not-installed state.
/// 2. **When a local pack server is up** (`python -m http.server -d exercise-photos 8787` over
///    `tools/workout/build_photo_pack.py --limit 12` output): drives the real
///    download → detail pager → remove loop end-to-end. Skipped otherwise.
final class GuidePhotoUITests: XCTestCase {
    var app: XCUIApplication!
    private static let localHost = "http://127.0.0.1:8787/"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        // Point the pack host at the local test server via the NSUserDefaults launch-argument
        // override. Harmless when the server isn't running — the not-installed assertions never
        // touch the network (downloads are strictly tap-initiated).
        app.launchArguments += ["-workout.photos.host", Self.localHost]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openWorkoutSettings() {
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        let gear = app.buttons["workout.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 6), "the Settings gear should be in the toolbar")
        gear.tap()
    }

    /// The pack persists in Application Support across launches (deliberately — it must work
    /// offline), so start every run from the not-installed state.
    private func ensureRemoved() {
        let remove = app.buttons["removeGuidePhotos"]
        if remove.waitForExistence(timeout: 2) { remove.tap() }
        XCTAssertTrue(app.buttons["downloadGuidePhotosSettings"].waitForExistence(timeout: 4),
                      "Settings should offer the guide-photo download when nothing is installed")
    }

    func testNotInstalledSurfacesRender() {
        openWorkoutSettings()
        ensureRemoved()
        snap("01-settings-not-installed")

        // Exercise detail shows the CTA (not a pager) while the pack is missing.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["Library"].tap()
        let row = app.buttons.matching(identifier: "exerciseRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4)); row.tap()
        XCTAssertTrue(app.buttons["downloadGuidePhotos"].waitForExistence(timeout: 4),
                      "exercise detail should show the download CTA when the pack is missing")
        snap("02-detail-cta")
    }

    func testDownloadPagerRemoveRoundtrip() throws {
        try XCTSkipUnless(Self.packServerReachable(),
                          "local pack server not running — see tools/workout/README.md")

        openWorkoutSettings()
        ensureRemoved()

        app.buttons["downloadGuidePhotosSettings"].tap()
        XCTAssertTrue(app.buttons["removeGuidePhotos"].waitForExistence(timeout: 30),
                      "the pack download from the local server should complete and show Installed")
        XCTAssertTrue(app.staticTexts["Installed"].exists)
        snap("03-settings-installed")

        // The alphabetical head of the catalog (3/4 Sit-Up) is in every `--limit` test pack,
        // so the first library row must now render the pager.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["Library"].tap()
        let row = app.buttons.matching(identifier: "exerciseRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4)); row.tap()
        let pager = app.descendants(matching: .any).matching(identifier: "exercise.guidePhotos").firstMatch
        XCTAssertTrue(pager.waitForExistence(timeout: 6),
                      "the installed pack should render the START→END pager on the first exercise")
        XCTAssertFalse(app.buttons["downloadGuidePhotos"].exists, "CTA must be gone once installed")
        snap("04-detail-pager")

        // Remove → CTA comes back (the exact pre-feature + not-installed UX).
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["workout.settings"].tap()
        app.buttons["removeGuidePhotos"].tap()
        XCTAssertTrue(app.buttons["downloadGuidePhotosSettings"].waitForExistence(timeout: 4))
        snap("05-settings-removed")
    }

    /// One cheap GET for the manifest, from the test runner (same host view as the app).
    private static func packServerReachable() -> Bool {
        guard let url = URL(string: localHost + "manifest.json") else { return false }
        var ok = false
        let done = DispatchSemaphore(value: 0)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        URLSession(configuration: config).dataTask(with: url) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return ok
    }
}
