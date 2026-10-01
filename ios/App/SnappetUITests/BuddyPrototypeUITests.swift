import XCTest

/// Prompt 147: the 3D training-buddy prototype opens from Workout → Settings → Labs and reacts to
/// stage, Form, pause and cheer. Screenshots are for the visual check (RealityKit renders in the sim).
@MainActor
final class BuddyPrototypeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testBuddyReactsToStageFormPauseAndCheer() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        app.buttons["moduleCard.workout-log"].tap()
        let gear = app.buttons["workout.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 6))
        gear.tap()
        let open = app.buttons["openBuddyPrototype"]
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        open.tap()

        let mood = app.staticTexts["buddy.mood"]
        XCTAssertTrue(mood.waitForExistence(timeout: 6))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "buddy.creature").firstMatch.exists)
        XCTAssertEqual(mood.label, "Steady")   // Sprout at 70 % Form
        sleep(1); snap("01-sprout-steady")

        let stage = app.segmentedControls["buddy.stage"]
        for (title, shot) in [("Egg", "02-egg"), ("Hatchling", "03-hatchling"), ("Adult", "04-adult"), ("Legend", "05-legend")] {
            stage.buttons[title].tap()
            sleep(1); snap(shot)
        }

        let form = app.sliders["buddy.form"]
        form.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(mood.label, "Fired up")
        sleep(1); snap("06-legend-fired-up")
        form.adjust(toNormalizedSliderPosition: 0.05)
        XCTAssertEqual(mood.label, "Sleepy")
        sleep(1); snap("07-legend-sleepy")

        // The Labs screen grew (P3 preview buttons): bring the switch above the tab bar first.
        let pauseSwitch = app.switches["buddy.pause"]
        for _ in 0..<3 where !pauseSwitch.isHittable { app.swipeUp() }
        pauseSwitch.switches.firstMatch.tap()
        XCTAssertTrue(mood.label.hasPrefix("Resting"), mood.label)
        app.swipeDown()
        sleep(1); snap("08-paused")
        for _ in 0..<3 where !pauseSwitch.isHittable { app.swipeUp() }
        pauseSwitch.switches.firstMatch.tap()

        form.adjust(toNormalizedSliderPosition: 0.9)
        app.swipeDown()
        // Tapping the buddy itself cheers (same as the Cheer button).
        app.descendants(matching: .any).matching(identifier: "buddy.creature").firstMatch.tap()
        usleep(450_000); snap("09-cheer")
        app.buttons["buddy.cheer"].tap()

        // The other styles are shown but locked until their model packs exist.
        XCTAssertTrue(app.buttons["buddy.style.Athlete"].label.contains("Coming soon"))
    }

    /// P3 (prompt 151): the level-up and growing-up moments, previewed from Labs.
    func testPreviewTheMoments() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        app.buttons["moduleCard.workout-log"].tap()
        let gear = app.buttons["workout.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 6))
        gear.tap()
        let open = app.buttons["openBuddyPrototype"]
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        open.tap()
        let levelUp = app.buttons["buddy.previewLevelUp"]
        for _ in 0..<4 where !levelUp.isHittable { app.swipeUp() }
        let title = app.staticTexts["moment.title"]

        app.buttons["buddy.previewGrewUp"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Adult")
        XCTAssertTrue(app.buttons["Meet your Adult"].exists)
        sleep(3); snap("21-moment-grew-up")
        app.buttons["moment.done"].tap()

        levelUp.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Level 13")
        sleep(6); snap("20-moment-level-up")
        app.buttons["moment.done"].tap()
        XCTAssertFalse(title.exists)
    }
}
