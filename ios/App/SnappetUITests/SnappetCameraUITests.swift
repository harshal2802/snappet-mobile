import XCTest

/// The in-app camera (prompt 190) — driven with the `-uiTestFakeCamera` stand-in (an iPhone 13 Pro-class camera, no
/// real capture: the simulator has none): the "HD · 30" chip cycles like the iPhone Camera, the lenses, the settings
/// tray, the hands-free countdown into a recording with its timer + mid-clip still, PHOTO mode, Done back to the set.
@MainActor final class SnappetCameraUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-uiTestFakeCamera"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openCameraFromATimedSet() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        app.buttons["moduleCard.workout-log"].tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6))
        quick.tap()
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        app.buttons["Lifting exercise"].tap()
        let row = app.buttons.matching(NSPredicate(
            format: "label CONTAINS 'Beginner' OR label CONTAINS 'Intermediate' OR label CONTAINS 'Expert'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        app.navigationBars.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add'")).firstMatch.tap()
        let time = app.buttons["freeform.timeThisSet"]
        XCTAssertTrue(time.waitForExistence(timeout: 6))
        time.tap()
        let record = app.buttons["timedSet.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 6), "the in-app camera")
    }

    func testTheCameraLikeTheIPhoneCamera() {
        openCameraFromATimedSet()

        // Chip: HD · 30 by default; tap the halves like the iPhone Camera.
        let res = app.buttons["camera.chip.resolution"], fps = app.buttons["camera.chip.fps"]
        XCTAssertEqual(res.label, "HD")
        XCTAssertEqual(fps.label, "30")
        fps.tap()
        XCTAssertEqual(fps.label, "60")
        res.tap()
        XCTAssertEqual(res.label, "4K")
        XCTAssertEqual(fps.label, "60", "4K keeps 60 on a Pro camera")

        // Lenses .5 / 1× / 3.
        XCTAssertTrue(app.buttons["camera.lens..5"].exists)
        XCTAssertTrue(app.buttons["camera.lens.3"].exists)
        app.buttons["camera.lens.3"].tap()
        snap("01-camera")

        // The settings tray: a 3 s countdown + grid.
        app.buttons["camera.more"].tap()
        let three = app.buttons["camera.tray.countdown.3s"]
        XCTAssertTrue(three.waitForExistence(timeout: 3), "the settings tray")
        three.tap()
        app.switches["camera.tray.grid"].tap()
        snap("02-tray")
        app.buttons["camera.more"].tap()
        XCTAssertFalse(app.buttons["camera.tray.countdown.3s"].waitForExistence(timeout: 1), "tray closed")

        // Record: the countdown, then the recording timer + a still mid-clip, then stop.
        app.buttons["camera.shutter"].tap()
        XCTAssertTrue(app.staticTexts["camera.countdownOverlay"].waitForExistence(timeout: 2), "hands-free countdown")
        snap("03-countdown")
        let timer = app.staticTexts["camera.timer"]
        XCTAssertTrue(timer.waitForExistence(timeout: 6), "recording after the countdown")
        XCTAssertTrue(app.buttons["camera.still"].exists, "a still mid-clip")
        XCTAssertFalse(app.buttons["camera.done"].isEnabled, "can't leave mid-recording")
        snap("04-recording")
        app.buttons["camera.shutter"].tap()
        XCTAssertTrue(app.buttons["camera.mode.photo"].waitForExistence(timeout: 3))

        // PHOTO mode: no chip; the shutter takes a photo.
        app.buttons["camera.mode.photo"].tap()
        XCTAssertFalse(app.buttons["camera.chip.fps"].exists, "no resolution chip for photos")
        app.buttons["camera.shutter"].tap()
        XCTAssertTrue(app.staticTexts["camera.captured"].waitForExistence(timeout: 3) || app.otherElements["camera.captured"].exists,
                      "the capture count")
        snap("05-photo")

        // Done → back on the live set.
        app.buttons["camera.done"].tap()
        XCTAssertTrue(app.staticTexts["timedSet.timer"].waitForExistence(timeout: 5), "back on the set")
    }

    func testSettingsAreRememberedNextTime() {
        openCameraFromATimedSet()
        app.buttons["camera.chip.resolution"].tap()
        XCTAssertEqual(app.buttons["camera.chip.resolution"].label, "4K")
        app.buttons["camera.done"].tap()
        XCTAssertTrue(app.buttons["timedSet.record"].waitForExistence(timeout: 5))
        app.buttons["timedSet.record"].tap()
        XCTAssertTrue(app.buttons["camera.chip.resolution"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons["camera.chip.resolution"].label, "4K", "opens with the last-used settings")
    }
}
