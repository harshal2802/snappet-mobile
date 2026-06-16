import XCTest

/// UI coverage for the **named free-flow climb session** (workout-with-timer PR 5): in the freeform
/// player, tapping "Climbing" in the add-exercise menu first asks for a custom climb name (e.g.
/// "Cave Project", "Blue V4") via a small "Name this climb" alert, so per-attempt logging groups under
/// the named climb instead of the fixed "Climbing". The typed name becomes the section header (stored on
/// the SessionExercise's `displayName`); a blank entry falls back to "Climbing" (the pure
/// `SetMeasure.climbName`).
///
/// Drives the real path — Quick Start → add a Climbing exercise → fill the name field "Cave Project" →
/// Add → assert the section header static text "Cave Project" appears → Add attempt → set grade "V3" →
/// Add → assert a `freeform.setRow` logs under that climb (distinctive grade "V3"). Photo attachment to a
/// free-flow climb is a deferred, device-pending follow-up (PHPicker/Photos is unverifiable in CI) and is
/// intentionally NOT exercised here.
///
/// Same fresh-store launch as the rest of SnappetUITests so the run never inherits a leftover active
/// session. Extract shots with `xcrun xcresulttool export attachments`.
final class NamedClimbTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestFreshStore"]
        app.launch()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Apps → Workout dashboard → Quick Start, landing in the routineless freeform player.
    private func openFreeformPlayer() {
        XCTAssertTrue(app.tabBars.buttons["Apps"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.workout-log"]
        XCTAssertTrue(card.waitForExistence(timeout: 8), "the workout module card should be in the App Library")
        card.tap()
        let quick = app.buttons["workout.quickStart"]
        XCTAssertTrue(quick.waitForExistence(timeout: 6), "Quick Start should be on the dashboard")
        quick.tap()
        XCTAssertTrue(app.staticTexts["overallWorkoutTimer"].waitForExistence(timeout: 8)
            || app.otherElements["overallWorkoutTimer"].waitForExistence(timeout: 2),
            "the freeform player should open")
    }

    /// Open the add-exercise menu and tap "Climbing" (which now opens the "Name this climb" prompt).
    private func tapAddClimbingMenuItem() {
        let menu = app.buttons["freeform.addExercise"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Add exercise menu should exist")
        menu.tap()
        let opt = app.buttons["Climbing"]
        XCTAssertTrue(opt.waitForExistence(timeout: 4), "menu item Climbing should appear")
        opt.tap()
    }

    /// Tap the "Add set" button for the most recently added exercise (robust to a SwiftUI `Menu` tap
    /// occasionally double-firing under XCUITest — always log into the newest exercise).
    private func tapAddSetForLastExercise() {
        let adds = app.buttons.matching(identifier: "freeform.addSet")
        XCTAssertTrue(adds.firstMatch.waitForExistence(timeout: 4), "an Add set button should exist")
        adds.element(boundBy: adds.count - 1).tap()
    }

    private func typeIn(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 4), "field should exist before typing")
        field.tap()
        field.typeText(text)
    }

    func testNamedClimbGroupsAttemptsUnderTheCustomName() {
        openFreeformPlayer()
        snap("01-freeform")

        // Tap "Climbing" → the "Name this climb" alert appears with a text field. Fill a custom name.
        tapAddClimbingMenuItem()
        // On iOS 26 a SwiftUI `.alert` TextField is NOT exposed under `app.alerts.textFields`; the leaf
        // TextField carrying `freeform.climbName` is reachable via the UNSCOPED query (the repo's
        // UI-test lesson). The alert's "Add" button is likewise reached unscoped.
        let nameField = app.textFields["freeform.climbName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5),
                      "tapping Climbing should present a 'Name this climb' prompt with a name field")
        nameField.tap()
        nameField.typeText("Cave Project")
        snap("02-named")
        app.buttons["Add"].tap()

        // The custom name becomes the section header (via resolver.name(override:) → SessionExercise
        // displayName). Assert the distinctive header text appears — proves the name persisted + renders.
        XCTAssertTrue(app.staticTexts["Cave Project"].waitForExistence(timeout: 6),
                      "the custom climb name should show as the exercise section header")
        snap("03-header")

        // Log an attempt under the named climb: open the attempt sheet, set a distinctive grade, Add.
        tapAddSetForLastExercise()
        let grade = app.textFields["logset.grade"]
        XCTAssertTrue(grade.waitForExistence(timeout: 6), "the climb attempt log sheet should open")
        typeIn(grade, "V3")

        let add = app.buttons["logset.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4) && add.isEnabled,
                      "a graded attempt should enable the Add button")
        add.tap()

        // The attempt logs as a row under the named climb. `freeform.setRow` is the row's content HStack
        // (a static-text / container element, NOT a List cell), so query it type-agnostically. The grade
        // "V3" is distinctive (the row renders "V3 · Sent" via SetMeasure.summary), so its presence proves
        // the attempt logged under the named climb.
        sleep(1); snap("04-logged")
        let row = app.descendants(matching: .any).matching(identifier: "freeform.setRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "a logged attempt row should appear under the climb")
        // The row summary is a single Text ("V3 · Sent"); assert one leaf static text carries the grade.
        // Querying the static text directly avoids the unreliable combined container label on iOS 26.
        let summary = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "V3")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 6),
                      "the attempt row should show the distinctive grade (V3) under the named climb")
        // …and the named-climb header is still present alongside the logged attempt.
        XCTAssertTrue(app.staticTexts["Cave Project"].exists,
                      "the named-climb header should remain while its attempts are logged")
    }
}
