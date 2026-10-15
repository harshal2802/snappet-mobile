import XCTest

/// The Library's "Yours" tab (Library redesign L1, prompt 183): your logged activities, sortable per discipline, each
/// opening its dashboard. Seeded by `-uiTestSeedRoutineHistory` (Push Day ×8, Finger day ×6, Bouldering ×5 with V2–V5
/// climbs, Easy run ×4).
@MainActor
final class LibraryYoursUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTestSeedRoutineHistory"]
        app.launch()
        app.tabBars.buttons["Apps"].tap()
        XCTAssertTrue(app.buttons["moduleCard.workout-log"].waitForExistence(timeout: 6))
        app.buttons["moduleCard.workout-log"].tap()
        app.segmentedControls.buttons["Library"].tap()
    }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private var rows: XCUIElementQuery { app.buttons.matching(identifier: "library.yours.row") }

    func testYoursIsTheDefaultAndListsWhatYouLogged() {
        let mode = app.segmentedControls.matching(identifier: "library.mode").firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 6))
        XCTAssertTrue(mode.buttons["Yours"].isSelected, "with history, the Library opens on Yours")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 6))
        // Your bench, your climbs and your run are all here — none of them were Library items before.
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS 'Bench'")).firstMatch.exists)
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS 'Easy run'")).firstMatch.exists)
        snap("01-yours-all")

        // Counts are days by default; "Count by" switches the unit (prompt 183 follow-up).
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS ' days'")).firstMatch.exists, "days by default")
        app.buttons.matching(identifier: "library.sort").firstMatch.tap()
        let sets = app.buttons["Sets"]
        XCTAssertTrue(sets.waitForExistence(timeout: 3))
        sets.tap()
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS ' sets'")).firstMatch.waitForExistence(timeout: 3))
        snap("01b-count-by-sets")
    }

    func testClimbingSortsByHardestAndOpensTheClimb() {
        let chip = app.descendants(matching: .any).matching(identifier: "library.chip.climb").firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 6))
        chip.tap()
        XCTAssertTrue(rows.matching(NSPredicate(format: "label CONTAINS 'boulder'")).firstMatch.waitForExistence(timeout: 6),
                      "the climbs you logged in Quick Sessions")
        snap("02-yours-climbing")

        app.buttons.matching(identifier: "library.sort").firstMatch.tap()
        let hardest = app.buttons["Hardest grade"]
        XCTAssertTrue(hardest.waitForExistence(timeout: 3))
        snap("03-sort-menu")
        hardest.tap()
        XCTAssertTrue(rows.firstMatch.label.contains("V5"), "hardest first: \(rows.firstMatch.label)")
        snap("04-hardest")

        rows.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "activity.dashboard.kpis").firstMatch
            .waitForExistence(timeout: 6), "the climb's dashboard")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The sort is remembered for the discipline.
        XCTAssertTrue(app.buttons.matching(identifier: "library.sort").firstMatch.label.contains("Hardest"))
    }
}
