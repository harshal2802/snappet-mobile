import XCTest

/// Prompt 209 — edit a planned session: remove and add climbs in the preview, start it, then remove a pending
/// climb mid-session. Runs on the synthetic Kilter fixture catalog (`-uiTestInstallKilterCatalog`).
final class KilterPlanEditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["apps", "-uiTestFreshStore", "-uiTestInstallKilterCatalog"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        let card = app.buttons["moduleCard.kilter"]
        var tries = 0
        while !card.isHittable && tries < 10 { app.swipeUp(); tries += 1 }
        card.tap()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var draftPicks: Int { app.descendants(matching: .any).matching(identifier: "kilter.plan.draftPick").count }
    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testEditThePlanThenEditItMidSession() {
        XCTAssertTrue(any("kilter.more").waitForExistence(timeout: 8))
        any("kilter.more").tap()
        any("kilter.plan").tap()

        let edit = any("kilter.plan.edit")
        XCTAssertTrue(edit.waitForExistence(timeout: 8), "the plan preview offers Edit")
        edit.tap()
        XCTAssertTrue(any("kilter.plan.draftPick").waitForExistence(timeout: 4))
        let start = draftPicks
        snap("01-editing")

        // Remove one (context menu), then add one back from the picker.
        any("kilter.plan.draftPick").press(forDuration: 1.0)
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertEqual(draftPicks, start - 1)

        let addSend = app.findScrolling("kilter.plan.add.send")
        XCTAssertTrue(addSend.exists, "each section offers + Add while editing")
        addSend.tap()
        // The main browse's filters are here: the Filters chip opens the same sheet (sort, classics, …).
        XCTAssertTrue(any("kilter.planAdd.filters").waitForExistence(timeout: 4))
        XCTAssertTrue(any("kilter.planAdd.saved").exists && any("kilter.planAdd.mine").exists)
        any("kilter.planAdd.filters").tap()
        XCTAssertTrue(any("kilter.filter.sort").waitForExistence(timeout: 4), "the browse Filters sheet")
        app.swipeDown(velocity: .fast)
        // Widen the grade slider (it starts at the section's band) to every grade on the tiny fixture.
        any("kilter.planAdd.grade").tap()
        XCTAssertTrue(any("kilter.grade.reset").waitForExistence(timeout: 4))
        any("kilter.grade.reset").tap()
        any("kilter.grade.done").tap()
        let add = any("kilter.planAdd.add")
        XCTAssertTrue(add.waitForExistence(timeout: 6), "a climb not in the plan can be added")
        add.tap()
        snap("02-add-sheet")
        any("kilter.planAdd.done").tap()
        XCTAssertEqual(draftPicks, start, "removed one, added one")
        XCTAssertTrue(any("kilter.plan.resetEdits").exists, "edited → Reset to suggestion replaces Shuffle")

        any("kilter.plan.edit").tap()   // Done
        any("kilter.plan.start").tap()

        // The started plan opens the first climb; come back to the session plan.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let progress = any("kilter.plan.progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 8), "session plan home")
        XCTAssertTrue(progress.label.contains("of \(start)"), progress.label)
        snap("03-session")

        // Mid-session: swipe a pending climb → Remove.
        let pick = any("kilter.plan.pick")
        pick.swipeLeft()
        any("kilter.plan.remove").tap()
        XCTAssertTrue(progress.label.contains("of \(start - 1)"), progress.label)
        XCTAssertTrue(any("kilter.plan.addClimb").exists, "and + Add a climb is offered")
    }
}
