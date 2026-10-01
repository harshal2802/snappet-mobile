import XCTest

/// Renders the buddy widget stills (progression P4): every stage × mood from the app's real 3D buddy,
/// on the widget's background colour. Skipped in normal runs — run on purpose with
/// `TEST_RUNNER_RENDER_BUDDY_STILLS=1`, then `scripts/buddy-stills.py <xcresult>` writes them into
/// `SnappetWidgets/BuddyStills.xcassets`.
@MainActor
final class BuddyStillRenderTests: XCTestCase {
    func testRenderWidgetStills() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RENDER_BUDDY_STILLS"] == "1", "render-only")
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore", "-buddyStillStudio"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        app.buttons["moduleCard.workout-log"].tap()
        let gear = app.buttons["workout.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 6))
        gear.tap()
        let open = app.buttons["openBuddyPrototype"]
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        open.tap()

        let creature = app.descendants(matching: .any).matching(identifier: "buddy.creature").firstMatch
        XCTAssertTrue(creature.waitForExistence(timeout: 6))
        let stage = app.segmentedControls["buddy.stage"]
        let form = app.sliders["buddy.form"]
        let pause = app.switches["buddy.pause"].switches.firstMatch
        let stages = ["Egg": "egg", "Hatchling": "hatchling", "Sprout": "sprout", "Adult": "adult", "Legend": "legend"]
        let moods: [(String, Double)] = [("fired", 0.92), ("steady", 0.6), ("tired", 0.32), ("sleepy", 0.06)]
        for (title, key) in stages {
            stage.buttons[title].tap()
            for (mood, value) in moods {
                form.adjust(toNormalizedSliderPosition: value)
                sleep(2)
                attach(creature.screenshot(), "buddy-\(key)-\(mood)")
            }
            pause.tap()
            sleep(2)
            attach(creature.screenshot(), "buddy-\(key)-resting")
            pause.tap()
        }
    }

    private func attach(_ shot: XCUIScreenshot, _ name: String) {
        let a = XCTAttachment(screenshot: shot)
        a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
